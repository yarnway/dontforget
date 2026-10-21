import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import '../models/reminder.dart';
import 'context_trigger_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal()
    : flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin(),
      usesNativeNotifications = !Platform.isWindows && !Platform.isLinux;

  @visibleForTesting
  NotificationService.forTesting(
    this.flutterLocalNotificationsPlugin, {
    required this.usesNativeNotifications,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin;
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
      final startedAt = _now();
      for (final reminder in reminders) {
        if (!reminder.isCompleted &&
            (reminder.triggerTime?.isAfter(startedAt) ?? false)) {
          await _scheduleReminder(reminder);
        }
      }
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

      if (usesNativeNotifications) {
        const AndroidInitializationSettings initializationSettingsAndroid =
            AndroidInitializationSettings('@mipmap/ic_launcher');

        const DarwinInitializationSettings initializationSettingsDarwin =
            DarwinInitializationSettings(
              requestSoundPermission: true,
              requestBadgePermission: true,
              requestAlertPermission: true,
            );

        const InitializationSettings initializationSettings =
            InitializationSettings(
              android: initializationSettingsAndroid,
              iOS: initializationSettingsDarwin,
              macOS: initializationSettingsDarwin,
            );

        final initialized = await flutterLocalNotificationsPlugin.initialize(
          initializationSettings,
          onDidReceiveNotificationResponse: (details) {
            // Handle notification tap
          },
        );
        if (initialized == false) {
          throw StateError('Native notification initialization failed.');
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

  Future<void> _scheduleReminder(Reminder reminder) async {
    // Invalidate older schedules immediately, before cancellation or permission
    // requests yield. Native mutations for one task must also finish in order.
    final revision = ++_nextRevision;
    _revisions[reminder.id] = revision;
    _scheduledReminders.remove(reminder.id);
    if (reminder.triggerTime != null && !reminder.isCompleted) {
      _scheduledReminders[reminder.id] = reminder;
    }
    _activeTimers.remove(reminder.id)?.cancel();
    await _cancelNative(reminder.id);

    if (_revisions[reminder.id] != revision ||
        reminder.triggerTime == null ||
        reminder.isCompleted) {
      return;
    }

    // Initialize lazily when a reminder is actually requested. Concurrent
    // schedules share one permission/initialization request.
    await init();
    if (_revisions[reminder.id] != revision) return;

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
          await flutterLocalNotificationsPlugin.zonedSchedule(
            reminder.id.hashCode,
            reminder.taskTitle,
            reminder.taskSummary ?? 'You have a scheduled task',
            tz.TZDateTime.from(reminder.triggerTime!, tz.local),
            platformChannelSpecifics,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
          );
        });
      } catch (e) {
        if (_strictFailures) rethrow;
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

  Future<void> _cancelReminder(String id) async {
    _revisions.remove(id);
    _scheduledReminders.remove(id);
    _activeTimers.remove(id)?.cancel();
    await _cancelNative(id);
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

  Future<void> _cancelNative(String id) async {
    if (usesNativeNotifications) {
      try {
        await _enqueueNative(
          id,
          () => flutterLocalNotificationsPlugin.cancel(id.hashCode),
        );
      } catch (_) {
        if (_strictFailures) rethrow;
      }
    }
  }

  Future<void> fireReminderNow(Reminder reminder) {
    if (_maintenance) return Future<void>.value();
    return _track(() => _fireReminderNow(reminder));
  }

  Future<void> _fireReminderNow(Reminder reminder) async {
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
