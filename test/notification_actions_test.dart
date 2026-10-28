import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/services/notification_epoch_store.dart';
import 'package:dont_forget/services/notification_route_service.dart';
import 'package:dont_forget/services/pending_notification_actions.dart';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  bool failCancel = false;
  bool failSchedule = false;
  bool failInitialize = false;
  int schedules = 0;
  int cancellations = 0;
  final Set<int> pending = {};

  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        return failInitialize
            ? Future<bool>.error(StateError('Synthetic initialization failure'))
            : Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value(
          const NotificationAppLaunchDetails(false),
        );
      case #cancel:
        cancellations++;
        if (failCancel) {
          return Future<void>.error(StateError('Synthetic cancel failure'));
        }
        pending.remove(call.positionalArguments.first);
        return Future<void>.value();
      case #cancelAll:
        pending.clear();
        return Future<void>.value();
      case #zonedSchedule:
        schedules++;
        if (failSchedule) {
          return Future<void>.error(StateError('Synthetic scheduling failure'));
        }
        pending.add(call.positionalArguments.first as int);
        return Future<void>.value();
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2030, 1, 1, 9, 1);
  late Directory directory;
  late DatabaseHelper helper;
  late Database db;
  late _Native native;
  late NotificationService notifications;
  RemindersNotifier? notifier;

  Reminder task(String id, {bool recurring = false}) => Reminder(
    id: id,
    taskTitle: 'Synthetic $id',
    quadrantLevel: 2,
    triggerTime: DateTime(2030, 1, 1, 9),
    eventTime: DateTime(2030, 1, 1, 10),
    isRecurring: recurring,
    recurrenceRule: recurring ? 'daily' : 'none',
  );
  Future<RemindersNotifier> load(Reminder item) async {
    await db.insert('Reminders', item.toJson());
    final value = notifier = RemindersNotifier(
      helper,
      notifications: notifications,
      runLoadEffects: false,
    );
    await value.ready;
    return value;
  }

  Future<NotificationPayload> payload(Reminder item) async =>
      NotificationPayload.forReminder(
        item,
        datasetEpoch: await helper.readNotificationEpoch(),
      );
  Future<Reminder> stored(String id) async => Reminder.fromJson(
    (await db.query('Reminders', where: 'id = ?', whereArgs: [id])).single,
  );
  Future<ReminderActionResult> apply(
    Reminder item,
    String action, {
    DateTime? occurredAt,
    NotificationPayload? encoded,
  }) async => notifier!.performNotificationAction(
    item,
    payload: encoded ?? await payload(item),
    actionId: action,
    occurredAt: occurredAt ?? now,
    now: now,
  );

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('notification-actions-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    db = await helper.database;
    native = _Native();
    notifications = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      database: helper,
      now: () => now,
    );
    notifier = null;
  });
  tearDown(() async {
    notifier?.dispose();
    await notifications.pauseForMaintenance();
    await helper.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  for (final recurring in [false, true]) {
    test(
      'complete notification recurring=$recurring and duplicate is inert',
      () async {
        final item = task('complete', recurring: recurring);
        await load(item);
        final encoded = await payload(item);
        final first = await apply(item, 'complete', encoded: encoded);
        expect(first.disposition, ReminderActionDisposition.applied);
        final saved = await stored(item.id);
        expect(saved.isCompleted, !recurring);
        expect(saved.noticeRevision, 1);
        if (recurring) expect(saved.triggerTime, DateTime(2030, 1, 2, 9));
        final count = native.schedules + native.cancellations;
        expect(
          (await apply(item, 'complete', encoded: encoded)).disposition,
          ReminderActionDisposition.stale,
        );
        expect((await stored(item.id)).toJson(), saved.toJson());
        expect(native.schedules + native.cancellations, count);
      },
    );
  }
  for (final minutes in [15, 60]) {
    test(
      'snooze $minutes uses action instant and preserves event/anchor',
      () async {
        final item = task('snooze', recurring: true);
        await load(item);
        final happened = now.subtract(const Duration(seconds: 30));
        final result = await apply(
          item,
          'snooze_$minutes',
          occurredAt: happened,
        );
        expect(result.disposition, ReminderActionDisposition.applied);
        final saved = await stored(item.id);
        expect(saved.triggerTime, happened.add(Duration(minutes: minutes)));
        expect(saved.eventTime, item.eventTime);
        expect(saved.recurrenceAnchorTime, item.triggerTime);
        expect(saved.recurrenceEventAnchorTime, item.eventTime);
        expect(saved.isCompleted, isFalse);
      },
    );
  }
  test('deferred snooze is at least a minute after processing', () async {
    final item = task('deferred', recurring: true);
    await load(item);
    await apply(
      item,
      'snooze_15',
      occurredAt: now.subtract(const Duration(hours: 1)),
    );
    expect(
      (await stored(item.id)).triggerTime,
      now.add(const Duration(minutes: 1)),
    );
  });
  test('skip only advances recurring tasks without completion', () async {
    final item = task('skip', recurring: true);
    await load(item);
    expect((await apply(item, 'skip_occurrence')).accepted, isTrue);
    final saved = await stored(item.id);
    expect(saved.isCompleted, isFalse);
    expect(saved.triggerTime, DateTime(2030, 1, 2, 9));
    expect(saved.details.history.last.action, 'skipped');
  });
  test('one-off skip is rejected', () async {
    final item = task('one-off');
    await load(item);
    expect(
      (await apply(item, 'skip_occurrence')).disposition,
      ReminderActionDisposition.stale,
    );
    expect((await stored(item.id)).toJson(), item.toJson());
  });
  for (final mismatch in ['trigger', 'revision', 'dataset']) {
    test('transaction rechecks $mismatch mismatch', () async {
      final item = task('stale');
      await load(item);
      final old = await payload(item);
      if (mismatch == 'dataset') {
        await NotificationEpochStore(Directory(await directory.resolveSymbolicLinks())).rotate();
      } else {
        final changed = mismatch == 'trigger'
            ? item.copyWith(triggerTime: now.add(const Duration(hours: 1)))
            : item.copyWith(noticeRevision: 3);
        await db.update(
          'Reminders',
          changed.toJson(),
          where: 'id = ?',
          whereArgs: [item.id],
        );
      }
      expect(
        (await apply(item, 'complete', encoded: old)).disposition,
        ReminderActionDisposition.stale,
      );
      expect((await stored(item.id)).isCompleted, isFalse);
      expect(native.cancellations, 0);
      expect(native.schedules, 0);
    });
  }
  test(
    'failed cleanup commits once, preserves journal repair and consumes intent',
    () async {
      final item = task('cleanup');
      await load(item);
      await notifications.scheduleReminderStrict(
        item.copyWith(triggerTime: now.add(const Duration(days: 1))),
      );
      native.failCancel = true;
      final queue = PendingNotificationActions.forDirectory(
        Directory('${directory.path}/actions'),
      );
      await queue.enqueue(
        NotificationActionRequest(
          payload: await payload(item),
          actionId: 'complete',
          occurredAt: now,
        ),
      );
      final outcomes = <NotificationActionOutcome>[];
      final router = NotificationActionRouteService(
        readQueue: () async => queue,
        readSnapshot: () => NotificationRouteSnapshot(
          datasetEpoch: notifications.datasetEpoch!,
          reminders: notifier!.state,
        ),
        apply: (current, request) async {
          final result = await apply(
            current,
            request.actionId,
            encoded: request.payload,
          );
          return result.nativeSyncFailed
              ? NotificationActionOutcome.repair
              : NotificationActionOutcome.applied;
        },
        onResult: outcomes.add,
      );
      await router.setReady(true);
      expect((await stored(item.id)).isCompleted, isTrue);
      expect(outcomes, [NotificationActionOutcome.repair]);
      expect(await queue.read(), isEmpty);
      final journal = await helper.withNotificationJournal((j) => j.read());
      expect(journal!.entries[item.id]!.status, 'failed');
      expect(journal.entries[item.id]!.action, 'cancel');
      router.dispose();
    },
  );
  test(
    'restart waits for ready, drops rotated dataset, and consumes once',
    () async {
      final item = task('restart', recurring: true);
      await load(item);
      final dir = Directory('${directory.path}/actions');
      final queue = PendingNotificationActions.forDirectory(dir);
      final request = NotificationActionRequest(
        payload: await payload(item),
        actionId: 'snooze_15',
        occurredAt: now,
      );
      await queue.enqueue(request);
      var ready = false;
      final router = NotificationActionRouteService(
        readQueue: () async => PendingNotificationActions.forDirectory(dir),
        readSnapshot: () => ready
            ? NotificationRouteSnapshot(
                datasetEpoch: request.payload.datasetEpoch,
                reminders: notifier!.state,
              )
            : null,
        apply: (current, request) async {
          final result = await apply(
            current,
            request.actionId,
            encoded: request.payload,
          );
          return result.accepted
              ? NotificationActionOutcome.applied
              : NotificationActionOutcome.rejected;
        },
      );
      await router.setReady(true);
      expect(await queue.read(), hasLength(1));
      ready = true;
      await Future.wait([router.flush(), router.flush()]);
      expect(await queue.read(), isEmpty);
      final saved = await stored(item.id);
      expect(saved.noticeRevision, 1);
      await queue.enqueue(request);
      await router.flush();
      expect((await stored(item.id)).noticeRevision, 1);
      expect(await queue.read(), isEmpty);
      router.dispose();
    },
  );
}
