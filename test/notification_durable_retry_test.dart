import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:dont_forget/services/notification_epoch_store.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/notification_schedule_reader.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
  final calls = <String>[];
  bool failCancel = false;
  bool failSchedule = false;
  bool failInitialize = false;
  String? launchPayload;
  void Function()? onSchedule;
  @override
  dynamic noSuchMethod(Invocation i) {
    switch (i.memberName) {
      case #initialize:
        if (failInitialize) {
          return Future<bool>.error(
            StateError('synthetic initialization failure'),
          );
        }
        return Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        calls.add('launch');
        return Future.value(
          NotificationAppLaunchDetails(
            launchPayload != null,
            notificationResponse: launchPayload == null
                ? null
                : NotificationResponse(
                    notificationResponseType:
                        NotificationResponseType.selectedNotification,
                    payload: launchPayload,
                  ),
          ),
        );
      case #cancelAll:
        calls.add('cancelAll');
        pending.clear();
        return Future<void>.value();
      case #cancel:
        final id = i.positionalArguments[0] as int;
        calls.add('cancel:$id');
        if (failCancel) {
          return Future<void>.error(
            StateError('synthetic cancellation failure'),
          );
        }
        pending.remove(id);
        return Future<void>.value();
      case #zonedSchedule:
        final id = i.positionalArguments[0] as int;
        calls.add('schedule:$id');
        onSchedule?.call();
        if (failSchedule) {
          return Future<void>.error(StateError('synthetic scheduling failure'));
        }
        pending[id] = i.namedArguments[#payload] as String;
        return Future<void>.value();
      default:
        throw UnsupportedError('${i.memberName}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper helper;
  late NotificationService service;
  late RemindersNotifier notifier;
  late _Native native;

  Reminder task(String id) => Reminder(
    id: id,
    taskTitle: 'Synthetic $id',
    quadrantLevel: 3,
    triggerTime: DateTime.now().add(const Duration(days: 2)),
  );
  Future<void> open() async {
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      database: helper,
    );
    notifier = RemindersNotifier(helper, notifications: service);
    await notifier.ready;
  }

  Future<void> restart() async {
    // Stop Dart timers without pretending process exit cancels OS requests.
    final pending = Map<int, String>.of(native.pending);
    await service.pauseForMaintenance();
    native.pending.addAll(pending);
    notifier.dispose();
    await helper.close(createBackup: false);
    native.calls.clear();
    await open();
  }

  Future<NotificationJournalSnapshot> snapshot() async => (await helper
      .withNotificationJournal<NotificationJournalSnapshot?>((j) => j.read()))!;
  setUp(() async {
    sqfliteFfiInit();
    final temp = await Directory.systemTemp.createTemp('durable-notification-');
    directory = Directory(await temp.resolveSymbolicLinks());
    native = _Native();
    await open();
  });
  tearDown(() async {
    await service.pauseForMaintenance();
    notifier.dispose();
    await helper.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  test(
    'foreground retry recovers initialization failure before journal creation',
    () async {
      native.failInitialize = true;
      expect(
        (await notifier.addReminder(task('early-failure'))).nativeSyncFailed,
        isTrue,
      );
      expect(await helper.withNotificationJournal((j) => j.read()), isNull);
      native.failInitialize = false;
      final result = await notifier.retryFailedNotificationDelivery(
        canSchedule: true,
        isActive: () => true,
        now: DateTime.now().add(const Duration(minutes: 2)),
      );
      expect(result, (attempted: 1, failed: 0));
      expect((await snapshot()).entries['early-failure']!.status, 'submitted');
      expect(native.pending.length, 1);
    },
  );

  test(
    'unrecorded failures respect cooldown, permission and foreground gates',
    () async {
      native.failInitialize = true;
      await notifier.addReminder(task('early-gated'));
      native.failInitialize = false;
      for (final (allowed, active, at) in [
        (true, true, DateTime.now()),
        (false, true, DateTime.now().add(const Duration(minutes: 2))),
        (true, false, DateTime.now().add(const Duration(minutes: 2))),
      ]) {
        expect(
          await notifier.retryFailedNotificationDelivery(
            canSchedule: allowed,
            isActive: () => active,
            now: at,
          ),
          (attempted: 0, failed: 0),
        );
      }
      expect(await helper.withNotificationJournal((j) => j.read()), isNull);
    },
  );

  test('unrecorded failure batches remain bounded and rotate', () async {
    native.failInitialize = true;
    for (var i = 0; i < 10; i++) {
      await notifier.addReminder(task('early-batch-$i'));
    }
    native.failInitialize = false;
    final at = DateTime.now().add(const Duration(minutes: 2));
    expect(
      await notifier.retryFailedNotificationDelivery(
        canSchedule: true,
        isActive: () => true,
        now: at,
      ),
      (attempted: 8, failed: 0),
    );
    expect(native.pending.length, 8);
    expect(
      await notifier.retryFailedNotificationDelivery(
        canSchedule: true,
        isActive: () => true,
        now: at,
      ),
      (attempted: 2, failed: 0),
    );
    expect(native.pending.length, 10);
    expect(
      await notifier.retryFailedNotificationDelivery(
        canSchedule: true,
        isActive: () => true,
        now: at,
      ),
      (attempted: 0, failed: 0),
    );
  });

  test(
    'early cancellation failure is retried without recreating a deleted row',
    () async {
      native.failInitialize = true;
      await notifier.addReminder(task('early-deleted'));
      expect(
        (await notifier.deleteReminder('early-deleted')).nativeSyncFailed,
        isTrue,
      );
      native.failInitialize = false;
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: false,
          isActive: () => true,
          now: DateTime.now().add(const Duration(minutes: 2)),
        ),
        (attempted: 1, failed: 0),
      );
      expect(notifier.state, isEmpty);
      expect(native.pending, isEmpty);
      expect((await snapshot()).entries['early-deleted']!.action, 'cancel');
    },
  );

  test(
    'startup initialization failure retries despite an older submitted journal',
    () async {
      await notifier.addReminder(task('early-reopen'));
      final old = (await snapshot()).entries['early-reopen']!;
      native.failInitialize = true;
      await restart();
      expect(
        (await snapshot()).entries['early-reopen']!.attempts,
        old.attempts,
      );
      native.failInitialize = false;
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => true,
          now: DateTime.now().add(const Duration(minutes: 2)),
        ),
        (attempted: 1, failed: 0),
      );
      final repaired = (await snapshot()).entries['early-reopen']!;
      expect(repaired.nativeId, old.nativeId);
      expect(repaired.attempts, old.attempts + 2);
    },
  );

  test(
    'failed scheduling retries after service and database reopen with the same ID',
    () async {
      native.failSchedule = true;
      final saved = await notifier.addReminder(task('retry'));
      expect(saved.nativeSyncFailed, isTrue);
      final first = (await snapshot()).entries['retry']!;
      expect(first.status, 'failed');
      expect(first.action, 'schedule');
      native.failSchedule = false;
      await restart();
      final second = (await snapshot()).entries['retry']!;
      expect(second.nativeId, first.nativeId);
      expect(second.status, 'submitted');
      expect(native.pending.keys, [first.nativeId]);
      expect(native.calls, isNot(contains('cancelAll')));
      expect(notifier.state.single.id, 'retry');
    },
  );

  test('empty-database retry still retires orphan legacy IDs', () async {
    native.pending[123] = 'legacy orphan';
    expect(await notifier.retryNotificationDelivery(), (
      attempted: 0,
      failed: 0,
    ));
    expect(native.pending, isEmpty);
    expect(native.calls, ['launch', 'cancelAll']);
    expect((await snapshot()).entries, isEmpty);
  });

  test(
    'deleted row cancellation failure survives restart without recreating the task',
    () async {
      await notifier.addReminder(task('deleted'));
      final nativeId = (await snapshot()).entries['deleted']!.nativeId;
      native.failCancel = true;
      expect(
        (await notifier.deleteReminder('deleted')).nativeSyncFailed,
        isTrue,
      );
      expect((await snapshot()).entries['deleted']!.status, 'failed');
      native.failCancel = false;
      await restart();
      expect(notifier.state, isEmpty);
      expect(native.pending, isEmpty);
      expect(native.calls, ['launch', 'cancel:$nativeId']);
      expect((await snapshot()).entries['deleted']!.status, 'submitted');
      expect((await snapshot()).entries['deleted']!.action, 'cancel');
      await restart();
      expect(native.calls, isEmpty); // completed tombstone is not replayed
    },
  );

  test(
    'restart closes the crash gap between SQL deletion and native cancellation',
    () async {
      await notifier.addReminder(task('gap-delete'));
      final id = (await snapshot()).entries['gap-delete']!.nativeId;
      await helper.writeTransaction(
        helper.captureGeneration(),
        (db) => db.delete('Reminders'),
      );
      expect((await snapshot()).entries['gap-delete']!.action, 'schedule');
      await restart();
      expect(native.calls, contains('cancel:$id'));
      expect(native.pending, isEmpty);
      expect(notifier.state, isEmpty);
    },
  );

  test(
    'restart cancels a stale future request after SQL moved its occurrence into the past',
    () async {
      await notifier.addReminder(task('gap-edit'));
      final id = (await snapshot()).entries['gap-edit']!.nativeId;
      await helper.writeTransaction(
        helper.captureGeneration(),
        (db) => db.update('Reminders', {
          'trigger_time': DateTime.now()
              .subtract(const Duration(minutes: 1))
              .toIso8601String(),
          'notice_revision': 1,
        }),
      );
      await restart();
      expect(native.calls, contains('cancel:$id'));
      expect(native.calls.where((c) => c.startsWith('schedule:')), isEmpty);
      expect(notifier.state.single.noticeRevision, 1);
      expect(notifier.state.single.noticeAcknowledgedAt, isNull);
    },
  );

  test(
    'startup preserves a delivered current occurrence without replay or acknowledgement',
    () async {
      final past = task('past').copyWith(
        triggerTime: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      await helper.writeTransaction(
        helper.captureGeneration(),
        (db) => db.insert('Reminders', past.toJson()),
      );
      final epoch = await helper.readNotificationEpoch();
      await helper.withNotificationJournal((j) async {
        await j.reset(epoch);
        final e = await j.reserve(epoch, past.id);
        native.pending[e.nativeId] = 'delivered';
        await j.record(
          epoch,
          past.id,
          action: 'schedule',
          status: 'submitted',
          triggerUtcMicros: past.triggerTime!.toUtc().microsecondsSinceEpoch,
          noticeRevision: past.noticeRevision,
        );
      });
      await restart();
      expect(native.calls, isEmpty);
      expect(native.pending.values, ['delivered']);
      expect(notifier.state.single.noticeAcknowledgedAt, isNull);
    },
  );

  test(
    'first migration captures cold click before retiring legacy IDs',
    () async {
      final future = task('legacy');
      final epoch = await helper.readNotificationEpoch();
      native.launchPayload = NotificationPayload.forReminder(
        future,
        datasetEpoch: epoch,
      ).encode();
      native.pending[future.id.hashCode] = 'legacy';
      await notifier.addReminder(future);
      expect(native.calls.take(2), ['launch', 'cancelAll']);
      expect(service.takePendingNotificationPayloads(), [native.launchPayload]);
      expect(native.pending.keys, [stableNotificationId(future.id)]);
    },
  );

  test(
    'restored epoch retires the previous registry before rebuilding',
    () async {
      await notifier.addReminder(task('old-dataset'));
      final previous = await snapshot();
      await service.pauseForMaintenance();
      final lease = await helper.beginMaintenance();
      await NotificationEpochStore(Directory(lease.directory)).rotate();
      await service.resumeFromReminders([task('new-dataset')]);
      await lease.resume();
      final next = await snapshot();
      expect(next.epoch, isNot(previous.epoch));
      expect(next.entries.keys, ['new-dataset']);
      expect(native.pending.keys, [stableNotificationId('new-dataset')]);
    },
  );

  test(
    'quiet retry waits for durable cooldown and leaves healthy schedules alone',
    () async {
      await notifier.addReminder(task('healthy'));
      native.failSchedule = true;
      await notifier.addReminder(task('retry-quiet'));
      final failed = (await snapshot()).entries['retry-quiet']!;
      final before = notifier.state.map((r) => r.toJson()).toList();
      native.failSchedule = false;
      native.calls.clear();
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => true,
          now: DateTime.parse(
            failed.attemptedAt!,
          ).add(const Duration(seconds: 59)),
        ),
        (attempted: 0, failed: 0),
      );
      expect(native.calls, isEmpty);
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => true,
          now: DateTime.parse(
            failed.attemptedAt!,
          ).add(const Duration(seconds: 60)),
        ),
        (attempted: 1, failed: 0),
      );
      expect(native.calls, [
        'cancel:${failed.nativeId}',
        'schedule:${failed.nativeId}',
      ]);
      expect((await snapshot()).entries['retry-quiet']!.status, 'submitted');
      expect(notifier.state.map((r) => r.toJson()).toList(), before);
    },
  );

  test(
    'quiet retry bounds a batch and completes the remainder on another pass',
    () async {
      native.failSchedule = true;
      for (var i = 0; i < 10; i++) {
        await notifier.addReminder(task('batch-$i'));
      }
      native.failSchedule = false;
      native.calls.clear();
      final now = DateTime.now().add(const Duration(minutes: 2));
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => true,
          now: now,
        ),
        (attempted: 8, failed: 0),
      );
      expect(
        native.calls.where((c) => c.startsWith('schedule:')),
        hasLength(8),
      );
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => true,
          now: now,
        ),
        (attempted: 2, failed: 0),
      );
      expect(
        (await snapshot()).entries.values.where((e) => e.unfinished),
        isEmpty,
      );
      expect(native.calls, isNot(contains('cancelAll')));
    },
  );

  test(
    'denied permission skips planning without starving deleted-task cancellation',
    () async {
      native.failSchedule = true;
      for (var i = 0; i < 9; i++) {
        await notifier.addReminder(task('denied-$i'));
      }
      native.failSchedule = false;
      await notifier.addReminder(task('retired'));
      native.failCancel = true;
      await notifier.deleteReminder('retired');
      final retired = (await snapshot()).entries['retired']!;
      native.failCancel = false;
      native.calls.clear();
      final now = DateTime.now().add(const Duration(minutes: 2));
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: false,
          isActive: () => true,
          now: now,
        ),
        (attempted: 0, failed: 0),
      );
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: false,
          isActive: () => true,
          now: now,
        ),
        (attempted: 1, failed: 0),
      );
      expect(native.calls, ['cancel:${retired.nativeId}']);
      expect((await snapshot()).entries['retired']!.status, 'submitted');
      expect(notifier.state, hasLength(9));
    },
  );

  test(
    'expired current failure is not replayed but stale cancellation is retried',
    () async {
      final epoch = await helper.readNotificationEpoch();
      final past = DateTime.now().subtract(const Duration(hours: 1));
      final reminders = [
        task('expired').copyWith(triggerTime: past),
        task('cancel-past').copyWith(triggerTime: past),
      ];
      await helper.writeTransaction(helper.captureGeneration(), (db) async {
        for (final r in reminders) {
          await db.insert('Reminders', r.toJson());
        }
      });
      await helper.withNotificationJournal((j) async {
        await j.reset(epoch);
        for (final r in reminders) {
          await j.reserve(epoch, r.id);
          await j.record(
            epoch,
            r.id,
            action: r.id == 'expired' ? 'schedule' : 'cancel',
            status: 'failed',
            triggerUtcMicros: past.toUtc().microsecondsSinceEpoch,
            noticeRevision: r.noticeRevision,
            attemptedAt: past,
          );
        }
      });
      final result = await notifier.retryFailedNotificationDelivery(
        canSchedule: false,
        isActive: () => true,
      );
      expect(result, (attempted: 1, failed: 0));
      expect(native.calls, [
        'launch',
        'cancel:${stableNotificationId('cancel-past')}',
      ]);
      final journal = await snapshot();
      expect(journal.entries['expired']!.status, 'failed');
      expect(journal.entries['cancel-past']!.status, 'submitted');
    },
  );

  test(
    'foreground loss after one operation stops the remainder of the batch',
    () async {
      native.failSchedule = true;
      await notifier.addReminder(task('first'));
      await notifier.addReminder(task('second'));
      var active = true;
      native.failSchedule = false;
      native.onSchedule = () => active = false;
      native.calls.clear();
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => active,
          now: DateTime.now().add(const Duration(minutes: 2)),
        ),
        (attempted: 1, failed: 0),
      );
      expect(
        native.calls.where((c) => c.startsWith('schedule:')),
        hasLength(1),
      );
      expect(
        (await snapshot()).entries.values.where((e) => e.unfinished),
        hasLength(1),
      );
    },
  );

  test(
    'status reads do not initialize native notifications or rewrite local journal',
    () async {
      final empty = await NotificationScheduleReader(helper).read();
      expect(empty.upcoming, 0);
      expect(native.calls, isEmpty);
      expect(await helper.withNotificationJournal((j) => j.read()), isNull);
      await notifier.addReminder(task('submitted'));
      native.failSchedule = true;
      await notifier.addReminder(task('failed'));
      native.calls.clear();
      final file = File('${directory.path}/${NotificationJournal.fileName}');
      final before = await file.readAsString();
      final result = await NotificationScheduleReader(helper).read();
      expect(result.upcoming, 2);
      expect(result.submitted, 1);
      expect(result.needsAttention, 1);
      expect(await file.readAsString(), before);
      expect(native.calls, isEmpty);
    },
  );

  test('status read and quiet retry fail closed on corrupt journal', () async {
    await notifier.addReminder(task('valid'));
    final file = File('${directory.path}/${NotificationJournal.fileName}');
    final before = await file.readAsString();
    await file.writeAsString('{broken');
    native.calls.clear();
    await expectLater(
      NotificationScheduleReader(helper).read(),
      throwsFormatException,
    );
    await expectLater(
      notifier.retryFailedNotificationDelivery(
        canSchedule: true,
        isActive: () => true,
      ),
      throwsFormatException,
    );
    expect(await file.readAsString(), '{broken');
    expect(native.calls, isEmpty);
    await file.writeAsString(before);
  });

  test(
    'repeated failures retain cooldown and the same identity after reopening',
    () async {
      native.failSchedule = true;
      await notifier.addReminder(task('still-failing'));
      final first = (await snapshot()).entries['still-failing']!;
      await restart();
      final reopened = (await snapshot()).entries['still-failing']!;
      expect(reopened.status, 'failed');
      expect(reopened.nativeId, first.nativeId);
      native.calls.clear();
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => true,
          now: DateTime.parse(
            reopened.attemptedAt!,
          ).add(const Duration(seconds: 59)),
        ),
        (attempted: 0, failed: 0),
      );
      expect(native.calls, isEmpty);
      expect(
        await notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => true,
          now: DateTime.parse(
            reopened.attemptedAt!,
          ).add(const Duration(seconds: 60)),
        ),
        (attempted: 1, failed: 1),
      );
      final retried = (await snapshot()).entries['still-failing']!;
      expect(retried.status, 'failed');
      expect(retried.nativeId, first.nativeId);
      expect(retried.attempts, greaterThan(reopened.attempts));
      native.failSchedule = false;
    },
  );

  test(
    'settings reader provider does not construct the scheduling controller',
    () async {
      final container = ProviderContainer(
        overrides: [
          databaseHelperProvider.overrideWithValue(helper),
          notificationServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      expect(container.exists(remindersProvider), isFalse);
      final result = await container.read(
        notificationScheduleStatusReaderProvider,
      )();
      expect(result.upcoming, 0);
      expect(container.exists(remindersProvider), isFalse);
      expect(native.calls, isEmpty);
    },
  );

  test(
    'status and quiet retry ignore an old dataset journal without rewriting it',
    () async {
      await notifier.addReminder(task('current'));
      final file = File('${directory.path}/${NotificationJournal.fileName}');
      final before = await file.readAsString();
      await service.pauseForMaintenance();
      final lease = await helper.beginMaintenance();
      await NotificationEpochStore(Directory(lease.directory)).rotate();
      await lease.resume();
      // Read-only status does not require resuming the paused native service.
      native.calls.clear();
      final result = await NotificationScheduleReader(helper).read();
      expect(result.upcoming, 1);
      expect(result.submitted, 0);
      expect(result.needsAttention, 1);
      expect(await file.readAsString(), before);
      expect(native.calls, isEmpty);
      await expectLater(
        notifier.retryFailedNotificationDelivery(
          canSchedule: true,
          isActive: () => true,
        ),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(await file.readAsString(), before);
    },
  );
}
