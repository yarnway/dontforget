import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import '../models/reminder.dart';
import '../models/notification_payload.dart';
import '../data/database_helper.dart';
import 'context_trigger_service.dart';
import 'notification_journal.dart';
import 'macos_notification_scheduler.dart';
import 'startup_trace.dart';

class NotificationService {
  static final _instances = Expando<NotificationService>();
  factory NotificationService() =>
      NotificationService.forDatabase(DatabaseHelper.instance);
  factory NotificationService.forDatabase(DatabaseHelper database) =>
      _instances[database] ??= NotificationService._internal(database);
  NotificationService._internal(DatabaseHelper database)
    : flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin(),
      usesNativeNotifications = !Platform.isWindows && !Platform.isLinux,
      macScheduler = Platform.isMacOS
          ? const MacOSNotificationScheduler()
          : null,
      _database = database,
      _readDatasetEpoch = database.readNotificationEpoch;

  @visibleForTesting
  NotificationService.forTesting(
    this.flutterLocalNotificationsPlugin, {
    required this.usesNativeNotifications,
    DateTime Function()? now,
    Future<String> Function()? readDatasetEpoch,
    DatabaseHelper? database,
    this.macScheduler,
  }) : _now = now ?? DateTime.now,
       _database = database,
       _readDatasetEpoch =
           readDatasetEpoch ??
           database?.readNotificationEpoch ??
           _testDatasetEpoch;

  // Journal admission and OS concurrency are independent: larger groups can
  // share durable writes without flooding the platform notification plugin.
  static const reconciliationBatchSize = 256;
  static const nativeConcurrency = 32;
  final _nativeWaiters = Queue<Completer<void>>();
  int _activeNative = 0;

  Future<void> _runNative(Future<void> Function() action) async {
    if (_activeNative >= nativeConcurrency) {
      final waiter = Completer<void>();
      _nativeWaiters.addLast(waiter);
      await waiter.future;
    } else {
      _activeNative++;
    }
    try {
      await action();
    } finally {
      if (_nativeWaiters.isNotEmpty) {
        // Transfer the permit directly; a new arrival cannot steal it.
        _nativeWaiters.removeFirst().complete();
      } else {
        _activeNative--;
      }
    }
  }

  final DatabaseHelper? _database;
  Future<void>? _journalPreparation;
  String? _journalEpoch;

  Future<void> _prepareJournal() async {
    final database = _database;
    if (database == null || !usesNativeNotifications) return;
    if (!_initialized) throw StateError('Notification initialization failed.');
    final epoch = await _readDatasetEpoch();
    if (_journalEpoch == epoch) return;
    if (_journalPreparation != null) {
      await _journalPreparation;
      return _prepareJournal();
    }
    final operation = database.withNotificationJournal((journal) async {
      final snapshot = await journal.read();
      if (snapshot == null || snapshot.epoch != epoch) {
        // One-time migration from VM hashCode IDs, or a restored data set.
        // Mark completion only after cancellation returns. A crash repeats
        // cancellation safely before any new IDs can be submitted.
        await flutterLocalNotificationsPlugin.cancelAll();
        await journal.reset(epoch);
      }
      _journalEpoch = epoch;
    });
    _journalPreparation = operation;
    try {
      await operation;
    } finally {
      _journalPreparation = null;
    }
  }

  Future<void> _journalNative(
    String id,
    Future<void> Function(int nativeId) action, {
    Reminder? schedule,
  }) async {
    final database = _database;
    if (database == null) {
      return _runNative(() => action(stableNotificationId(id)));
    }
    await init();
    await _prepareJournal();
    final epoch = _journalEpoch!;
    final entry = await database.withNotificationJournal(
      (j) => j.begin(
        epoch,
        id,
        action: schedule == null ? 'cancel' : 'schedule',
        triggerUtcMicros: schedule?.triggerTime?.toUtc().microsecondsSinceEpoch,
        noticeRevision: schedule?.noticeRevision,
        attemptedAt: _now(),
      ),
    );
    Future<void> record(String status) => database.withNotificationJournal(
      (j) => j.record(
        epoch,
        id,
        action: schedule == null ? 'cancel' : 'schedule',
        status: status,
        triggerUtcMicros: schedule?.triggerTime?.toUtc().microsecondsSinceEpoch,
        noticeRevision: schedule?.noticeRevision,
        attemptedAt: _now(),
      ),
    );
    try {
      await _runNative(() => action(entry.nativeId));
      await record('submitted');
      if (StartupTrace.retryEnabled) {
        StartupTrace.notificationEvent('native_submitted', {
          'native_id': entry.nativeId,
          'action': schedule == null ? 'cancel' : 'schedule',
        });
      }
    } catch (error) {
      // A failed result write leaves a durable pending intent. Preserve the
      // original native error if even failure bookkeeping cannot be written.
      try {
        await record('failed');
      } catch (_) {}
      if (StartupTrace.retryEnabled) {
        final details = error is PlatformException && error.details is Map
            ? error.details as Map
            : null;
        StartupTrace.notificationEvent('native_failed', {
          'native_id': entry.nativeId,
          'action': schedule == null ? 'cancel' : 'schedule',
          'error_type': error.runtimeType.toString(),
          if (error is PlatformException) 'platform_code': error.code,
          if (details?['domain'] is String) 'os_domain': details!['domain'],
          if (details?['code'] is int) 'os_code': details!['code'],
        });
      }
      rethrow;
    }
  }

  static Future<String> _testDatasetEpoch() async =>
      '00000000-0000-4000-8000-000000000001';

  final Future<String> Function() _readDatasetEpoch;
  String? _datasetEpoch;
  String? get datasetEpoch => _datasetEpoch;
  final _payloads = StreamController<String>.broadcast();
  final List<String> _pendingPayloads = [];
  Stream<String> get onNotificationPayload => _payloads.stream;
  List<String> takePendingNotificationPayloads() {
    final pending = List<String>.of(_pendingPayloads);
    _pendingPayloads.clear();
    return pending;
  }

  void _receiveNotificationResponse(NotificationResponse response) {
    if (response.notificationResponseType !=
            NotificationResponseType.selectedNotification ||
        (response.actionId?.isNotEmpty ?? false)) {
      return;
    }
    final payload = response.payload;
    if (NotificationPayload.tryParse(payload) == null) return;
    if (_payloads.hasListener) {
      _payloads.add(payload!);
    } else {
      if (_pendingPayloads.length >= 32) _pendingPayloads.removeAt(0);
      _pendingPayloads.add(payload!);
    }
  }

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin;
  final MacOSNotificationScheduler? macScheduler;
  final bool usesNativeNotifications;
  DateTime Function() _now = DateTime.now;
  Future<void>? _initialization;
  bool _initialized = false;
  bool _maintenance = false;
  bool _maintenanceReady = false;
  Future<void>? _pausing;
  bool _strictFailures = false;
  final Set<Future<void>> _operations = {};

  bool get isPausedForMaintenance => _maintenance;

  Future<void> _track(Future<void> Function() action) {
    final result = Future<void>.sync(action);
    late final Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() => _operations.remove(settled));
    _operations.add(settled);
    return result;
  }

  /// Stops timer delivery immediately, drains scheduling already in flight,
  /// then cancels native requests. A plugin error deliberately leaves it paused.
  Future<void> pauseForMaintenance() {
    if (_strictFailures) {
      return Future.error(
        StateError('Notification rebuilding is in progress.'),
      );
    }
    if (_pausing != null) return _pausing!;
    _maintenance = true;
    _maintenanceReady = false;
    _invalidateTimers();
    return _pausing = _drainAndCancelAll().whenComplete(() => _pausing = null);
  }

  Future<void> _drainAndCancelAll() async {
    await Future.wait(List<Future<void>>.of(_operations));
    await Future.wait(List<Future<void>>.of(_nativeOperations.values));
    if (usesNativeNotifications) {
      await flutterLocalNotificationsPlugin.cancelAll();
    }
    _maintenanceReady = true;
  }

  void _invalidateTimers() {
    _revisions.clear();
    _scheduledReminders.clear();
    for (final timer in _activeTimers.values) {
      timer.cancel();
    }
    _activeTimers.clear();
  }

  /// Caller supplies the final database state after commit or rollback. Errors
  /// are observable here, unlike legacy best-effort UI notification requests.
  Future<void> resumeFromReminders(Iterable<Reminder> reminders) async {
    if (!_maintenance || !_maintenanceReady || _strictFailures) {
      throw StateError('Notification maintenance is not ready to resume.');
    }
    _strictFailures = true;
    try {
      _datasetEpoch = await _readDatasetEpoch();
      if (_database != null && usesNativeNotifications) await init();
      final startedAt = _now();
      final batch = <Future<void>>[];
      for (final reminder in reminders) {
        if (!reminder.isCompleted &&
            reminder.noticeAcknowledgedAt == null &&
            (reminder.triggerTime?.isAfter(startedAt) ?? false)) {
          batch.add(_scheduleReminder(reminder));
          if (batch.length == reconciliationBatchSize) {
            // Default Future.wait drains every admitted task on failure before
            // cleanup cancels all native requests. No later batch is admitted.
            await Future.wait(batch);
            batch.clear();
          }
        }
      }
      await Future.wait(batch);
      _maintenance = false;
      _maintenanceReady = false;
      // Timers start only after the whole rebuild succeeds. An occurrence that
      // became due while native scheduling was blocked is delivered once now.
      for (final reminder in _scheduledReminders.values) {
        _armTimer(reminder, _revisions[reminder.id]!);
      }
    } catch (_) {
      _invalidateTimers();
      _maintenanceReady = false;
      if (usesNativeNotifications) {
        try {
          await flutterLocalNotificationsPlugin.cancelAll();
          _maintenanceReady = true;
        } catch (_) {
          // The caller keeps recovery blocked and can retry reconciliation.
        }
      } else {
        _maintenanceReady = true;
      }
      rethrow;
    } finally {
      _strictFailures = false;
    }
  }

  final Map<String, Timer> _activeTimers = {};
  final Map<String, int> _revisions = {};
  final Map<String, Future<void>> _nativeOperations = {};
  final Map<String, Reminder> _scheduledReminders = {};
  int _nextRevision = 0;
  final StreamController<Reminder> _reminderDueController =
      StreamController<Reminder>.broadcast();

  /// 沉浸备战专注模式开关（开启后底层静音拦截 Q3 和 Q4 通知）
  bool _isImmersiveModeActive = false;
  bool get isImmersiveModeActive => _isImmersiveModeActive;
  set isImmersiveModeActive(bool value) {
    if (_isImmersiveModeActive == value) return;
    _isImmersiveModeActive = value;
    unawaited(reconcileNotificationPolicy());
  }

  bool isSuppressed(Reminder reminder) {
    final profile = ContextTriggerService().currentProfile;
    return reminder.quadrantLevel >= 3 &&
        (isImmersiveModeActive ||
            profile == ContextProfile.office ||
            profile == ContextProfile.deepWork);
  }

  /// Reconcile future native requests when the session's focus policy changes.
  /// Timers remain active so suppressed due tasks can be recorded by the app.
  Future<void> reconcileNotificationPolicy() async {
    if (_maintenance) return;
    await Future.wait(
      List<Reminder>.of(_scheduledReminders.values)
          .where((r) => r.quadrantLevel >= 3 && r.triggerTime!.isAfter(_now()))
          .map(scheduleReminder),
    );
  }

  Stream<Reminder> get onReminderDue => _reminderDueController.stream;

  Future<void> init() {
    // UI route readiness calls init repeatedly. Reuse the completed native
    // initialization instead of reopening local files on every widget build.
    // Native mutations still read the durable epoch in _prepareJournal, and
    // recovery refreshes _datasetEpoch before requesting initialization.
    if (_initialized &&
        (_database == null ||
            !usesNativeNotifications ||
            (_journalEpoch != null && _journalEpoch == _datasetEpoch))) {
      return _initialization!;
    }
    return _track(() async {
      await _initializeOnce();
      if (_database != null && usesNativeNotifications && !_initialized) {
        throw StateError('Native notification initialization failed.');
      }
      // Capture cold-launch payloads before migration removes legacy notices.
      // Even an empty database needs this migration, otherwise old IDs from a
      // failed deletion could survive indefinitely with nothing to reschedule.
      if (_initialized && (!_maintenance || _strictFailures)) {
        await _prepareJournal();
      }
    });
  }

  Future<void> _initializeOnce() {
    if (_initialization != null) return _initialization!;
    late final Future<void> pending;
    pending = _initialize().whenComplete(() {
      if (!_initialized && identical(_initialization, pending)) {
        _initialization = null;
      }
    });
    return _initialization = pending;
  }

  Future<void> _initialize() async {
    try {
      tz.initializeTimeZones();
      _datasetEpoch = await _readDatasetEpoch();

      if (usesNativeNotifications) {
        const AndroidInitializationSettings initializationSettingsAndroid =
            AndroidInitializationSettings('@mipmap/ic_launcher');

        const DarwinInitializationSettings initializationSettingsDarwin =
            DarwinInitializationSettings(
              requestSoundPermission: false,
              requestBadgePermission: false,
              requestAlertPermission: false,
            );

        const InitializationSettings initializationSettings =
            InitializationSettings(
              android: initializationSettingsAndroid,
              iOS: initializationSettingsDarwin,
              macOS: initializationSettingsDarwin,
            );

        final initialized = await flutterLocalNotificationsPlugin.initialize(
          initializationSettings,
          onDidReceiveNotificationResponse: _receiveNotificationResponse,
        );
        // In plugin 17.2.x Darwin returns the authorization request result.
        // With every request flag false it returns false after successfully
        // registering callbacks. Android's false still means initialization
        // failed; exceptions on every platform remain failures.
        final darwin =
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS;
        if (initialized == false && !darwin) {
          throw StateError('Native notification initialization failed.');
        }
        final launch = await flutterLocalNotificationsPlugin
            .getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp == true &&
            launch?.notificationResponse != null) {
          _receiveNotificationResponse(launch!.notificationResponse!);
        }
      }
      _initialized = true;
    } catch (e) {
      if (_strictFailures) rethrow;
      debugPrint('Notification init error: $e');
    }
  }

  Future<void> scheduleReminder(Reminder reminder) {
    if (_maintenance) {
      return Future.error(
        StateError('Notifications are paused for maintenance.'),
      );
    }
    return _track(() => _scheduleReminder(reminder));
  }

  /// Interactive persistence already succeeded. Let the caller report a native
  /// failure separately instead of treating the saved task as a failed write.
  Future<void> scheduleReminderStrict(Reminder reminder) {
    if (_maintenance) {
      return Future.error(
        StateError('Notifications are paused for maintenance.'),
      );
    }
    return _track(() => _scheduleReminder(reminder, strict: true));
  }

  Future<void> _scheduleReminder(
    Reminder reminder, {
    bool strict = false,
  }) async {
    // Invalidate older schedules immediately, before cancellation or permission
    // requests yield. Native mutations for one task must also finish in order.
    final revision = ++_nextRevision;
    _revisions[reminder.id] = revision;
    _scheduledReminders.remove(reminder.id);
    if (reminder.triggerTime != null &&
        !reminder.isCompleted &&
        reminder.noticeAcknowledgedAt == null) {
      _scheduledReminders[reminder.id] = reminder;
    }
    _activeTimers.remove(reminder.id)?.cancel();
    await _cancelNative(reminder.id, strict: strict);

    if (_revisions[reminder.id] != revision ||
        reminder.triggerTime == null ||
        reminder.isCompleted ||
        reminder.noticeAcknowledgedAt != null) {
      return;
    }

    // Initialize lazily when a reminder is actually requested. Concurrent
    // schedules share one permission/initialization request.
    await init();
    if (_revisions[reminder.id] != revision) return;
    if (!_initialized && (strict || _strictFailures)) {
      throw StateError('Native notification initialization failed.');
    }
    final epoch = await _readDatasetEpoch();
    if (_revisions[reminder.id] != revision) return;
    _datasetEpoch = epoch;

    final now = _now();
    final difference = reminder.triggerTime!.difference(now);

    // If already overdue
    if (difference.isNegative) {
      if (_maintenance) return;
      _scheduledReminders.remove(reminder.id);
      // If it passed within the last 30 seconds, fire it immediately
      if (difference.inSeconds > -30) {
        fireReminderNow(reminder);
      }
      return;
    }

    // In-process timer for all platforms (vital on Windows)
    if (!_maintenance) _armTimer(reminder, revision);

    // Native mobile/Darwin scheduling if supported
    if (usesNativeNotifications && !isSuppressed(reminder)) {
      try {
        String channelId;
        String channelName;
        String channelDescription;
        Priority priority;
        Importance importance;
        bool enableVibration = false;
        bool playSound = false;

        if (reminder.quadrantLevel == 1) {
          channelId = 'q1_channel';
          channelName = 'Urgent & Important';
          channelDescription = 'High priority alerts with sound and vibration';
          priority = Priority.high;
          importance = Importance.max;
          enableVibration = true;
          playSound = true;
        } else if (reminder.quadrantLevel == 2) {
          channelId = 'q2_channel';
          channelName = 'Important';
          channelDescription = 'Standard priority alerts';
          priority = Priority.defaultPriority;
          importance = Importance.defaultImportance;
          enableVibration = true;
          playSound = true;
        } else {
          channelId = 'q34_channel';
          channelName = 'General Reminders';
          channelDescription = 'Low priority silent alerts';
          priority = Priority.low;
          importance = Importance.low;
          enableVibration = false;
          playSound = false;
        }

        final androidPlatformChannelSpecifics = AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: importance,
          priority: priority,
          enableVibration: enableVibration,
          playSound: playSound,
          fullScreenIntent: reminder.quadrantLevel == 1,
        );

        final platformChannelSpecifics = NotificationDetails(
          android: androidPlatformChannelSpecifics,
          iOS: DarwinNotificationDetails(
            presentSound: playSound,
            presentAlert: true,
            presentBadge: true,
            interruptionLevel: reminder.quadrantLevel == 1
                ? InterruptionLevel.timeSensitive
                : InterruptionLevel.active,
          ),
          macOS: DarwinNotificationDetails(
            presentSound: playSound,
            presentAlert: true,
            presentBadge: true,
          ),
        );

        await _enqueueNative(reminder.id, () async {
          if (_revisions[reminder.id] != revision || isSuppressed(reminder)) {
            return;
          }
          await _journalNative(reminder.id, (nativeId) {
            final payload = NotificationPayload.forReminder(
              reminder,
              datasetEpoch: epoch,
            ).encode();
            final mac = macScheduler;
            if (mac != null) {
              return mac.schedule(
                nativeId: nativeId,
                title: reminder.taskTitle,
                body: reminder.taskSummary ?? 'You have a scheduled task',
                trigger: reminder.triggerTime!,
                playSound: playSound,
                payload: payload,
              );
            }
            return flutterLocalNotificationsPlugin.zonedSchedule(
              nativeId,
              reminder.taskTitle,
              reminder.taskSummary ?? 'You have a scheduled task',
              tz.TZDateTime.from(reminder.triggerTime!, tz.local),
              platformChannelSpecifics,
              androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
              uiLocalNotificationDateInterpretation:
                  UILocalNotificationDateInterpretation.absoluteTime,
              payload: payload,
            );
          }, schedule: reminder);
        });
      } catch (e) {
        if (strict || _strictFailures) rethrow;
        debugPrint('Mobile zonedSchedule error: $e');
      }
    }
  }

  void _armTimer(Reminder reminder, int revision) {
    final remaining = reminder.triggerTime!.difference(_now());
    _activeTimers[reminder.id] = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        if (!_maintenance && _revisions[reminder.id] == revision) {
          _scheduledReminders.remove(reminder.id);
          fireReminderNow(reminder);
        }
      },
    );
  }

  Future<void> cancelReminder(String id) {
    if (_maintenance) {
      return Future.error(
        StateError('Notifications are paused for maintenance.'),
      );
    }
    return _track(() => _cancelReminder(id));
  }

  Future<void> cancelReminderStrict(String id) {
    if (_maintenance) {
      return Future.error(
        StateError('Notifications are paused for maintenance.'),
      );
    }
    return _track(() => _cancelReminder(id, strict: true));
  }

  Future<void> _cancelReminder(String id, {bool strict = false}) async {
    _revisions.remove(id);
    _scheduledReminders.remove(id);
    _activeTimers.remove(id)?.cancel();
    await _cancelNative(id, strict: strict);
  }

  Future<void> _enqueueNative(String id, Future<void> Function() action) async {
    final previous = _nativeOperations[id] ?? Future<void>.value();
    final next = previous.then((_) => action());
    // Keep the queue usable after a plugin failure; the caller still receives
    // that failure through `next`.
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _nativeOperations[id] = settled;
    try {
      await next;
    } finally {
      if (identical(_nativeOperations[id], settled)) {
        _nativeOperations.remove(id);
      }
    }
  }

  Future<void> _cancelNative(String id, {bool strict = false}) async {
    if (usesNativeNotifications) {
      try {
        await _enqueueNative(
          id,
          () => _journalNative(id, flutterLocalNotificationsPlugin.cancel),
        );
      } catch (_) {
        if (strict || _strictFailures) rethrow;
      }
    }
  }

  Future<void> fireReminderNow(Reminder reminder) {
    if (_maintenance) return Future<void>.value();
    return _track(() => _fireReminderNow(reminder));
  }

  Future<void> _fireReminderNow(Reminder reminder) async {
    if (reminder.isCompleted || reminder.noticeAcknowledgedAt != null) return;
    _activeTimers.remove(reminder.id)?.cancel();
    _scheduledReminders.remove(reminder.id);

    // 高压场景专注模式：拦截并静音所有“紧急不重要 (Q3)”和“不重要不紧急 (Q4)”的通知
    if (isImmersiveModeActive &&
        (reminder.quadrantLevel == 3 || reminder.quadrantLevel == 4)) {
      debugPrint(
        '[沉浸模式拦截] 已静音跳过低优先级提醒: [Q${reminder.quadrantLevel}] ${reminder.taskTitle}',
      );
      return;
    }

    // 情境感知模式拦截：办公与深度专注情境下静音拦截次要通知并入队待生成事后摘要
    if (ContextTriggerService().shouldInterceptNotification(reminder)) {
      debugPrint(
        '[情境感知拦截] 处于办公/专注情境，拦截并记录次要提醒: [Q${reminder.quadrantLevel}] ${reminder.taskTitle}',
      );
      return;
    }

    // Notify UI / Stream listeners
    _reminderDueController.add(reminder);

    // Native notifications own the sound policy. Do not add another app sound
    // or steal keyboard focus when an occurrence arrives.
    if (Platform.isWindows) {
      final summary =
          reminder.taskSummary != null && reminder.taskSummary!.isNotEmpty
          ? reminder.taskSummary!
          : '您设置的待办事项时间已到，请及时处理！';

      await showWindowsToast(
        reminder.taskTitle,
        summary,
        playSound: reminder.quadrantLevel <= 2,
      );
    }
  }

  Future<void> showWindowsToast(
    String title,
    String body, {
    bool playSound = true,
  }) async {
    try {
      final safeTitle = title
          .replaceAll("'", "''")
          .replaceAll('`', '``')
          .replaceAll(r'$', r'`$')
          .replaceAll('\r', '')
          .replaceAll('\n', ' ');
      final safeBody = body
          .replaceAll("'", "''")
          .replaceAll('`', '``')
          .replaceAll(r'$', r'`$')
          .replaceAll('\r', '')
          .replaceAll('\n', ' ');

      final script =
          '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null
\$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
\$textNodes = \$template.GetElementsByTagName('text')
\$textNodes.Item(0).AppendChild(\$template.CreateTextNode('$safeTitle')) > \$null
\$textNodes.Item(1).AppendChild(\$template.CreateTextNode('$safeBody')) > \$null
\$audio = \$template.CreateElement('audio')
\$audio.SetAttribute('silent', '${!playSound}')
\$template.DocumentElement.AppendChild(\$audio) > \$null
\$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Don't Forget")
\$notification = [Windows.UI.Notifications.ToastNotification]::new(\$template)
\$notifier.Show(\$notification)
''';

      await Process.run('powershell', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        script,
      ]);
    } catch (e) {
      debugPrint('Windows Toast Error: $e');
    }
  }
}
