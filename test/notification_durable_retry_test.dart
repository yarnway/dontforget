import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:dont_forget/services/notification_epoch_store.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
  final calls = <String>[];
  bool failCancel = false;
  bool failSchedule = false;
  String? launchPayload;
  @override
  dynamic noSuchMethod(Invocation i) {
    switch (i.memberName) {
      case #initialize:
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
}
