import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
  final failedCancellations = <int>{};
  final events = <String>[];
  int highWater = 0;
  Completer<void>? scheduleBarrier;
  final scheduleEntered = Completer<void>();

  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        return Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value();
      case #cancelAll:
        events.add('cancelAll');
        pending.clear();
        return Future<void>.value();
      case #cancel:
        final id = call.positionalArguments.first as int;
        events.add('cancel:$id');
        if (failedCancellations.contains(id)) {
          return Future<void>.error(
            StateError('Synthetic cancellation failure'),
          );
        }
        pending.remove(id);
        return Future<void>.value();
      case #zonedSchedule:
        return schedule(call);
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }

  Future<void> schedule(Invocation call) async {
    if (!scheduleEntered.isCompleted) scheduleEntered.complete();
    await scheduleBarrier?.future;
    final id = call.positionalArguments.first as int;
    events.add('schedule:$id');
    pending[id] = call.positionalArguments[1] as String;
    if (pending.length > highWater) highWater = pending.length;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2032, 1, 1);
  Reminder task(String id, int minute) => Reminder(
    id: id,
    taskTitle: id,
    quadrantLevel: 2,
    triggerTime: now.add(Duration(minutes: minute)),
  );
  late _Native native;
  late NotificationService service;
  setUp(() {
    native = _Native();
    service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
      nativePendingLimit: 3,
      now: () => now,
    );
  });
  tearDown(() => service.pauseForMaintenance());

  test(
    'best-effort cancellation failure keeps its capacity reservation',
    () async {
      for (var i = 1; i <= 4; i++) {
        await service.scheduleReminderStrict(task('$i', i));
      }
      native.failedCancellations.add(stableNotificationId('1'));
      await service.cancelReminder('1');
      expect(native.highWater, 3);
      expect(native.pending.values.toSet(), {'1', '2', '3'});
      native.failedCancellations.clear();
      await service.scheduleReminderStrict(task('4', 4));
      expect(native.pending.values.toSet(), {'2', '3', '4'});
      expect(native.highWater, 3);
    },
  );

  test(
    'maintenance drains a blocked shared window before rebuilding',
    () async {
      native.scheduleBarrier = Completer<void>();
      final pending = service.scheduleReminderStrict(task('old', 1));
      await native.scheduleEntered.future;
      var paused = false;
      final pause = service.pauseForMaintenance().then((_) => paused = true);
      await Future<void>.delayed(Duration.zero);
      expect(paused, isFalse);
      native.scheduleBarrier!.complete();
      await Future.wait([pending, pause]);
      expect(native.pending, isEmpty);
      expect(native.events.last, 'cancelAll');
      await service.resumeFromReminders([
        task('new4', 4),
        task('new3', 3),
        task('new2', 2),
        task('new1', 1),
      ]);
      expect(native.pending.values.toSet(), {'new1', 'new2', 'new3'});
      expect(native.highWater, lessThanOrEqualTo(3));
    },
  );

  test(
    'a fresh service accounts for retained requests from its journal',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'capacity-restart-',
      );
      final database = DatabaseHelper.forTesting(
        directory.path,
        databaseFactoryFfi,
      );
      NotificationService withDatabase() => NotificationService.forTesting(
        native,
        database: database,
        usesNativeNotifications: true,
        nativePendingLimit: 3,
        now: () => now,
      );
      final first = withDatabase();
      final restarted = withDatabase();
      try {
        for (var i = 2; i <= 4; i++) {
          await first.scheduleReminderStrict(task('$i', i));
        }
        expect(native.pending.length, 3);
        native.failedCancellations.add(stableNotificationId('2'));
        await expectLater(
          restarted.scheduleReminderStrict(task('1', 1)),
          throwsStateError,
        );
        expect(native.pending.length, 3);
        expect(native.highWater, 3);
        native.failedCancellations.clear();
        for (var i = 1; i <= 4; i++) {
          await restarted.scheduleReminderStrict(task('$i', i));
        }
        expect(native.pending.values.toSet(), {'1', '2', '3'});
        expect(native.highWater, 3);
      } finally {
        native.failedCancellations.clear();
        await first.pauseForMaintenance();
        await restarted.pauseForMaintenance();
        await database.close(createBackup: false);
        await directory.delete(recursive: true);
      }
    },
  );
}
