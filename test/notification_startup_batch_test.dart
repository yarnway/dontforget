import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  _Native(this.directory);
  final Directory directory;
  final pending = <int>{};
  final failSchedules = <int>{};
  Completer<void>? release;
  final firstBatch = Completer<void>();
  int schedules = 0;
  int active = 0;
  int peakActive = 0;

  Future<void> mutate(int id, String action) async {
    // Bypass the live cache and read the durable file at the native boundary.
    final state = NotificationJournalSnapshot.decode(
      jsonDecode(
        await File(
          '${directory.path}/${NotificationJournal.fileName}',
        ).readAsString(),
      ),
    );
    final entry = state.entries.values.singleWhere((e) => e.nativeId == id);
    expect(entry.action, action);
    expect(entry.status, 'pending');
    expect(entry.attempts, greaterThan(0));
    if (action == 'cancel') {
      pending.remove(id);
      return;
    }
    schedules++;
    active++;
    if (active > peakActive) peakActive = active;
    if (schedules == 32 && !firstBatch.isCompleted) firstBatch.complete();
    try {
      await release?.future;
      if (failSchedules.contains(id)) {
        throw StateError('synthetic native failure');
      }
      pending.add(id);
    } finally {
      active--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        return Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        return Future.value(const NotificationAppLaunchDetails(false));
      case #cancelAll:
        expect(active, 0, reason: 'Cleanup must drain admitted native work');
        pending.clear();
        return Future<void>.value();
      case #cancel:
        return mutate(call.positionalArguments.first as int, 'cancel');
      case #zonedSchedule:
        return mutate(call.positionalArguments.first as int, 'schedule');
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseHelper helper;
  late _Native native;
  late NotificationService service;
  RemindersNotifier? notifier;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('startup-batch-');
    directory = Directory(await directory.resolveSymbolicLinks());
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    native = _Native(directory);
    service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      database: helper,
    );
    final db = await helper.database;
    final batch = db.batch();
    for (var i = 0; i < 257; i++) {
      batch.insert(
        'Reminders',
        Reminder(
          id: 'task-$i',
          taskTitle: 'Synthetic $i',
          quadrantLevel: 3,
          triggerTime: DateTime.utc(2099),
        ).toJson(),
      );
    }
    await batch.commit(noResult: true);
  });
  tearDown(() async {
    if (native.release != null && !native.release!.isCompleted) {
      native.release!.complete();
    }
    await notifier?.ready.catchError((Object _) {});
    notifier?.dispose();
    notifier = null;
    await service.pauseForMaintenance();
    await helper.close(createBackup: false);
    await directory.delete(recursive: true);
  });

  test(
    'startup bounds native concurrency and persists intent before effects',
    () async {
      native.release = Completer<void>();
      notifier = RemindersNotifier(helper, notifications: service);
      var ready = false;
      final loaded = notifier!.ready.then((_) => ready = true);
      await native.firstBatch.future.timeout(const Duration(seconds: 5));
      expect(native.active, 32);
      expect(native.schedules, 32);
      expect(ready, isFalse);
      native.release!.complete();
      await loaded;
      expect(native.peakActive, 32);
      expect(native.pending, hasLength(257));
      final state = (await helper.withNotificationJournal((j) => j.read()))!;
      expect(
        state.entries.values.every(
          (e) => e.status == 'submitted' && e.action == 'schedule',
        ),
        isTrue,
      );
      // Exact coalescing depends on filesystem completion order. Deterministic
      // batch counts are covered by notification_journal_test; this test checks
      // the durable native boundary and concurrency bound across platforms.
    },
  );

  test(
    'partial native failures remain durable and retry without disturbing peers',
    () async {
      final failedId = stableNotificationId('task-4');
      native.failSchedules.add(failedId);
      notifier = RemindersNotifier(helper, notifications: service);
      await notifier!.ready;
      final state = (await helper.withNotificationJournal((j) => j.read()))!;
      expect(native.pending, hasLength(256));
      expect(state.entries['task-4']!.status, 'failed');
      expect(
        state.entries.values.where((e) => e.status == 'submitted'),
        hasLength(256),
      );
      final beforeSchedules = native.schedules;
      native.failSchedules.clear();
      final result = await notifier!.retryFailedNotificationDelivery(
        canSchedule: true,
        isActive: () => true,
        now: DateTime.now().add(const Duration(minutes: 2)),
      );
      expect(result, (attempted: 1, failed: 0));
      expect(native.schedules, beforeSchedules + 1);
      expect(native.pending, hasLength(257));
      expect(
        (await helper.withNotificationJournal(
          (j) => j.read(),
        ))!.entries['task-4']!.nativeId,
        failedId,
      );
    },
  );

  test(
    'maintenance drains the admitted batch and rejects later batches',
    () async {
      native.release = Completer<void>();
      notifier = RemindersNotifier(helper, notifications: service);
      await native.firstBatch.future.timeout(const Duration(seconds: 5));
      final stopped = expectLater(
        notifier!.ready,
        throwsA(isA<DatabaseAccessException>()),
      );
      var issued = false;
      final pausing = helper.beginMaintenance().then((lease) {
        issued = true;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(issued, isFalse);
      native.release!.complete();
      await stopped;
      final lease = await pausing;
      expect(native.active, 0);
      expect(native.schedules, 256);
      final state = (await helper.withNotificationJournal((j) => j.read()))!;
      expect(state.entries, hasLength(256));
      expect(
        state.entries.values.every((e) => e.status == 'submitted'),
        isTrue,
      );
      await lease.resume();
    },
  );
  test(
    'recovery batches drain failures before cleanup and can rebuild again',
    () async {
      await service.init();
      await service.pauseForMaintenance();
      final tasks = (await (await helper.database).query(
        'Reminders',
      )).map(Reminder.fromJson).toList();
      native.release = Completer<void>();
      native.failSchedules.add(stableNotificationId('task-4'));
      final failed = expectLater(
        service.resumeFromReminders(tasks),
        throwsStateError,
      );
      await native.firstBatch.future.timeout(const Duration(seconds: 5));
      expect(native.active, 32);
      expect(service.isPausedForMaintenance, isTrue);
      native.release!.complete();
      await failed;
      expect(native.schedules, 256);
      expect(native.active, 0);
      expect(native.pending, isEmpty);
      expect(service.isPausedForMaintenance, isTrue);
      final before = (await helper.withNotificationJournal((j) => j.read()))!;
      expect(before.entries, hasLength(256));
      expect(before.entries['task-4']!.status, 'failed');
      native.failSchedules.clear();
      await service.resumeFromReminders(tasks);
      expect(native.pending, hasLength(257));
      expect(native.peakActive, 32);
      expect(service.isPausedForMaintenance, isFalse);
      final after = (await helper.withNotificationJournal((j) => j.read()))!;
      for (final entry in before.entries.values) {
        expect(after.entries[entry.reminderId]!.nativeId, entry.nativeId);
      }
    },
  );
}
