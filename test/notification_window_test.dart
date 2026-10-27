import 'dart:async';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:dont_forget/services/notification_window.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
  int highWater = 0, schedules = 0;
  bool failCancel = false, uncertainSchedule = false;
  Completer<void>? blocked;
  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        return Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value();
      case #cancelAll:
        pending.clear();
        return Future<void>.value();
      case #cancel:
        if (failCancel) {
          return Future<void>.error(StateError('Synthetic cancel failure'));
        }
        pending.remove(call.positionalArguments.first);
        return Future<void>.value();
      case #zonedSchedule:
        return _schedule(call);
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }

  Future<void> _schedule(Invocation call) async {
    await blocked?.future;
    schedules++;
    pending[call.positionalArguments[0] as int] =
        call.positionalArguments[1] as String;
    if (pending.length > highWater) highWater = pending.length;
    if (uncertainSchedule) throw StateError('Synthetic uncertain native write');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime.utc(2030, 1, 1);
  Reminder task(String id, int minute) => Reminder(
    id: id,
    taskTitle: id,
    quadrantLevel: 2,
    triggerTime: start.add(Duration(minutes: minute)),
  );
  late DateTime now;
  late _Native native;
  late NotificationService service;
  setUp(() {
    now = start;
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
    'earliest dates win regardless of concurrent insertion order, without overflow',
    () async {
      await Future.wait([
        for (var i = 20; i > 0; i--)
          service.scheduleReminderStrict(task('$i', i)),
      ]);
      expect(native.pending.values.toSet(), {'1', '2', '3'});
      expect(native.highWater, lessThanOrEqualTo(3));
    },
  );
  test('cancelling the first date fills the vacant slot', () async {
    for (var i = 1; i <= 5; i++) {
      await service.scheduleReminderStrict(task('$i', i));
    }
    await service.cancelReminderStrict('1');
    expect(native.pending.values.toSet(), {'2', '3', '4'});
    expect(native.highWater, 3);
  });
  test(
    'an earlier new task cancels a displaced date before submitting',
    () async {
      for (var i = 2; i <= 5; i++) {
        await service.scheduleReminderStrict(task('$i', i));
      }
      await service.scheduleReminderStrict(task('1', 1));
      expect(native.pending.values.toSet(), {'1', '2', '3'});
      expect(native.highWater, 3);
    },
  );
  test('failed cancellation reserves its slot and remains retryable', () async {
    for (var i = 2; i <= 4; i++) {
      await service.scheduleReminderStrict(task('$i', i));
    }
    native.failCancel = true;
    await expectLater(
      service.scheduleReminderStrict(task('1', 1)),
      throwsStateError,
    );
    expect(native.pending.values.toSet(), {'2', '3', '4'});
    expect(native.highWater, 3);
    native.failCancel = false;
    await service.scheduleReminderStrict(task('1', 1));
    expect(native.pending.values.toSet(), {'1', '2', '3'});
  });
  test('uncertain scheduling is cancelled before the next attempt', () async {
    native.uncertainSchedule = true;
    await expectLater(
      service.scheduleReminderStrict(task('1', 1)),
      throwsStateError,
    );
    expect(native.pending.length, 1);
    native.uncertainSchedule = false;
    await Future.wait([
      service.scheduleReminderStrict(task('2', 2)),
      service.scheduleReminderStrict(task('3', 3)),
    ]);
    expect(native.pending.values.toSet(), {'1', '2', '3'});
    expect(native.highWater, 3);
  });
  test('a content edit replaces the same native slot', () async {
    final row = task('1', 1);
    await service.scheduleReminderStrict(row);
    await service.scheduleReminderStrict(
      row.copyWith(taskTitle: 'Edited', noticeRevision: 1),
    );
    expect(native.pending.values, ['Edited']);
    expect(native.highWater, 1);
  });
  test(
    'focus mode frees suppressed slots and restores them in time order',
    () async {
      await service.scheduleReminderStrict(
        task('low', 1).copyWith(quadrantLevel: 3),
      );
      for (var i = 2; i <= 4; i++) {
        await service.scheduleReminderStrict(task('$i', i));
      }
      await service.applyFocusMode(true);
      expect(native.pending.values.toSet(), {'2', '3', '4'});
      await service.applyFocusMode(false);
      expect(native.pending.values.toSet(), {'low', '2', '3'});
    },
  );
  test('maintenance rebuild obeys the same shared capacity', () async {
    await service.pauseForMaintenance();
    await service.resumeFromReminders([
      for (var i = 9; i >= 1; i--) task('$i', i),
    ]);
    expect(native.pending.values.toSet(), {'1', '2', '3'});
    expect(native.highWater, 3);
  });
  test(
    'foreground delivery fills a slot without cancelling the retained past banner',
    () async {
      for (var i = 1; i <= 4; i++) {
        await service.scheduleReminderStrict(task('$i', i));
      }
      // The OS has delivered the first request; the fake removes its pending row.
      native.pending.remove(stableNotificationId('1'));
      now = start.add(const Duration(minutes: 1));
      await service.fireReminderNow(task('1', 1));
      expect(native.pending.values.toSet(), {'2', '3', '4'});
    },
  );
  test(
    'selection excludes hidden, paused, acknowledged and completed rows',
    () {
      final rows = [
        task('a', 1),
        task('b', 2).copyWith(isCompleted: true),
        task('c', 3).copyWith(noticeAcknowledgedAt: start),
      ];
      expect(
        NotificationWindow.select(rows, start, limit: 3).map((r) => r.id),
        ['a'],
      );
    },
  );
}
