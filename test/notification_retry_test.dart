import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  @override
  Future<void> init() async {}

  @override
  bool isPausedForMaintenance = false;
  final List<Reminder> scheduled = [];
  final List<String> cancelled = [];
  final Set<String> failures = {};
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<void> scheduleReminderStrict(Reminder reminder) async {
    scheduled.add(reminder);
    if (entered?.isCompleted == false) entered!.complete();
    await release?.future;
    if (failures.contains(reminder.id)) {
      throw StateError('native schedule failed');
    }
  }

  @override
  Future<void> cancelReminderStrict(String id) async {
    cancelled.add(id);
    if (failures.contains(id)) throw StateError('native cancel failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2030, 1, 1, 12);
  late Directory directory;
  late DatabaseHelper helper;
  late Database database;
  late _Notifications notifications;
  RemindersNotifier? notifier;

  Reminder task(String id) => Reminder(
    id: id,
    taskTitle: id,
    quadrantLevel: 3,
    triggerTime: now.add(const Duration(days: 1)),
    noticeRevision: 7,
  );

  Future<RemindersNotifier> load() async {
    final result = notifier = RemindersNotifier(
      helper,
      notifications: notifications,
      runLoadEffects: false,
    );
    await result.ready;
    return result;
  }

  Future<void> seed(Reminder reminder) =>
      database.insert('Reminders', reminder.toJson());

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('notification-retry-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    database = await helper.database;
    notifications = _Notifications();
    notifier = null;
  });

  tearDown(() async {
    notifier?.dispose();
    await helper.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  test(
    'strict retry processes all saved tasks, collects failures and never changes rows',
    () async {
      for (final reminder in [
        task('future-a'),
        task('future-b'),
        task('confirmed').copyWith(noticeAcknowledgedAt: now),
        task('completed').copyWith(isCompleted: true),
        task('untimed').copyWith(triggerTime: null),
        task(
          'overdue',
        ).copyWith(triggerTime: now.subtract(const Duration(minutes: 1))),
      ]) {
        await seed(reminder);
      }
      final current = await load();
      final before = await database.query('Reminders', orderBy: 'id');
      notifications.failures.addAll(['future-a', 'confirmed']);
      final result = await current.retryNotificationDelivery(now: now);
      expect(result, (attempted: 5, failed: 2));
      expect(notifications.scheduled.map((r) => r.id), [
        'future-a',
        'future-b',
      ]);
      expect(notifications.cancelled, ['confirmed', 'completed', 'untimed']);
      expect(await database.query('Reminders', orderBy: 'id'), before);
      expect(
        current.state
            .singleWhere((r) => r.id == 'overdue')
            .noticeAcknowledgedAt,
        isNull,
      );
      notifications.failures.clear();
      expect(await current.retryNotificationDelivery(now: now), (
        attempted: 5,
        failed: 0,
      ));
    },
  );

  test(
    'retry reads saved data even when UI state has not loaded the new row',
    () async {
      final current = await load();
      await seed(task('saved-after-load'));
      expect(current.state, isEmpty);
      expect(await current.retryNotificationDelivery(now: now), (
        attempted: 1,
        failed: 0,
      ));
      expect(notifications.scheduled.single.id, 'saved-after-load');
      expect(current.state, isEmpty);
    },
  );

  test(
    'overdue tasks alone are left untouched without replaying native delivery',
    () async {
      await seed(
        task(
          'past',
        ).copyWith(triggerTime: now.subtract(const Duration(seconds: 10))),
      );
      final current = await load();
      expect(await current.retryNotificationDelivery(now: now), (
        attempted: 0,
        failed: 0,
      ));
      expect(notifications.scheduled, isEmpty);
      expect(notifications.cancelled, isEmpty);
    },
  );

  test(
    'notification maintenance blocks retry before any native calls',
    () async {
      await seed(task('future'));
      final current = await load();
      notifications.isPausedForMaintenance = true;
      await expectLater(
        current.retryNotificationDelivery(now: now),
        throwsStateError,
      );
      expect(notifications.scheduled, isEmpty);
      expect(notifications.cancelled, isEmpty);
    },
  );

  test(
    'database maintenance drains admitted work and rejects queued old retries',
    () async {
      await seed(task('first'));
      await seed(task('second'));
      final current = await load();
      notifications.entered = Completer<void>();
      notifications.release = Completer<void>();
      final first = current.retryNotificationDelivery(now: now);
      await notifications.entered!.future;
      final queued = current.retryNotificationDelivery(now: now);
      final firstRejected = expectLater(
        first,
        throwsA(isA<DatabaseAccessException>()),
      );
      final queuedRejected = expectLater(
        queued,
        throwsA(isA<DatabaseAccessException>()),
      );
      var maintenanceGranted = false;
      final maintaining = helper.beginMaintenance().then((lease) {
        maintenanceGranted = true;
        return lease;
      });
      expect(maintenanceGranted, isFalse);
      notifications.release!.complete();
      await Future.wait([firstRejected, queuedRejected]);
      final lease = await maintaining;
      expect(notifications.scheduled.map((r) => r.id), ['first']);
      await lease.resume();
      await expectLater(
        current.retryNotificationDelivery(now: now),
        throwsA(isA<DatabaseAccessException>()),
      );
      current.dispose();
      notifier = null;
      notifications.release = null;
      final reloaded = await load();
      expect(await reloaded.retryNotificationDelivery(now: now), (
        attempted: 2,
        failed: 0,
      ));
    },
  );

  test(
    'disposing the notifier during native work stops the rest of the retry',
    () async {
      await seed(task('first'));
      await seed(task('second'));
      final current = await load();
      notifications.entered = Completer<void>();
      notifications.release = Completer<void>();
      final retry = current.retryNotificationDelivery(now: now);
      await notifications.entered!.future;
      final rejected = expectLater(retry, throwsStateError);
      current.dispose();
      notifier = null;
      notifications.release!.complete();
      await rejected;
      expect(notifications.scheduled.map((r) => r.id), ['first']);
    },
  );
}
