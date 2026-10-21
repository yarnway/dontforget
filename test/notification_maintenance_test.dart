import 'dart:async';

import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  Completer<void>? scheduling;
  int? blockScheduleNumber;
  bool failCancelAll = false;
  bool failSchedule = false;
  int initializeFailures = 0;
  int initializations = 0;
  int? failOnScheduleNumber;
  int schedules = 0;
  final Map<int, String> pending = {};
  int cancellations = 0;

  Future<void> _schedule(Invocation call) async {
    schedules++;
    if (blockScheduleNumber == null || schedules == blockScheduleNumber) {
      await scheduling?.future;
    }
    if (schedules == failOnScheduleNumber) {
      failCancelAll = true;
      throw StateError('synthetic partial rebuild and cleanup failure');
    }
    if (failSchedule) throw StateError('synthetic schedule failure');
    pending[call.positionalArguments[0] as int] =
        call.positionalArguments[1] as String;
  }

  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        initializations++;
        if (initializeFailures-- > 0) {
          return Future<bool>.error(StateError('synthetic initialize failure'));
        }
        return Future<bool>.value(true);
      case #cancel:
        pending.remove(call.positionalArguments[0]);
        return Future<void>.value();
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value();
      case #cancelAll:
        cancellations++;
        if (failCancelAll) {
          return Future<void>.error(StateError('synthetic cancel failure'));
        }
        pending.clear();
        return Future<void>.value();
      case #zonedSchedule:
        return _schedule(call);
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Reminder task(String id) => Reminder(
    id: id,
    taskTitle: id,
    quadrantLevel: 2,
    triggerTime: DateTime.now().add(const Duration(days: 1)),
  );

  test(
    'pause drains native add before cancelling and rejects new schedules',
    () async {
      final native = _Native()..scheduling = Completer<void>();
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      final schedule = service.scheduleReminder(task('old'));
      await Future<void>.delayed(Duration.zero);
      var paused = false;
      final pause = service.pauseForMaintenance().then((_) => paused = true);
      await expectLater(
        service.scheduleReminder(task('late')),
        throwsStateError,
      );
      await expectLater(
        service.resumeFromReminders([task('too-soon')]),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(paused, isFalse);
      native.scheduling!.complete();
      await Future.wait([schedule, pause]);
      expect(native.pending, isEmpty);
      expect(native.cancellations, 1);
      await service.resumeFromReminders([
        task('new'),
        task('done').copyWith(isCompleted: true),
      ]);
      expect(native.pending.values, ['new']);
      expect(service.isPausedForMaintenance, isFalse);
      await service.pauseForMaintenance();
    },
  );

  test('native cancellation failure leaves maintenance closed', () async {
    final native = _Native()..failCancelAll = true;
    final service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
    );
    await expectLater(service.pauseForMaintenance(), throwsStateError);
    expect(service.isPausedForMaintenance, isTrue);
    await expectLater(
      service.resumeFromReminders([task('new')]),
      throwsStateError,
    );
    await expectLater(service.scheduleReminder(task('late')), throwsStateError);
  });

  test(
    'rebuild failure is visible, removes partial schedules and permits retry',
    () async {
      final native = _Native();
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      await service.pauseForMaintenance();
      native.failSchedule = true;
      await expectLater(
        service.resumeFromReminders([task('new')]),
        throwsStateError,
      );
      expect(service.isPausedForMaintenance, isTrue);
      expect(native.pending, isEmpty);
      native.failSchedule = false;
      await service.resumeFromReminders([task('old')]);
      expect(native.pending.values, ['old']);
      await service.pauseForMaintenance();
    },
  );

  test('maintenance suppresses timer and immediate in-app delivery', () async {
    final service = NotificationService.forTesting(
      _Native(),
      usesNativeNotifications: false,
    );
    final delivered = <Reminder>[];
    final subscription = service.onReminderDue.listen(delivered.add);
    await service.scheduleReminder(task('old'));
    await service.pauseForMaintenance();
    await service.fireReminderNow(task('old'));
    await service.reconcileNotificationPolicy();
    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);
    await subscription.cancel();
  });

  test(
    'failed partial rebuild cleanup cannot resume until native cancellation succeeds',
    () async {
      final native = _Native()..failOnScheduleNumber = 2;
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      await service.pauseForMaintenance();
      await expectLater(
        service.resumeFromReminders([task('new-a'), task('new-b')]),
        throwsStateError,
      );
      expect(native.pending.values, ['new-a']);
      await expectLater(
        service.resumeFromReminders([task('old')]),
        throwsStateError,
      );
      await expectLater(service.pauseForMaintenance(), throwsStateError);
      expect(service.isPausedForMaintenance, isTrue);
      native.failCancelAll = false;
      await service.pauseForMaintenance();
      await service.resumeFromReminders([task('old')]);
      expect(native.pending.values, ['old']);
      await service.pauseForMaintenance();
    },
  );

  test(
    'transient initialization failure permits a later recovery retry',
    () async {
      final native = _Native()..initializeFailures = 1;
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      await service.pauseForMaintenance();
      await expectLater(
        service.resumeFromReminders([task('new')]),
        throwsStateError,
      );
      await service.resumeFromReminders([task('old')]);
      expect(native.initializations, 2);
      expect(native.pending.values, ['old']);
      await service.pauseForMaintenance();
    },
  );

  testWidgets(
    'occurrence due during rebuild is delivered once after all scheduling succeeds',
    (tester) async {
      final native = _Native()
        ..scheduling = Completer<void>()
        ..blockScheduleNumber = 2;
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
        now: tester.binding.clock.now,
      );
      final delivered = <Reminder>[];
      final subscription = service.onReminderDue.listen(delivered.add);
      await service.pauseForMaintenance();
      final startedAt = tester.binding.clock.now();
      final rebuilding = service.resumeFromReminders([
        task(
          'due-during-rebuild',
        ).copyWith(triggerTime: startedAt.add(const Duration(seconds: 5))),
        task(
          'later',
        ).copyWith(triggerTime: startedAt.add(const Duration(minutes: 5))),
      ]);
      await tester.pump();
      expect(native.schedules, 2);
      await tester.pump(const Duration(seconds: 10));
      expect(delivered, isEmpty);
      native.scheduling!.complete();
      await tester.pump();
      await rebuilding;
      await tester.pump(const Duration(milliseconds: 1));
      expect(delivered.map((r) => r.id), ['due-during-rebuild']);
      await tester.pump(const Duration(seconds: 1));
      expect(delivered, hasLength(1));
      await service.pauseForMaintenance();
      // Broadcast cancellation detaches synchronously; its completion future
      // can belong to the real zone used by the native initialization fixture.
      unawaited(subscription.cancel());
    },
  );
}
