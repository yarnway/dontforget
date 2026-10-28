import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/database_helper.dart';
import '../models/notification_schedule_status.dart';
import 'macos_notification_scheduler.dart';
import 'notification_permission_service.dart';
import 'notification_service.dart';
import 'system_notification_reader.dart';

enum TestNotificationResult { submitted, permissionDenied, unsupported, failed }

class NotificationFailureHistory {
  const NotificationFailureHistory({
    required this.available,
    this.latestFailure,
  });
  final bool available;
  final DateTime? latestFailure;

  static Future<NotificationFailureHistory> read(
    DatabaseHelper database,
  ) async {
    final generation = database.captureGeneration();
    return database.runOperation(generation, () async {
      final journal = await database.withNotificationJournal((j) => j.read());
      database.checkGeneration(generation);
      final epoch = await database.readNotificationEpoch();
      database.checkGeneration(generation);
      if (journal == null || journal.epoch != epoch) {
        return const NotificationFailureHistory(available: false);
      }
      DateTime? latest;
      for (final entry in journal.entries.values) {
        if (entry.status != 'failed') continue;
        final at = DateTime.tryParse(entry.attemptedAt ?? '');
        if (at != null && (latest == null || at.isAfter(latest))) latest = at;
      }
      return NotificationFailureHistory(available: true, latestFailure: latest);
    });
  }
}

class NotificationDiagnosticsSnapshot {
  const NotificationDiagnosticsSnapshot({
    required this.permission,
    this.pendingCount,
    this.schedule,
    this.failureHistory,
  });
  final NotificationPermissionSnapshot permission;
  final int? pendingCount;
  final NotificationScheduleStatus? schedule;
  final NotificationFailureHistory? failureHistory;
}

/// A diagnostic request has no business payload, database row or journal entry.
/// Zero is outside the business journal's positive native ID allocation range.
abstract interface class TestNotificationBackend {
  bool get supportsNativeScheduling;
  Future<void> cancel();
  Future<void> schedule({
    required String title,
    required String body,
    required DateTime trigger,
  });
}

class PluginTestNotificationBackend implements TestNotificationBackend {
  const PluginTestNotificationBackend({
    required this.plugin,
    required this.supportsNativeScheduling,
    this.macScheduler,
  });
  static const nativeId = 0;
  static const payload = 'dontforget:test:v1';
  final FlutterLocalNotificationsPlugin plugin;
  final MacOSNotificationScheduler? macScheduler;
  @override
  final bool supportsNativeScheduling;

  @override
  Future<void> cancel() => plugin.cancel(nativeId);

  @override
  Future<void> schedule({
    required String title,
    required String body,
    required DateTime trigger,
  }) {
    final mac = macScheduler;
    if (mac != null) {
      return mac.schedule(
        nativeId: nativeId,
        title: title,
        body: body,
        trigger: trigger,
        playSound: true,
        payload: payload,
      );
    }
    return plugin.zonedSchedule(
      nativeId,
      title,
      body,
      tz.TZDateTime.from(trigger, tz.UTC),
      NotificationDetails(
        android: AndroidNotificationDetails(
          'notification_diagnostics',
          title,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: false,
        ),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: false,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }
}

class NotificationDiagnosticsService {
  NotificationDiagnosticsService({
    required this.permissions,
    required this.backend,
    required this.readSystem,
    required this.readSchedule,
    required this.readFailureHistory,
    DateTime Function()? now,
    this.checkCurrent,
    this.readTimeout = const Duration(seconds: 3),
  }) : _now = now ?? DateTime.now;

  factory NotificationDiagnosticsService.forNotifications(
    NotificationService notifications, {
    required DatabaseHelper database,
    required Future<NotificationScheduleStatus> Function() readSchedule,
    Future<NotificationFailureHistory> Function()? readFailureHistory,
    void Function()? checkCurrent,
  }) => NotificationDiagnosticsService(
    permissions: NotificationPermissionService(
      backend: PluginNotificationPermissionBackend(
        plugin: notifications.flutterLocalNotificationsPlugin,
      ),
    ),
    backend: PluginTestNotificationBackend(
      plugin: notifications.flutterLocalNotificationsPlugin,
      supportsNativeScheduling: notifications.usesNativeNotifications,
      macScheduler: notifications.macScheduler,
    ),
    readSystem: notifications.readSystemNotifications,
    readSchedule: readSchedule,
    readFailureHistory:
        readFailureHistory ?? () => NotificationFailureHistory.read(database),
    checkCurrent: checkCurrent,
  );

  final NotificationPermissionService permissions;
  final TestNotificationBackend backend;
  final Future<SystemNotificationSnapshot> Function() readSystem;
  final Future<NotificationScheduleStatus> Function() readSchedule;
  final Future<NotificationFailureHistory> Function() readFailureHistory;
  final DateTime Function() _now;
  final void Function()? checkCurrent;
  final Duration readTimeout;
  Future<void>? _tail;
  final _cancelObservations = <void Function()>{};

  bool get supportsNativeScheduling => backend.supportsNativeScheduling;

  Future<T?> _observe<T>(Future<T> Function() query) {
    final result = Completer<T?>();
    late final Timer timeout;
    late final void Function() cancel;
    void finish(T? value) {
      if (result.isCompleted) return;
      timeout.cancel();
      _cancelObservations.remove(cancel);
      result.complete(value);
    }

    cancel = () => finish(null);
    timeout = Timer(readTimeout, cancel);
    _cancelObservations.add(cancel);
    Future<T>.sync(
      query,
    ).then(finish, onError: (Object _, StackTrace __) => finish(null));
    return result.future;
  }

  /// Leaving an observer cancels only its read deadlines, never a submitted
  /// test request. Late platform/file results are still safely observed.
  void cancelReads() {
    for (final cancel in List.of(_cancelObservations)) {
      cancel();
    }
  }

  Future<NotificationDiagnosticsSnapshot> refresh() async {
    final permission = permissions.refresh();
    final system = _observe(readSystem);
    final schedule = _observe(readSchedule);
    final history = _observe(readFailureHistory);
    return NotificationDiagnosticsSnapshot(
      permission: await permission,
      pendingCount: (await system)?.pending?.length,
      schedule: await schedule,
      failureHistory: await history,
    );
  }

  /// Serialize replacements so a slow first click cannot overtake the next.
  Future<TestNotificationResult> sendTest({
    required String title,
    required String body,
  }) {
    Future<TestNotificationResult> submit() async {
      if (!supportsNativeScheduling) return TestNotificationResult.unsupported;
      try {
        checkCurrent?.call();
        await backend.cancel();
        checkCurrent?.call();
        final permission = await permissions.refresh();
        checkCurrent?.call();
        if (permission.authorization.status ==
            NotificationPermissionStatus.notEnabled) {
          return TestNotificationResult.permissionDenied;
        }
        await backend.schedule(
          title: title,
          body: body,
          trigger: _now().add(const Duration(seconds: 5)),
        );
        return TestNotificationResult.submitted;
      } catch (_) {
        return TestNotificationResult.failed;
      }
    }

    final result = _tail == null ? submit() : _tail!.then((_) => submit());
    _tail = result.then<void>((_) {});
    return result;
  }
}
