import 'dart:async';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';

class NativeProbe implements FlutterLocalNotificationsPlugin {
  Completer<void>? initialization;
  Completer<void>? scheduling;
  Completer<void>? cancellation;
  bool failCancel = false;
  final List<NotificationDetails> schedules = [];
  final Map<int, String> pending = {};

  Future<void> schedule(Invocation i) async {
    schedules.add(i.positionalArguments[4] as NotificationDetails);
    await scheduling?.future;
    pending[i.positionalArguments[0] as int] =
        i.positionalArguments[1] as String;
  }

  @override
  dynamic noSuchMethod(Invocation i) {
    switch (i.memberName) {
      case #initialize:
        return initialization == null
            ? Future<bool>.value(true)
            : initialization!.future.then((_) => true);
      case #cancel:
        return () async {
          await cancellation?.future;
          if (failCancel) throw StateError('synthetic OS cancellation failure');
          pending.remove(i.positionalArguments[0]);
        }();
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value();
      case #zonedSchedule:
        return schedule(i);
      default:
        throw UnsupportedError('${i.memberName}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Reminder task(String id, int quadrant) => Reminder(
    id: id,
    taskTitle: 'Synthetic protocol diagnostic',
    quadrantLevel: quadrant,
    triggerTime: DateTime.now().add(const Duration(days: 1)),
  );
  test('Mac Q3 scheduled reminder must explicitly disable sound', () async {
    final native = NativeProbe();
    final service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
    );
    try {
      await service.scheduleReminder(task('q3', 3));
      expect(native.schedules.single.macOS!.presentSound, isFalse);
    } finally {
      await service.cancelReminder('q3');
    }
  });
  test(
    'cancellation while initialization is pending must not resurrect notification',
    () async {
      final native = NativeProbe()..initialization = Completer<void>();
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      final scheduled = service.scheduleReminder(task('cancelled', 1));
      await Future<void>.delayed(Duration.zero);
      await service.cancelReminder('cancelled');
      native.initialization!.complete();
      await scheduled;
      try {
        expect(native.schedules, isEmpty);
      } finally {
        await service.cancelReminder('cancelled');
      }
    },
  );
  test('focus suppression must not emit an in-app reminder event', () async {
    final native = NativeProbe();
    final service = NotificationService.forTesting(
      native,
      usesNativeNotifications: false,
    )..isImmersiveModeActive = true;
    ContextTriggerService().clearSuppressed();
    final emitted = <Reminder>[];
    final subscription = service.onReminderDue.listen(emitted.add);
    try {
      service.fireReminderNow(task('focus', 3));
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);
      expect(ContextTriggerService().suppressedReminders.single.id, 'focus');
      await service.fireReminderNow(task('focus', 3));
      expect(ContextTriggerService().suppressedReminders, hasLength(1));
    } finally {
      ContextTriggerService().clearSuppressed();
      await subscription.cancel();
    }
  });

  test(
    'cancellation waits for an in-flight native add before removing it',
    () async {
      final native = NativeProbe()..scheduling = Completer<void>();
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      final scheduled = service.scheduleReminder(task('in-flight', 1));
      await Future<void>.delayed(Duration.zero);
      expect(native.schedules, hasLength(1));
      final cancelled = service.cancelReminder('in-flight');
      native.scheduling!.complete();
      await Future.wait([scheduled, cancelled]);
      expect(native.pending, isEmpty);
    },
  );

  test('latest edit wins while native initialization is pending', () async {
    final native = NativeProbe()..initialization = Completer<void>();
    final service = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
    );
    final old = service.scheduleReminder(
      task('edit', 1).copyWith(taskTitle: 'old'),
    );
    await Future<void>.delayed(Duration.zero);
    final latest = service.scheduleReminder(
      task('edit', 3).copyWith(taskTitle: 'latest'),
    );
    await Future<void>.delayed(Duration.zero);
    native.initialization!.complete();
    await Future.wait([old, latest]);
    try {
      expect(native.pending.values, ['latest']);
      expect(native.schedules, hasLength(1));
      expect(native.schedules.single.macOS!.presentSound, isFalse);
    } finally {
      await service.cancelReminder('edit');
    }
  });

  test(
    'focus toggle removes queued Q3 and restores only future active tasks',
    () async {
      final native = NativeProbe();
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      try {
        await service.scheduleReminder(task('quiet', 3));
        await service.scheduleReminder(task('urgent', 1));
        service.isImmersiveModeActive = true;
        await service.reconcileNotificationPolicy();
        expect(native.pending.keys, [stableNotificationId('urgent')]);
        await service.cancelReminder('quiet');
        service.isImmersiveModeActive = false;
        await service.reconcileNotificationPolicy();
        expect(native.pending.keys, [stableNotificationId('urgent')]);
        expect(native.schedules.last.macOS!.presentSound, isTrue);
      } finally {
        await service.cancelReminder('quiet');
        await service.cancelReminder('urgent');
      }
    },
  );

  test(
    'context suppression queues a digest without native or in-app alerts',
    () async {
      final native = NativeProbe();
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      final context = ContextTriggerService();
      final emitted = <Reminder>[];
      final subscription = service.onReminderDue.listen(emitted.add);
      try {
        await service.scheduleReminder(task('context', 4));
        context.switchProfile(ContextProfile.office);
        await service.reconcileNotificationPolicy();
        expect(native.pending, isEmpty);
        context.switchProfile(ContextProfile.general);
        await service.reconcileNotificationPolicy();
        expect(native.pending.keys, [stableNotificationId('context')]);
        context.switchProfile(ContextProfile.office);
        await service.reconcileNotificationPolicy();
        await service.fireReminderNow(task('context', 4));
        await Future<void>.delayed(Duration.zero);
        expect(emitted, isEmpty);
        expect(context.suppressedReminders.map((r) => r.id), ['context']);
        context.switchProfile(ContextProfile.general);
        await service.reconcileNotificationPolicy();
        expect(native.pending, isEmpty);
      } finally {
        context.switchProfile(ContextProfile.general);
        context.clearSuppressed();
        await subscription.cancel();
        await service.cancelReminder('context');
      }
    },
  );

  test(
    'due reminders never add an in-app sound on top of native delivery',
    () async {
      final sounds = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            sounds.add(call);
            return null;
          });
      final service = NotificationService.forTesting(
        NativeProbe(),
        usesNativeNotifications: false,
      );
      try {
        await service.fireReminderNow(task('silent', 3));
        expect(
          sounds.where((call) => call.method == 'SystemSound.play'),
          isEmpty,
        );
        await service.fireReminderNow(task('audible', 1));
        expect(
          sounds.where((call) => call.method == 'SystemSound.play'),
          isEmpty,
        );
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      }
    },
  );
  test(
    'focus application awaits OS outcome, reports failure and retries same policy',
    () async {
      final native = NativeProbe();
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      await service.scheduleReminder(task('focus-failure', 3));
      native.failCancel = true;
      final failed = await service.applyFocusMode(true);
      expect(failed, (attempted: 1, failed: 1));
      expect(service.isImmersiveModeActive, true);
      expect(native.pending, isNotEmpty);
      native.failCancel = false;
      final retried = await service.applyFocusMode(true);
      expect(retried, (attempted: 1, failed: 0));
      expect(native.pending, isEmpty);
      final resumed = await service.applyFocusMode(false);
      expect(resumed, (attempted: 1, failed: 0));
      expect(native.pending.keys, [stableNotificationId('focus-failure')]);
      await service.cancelReminder('focus-failure');
    },
  );

  test(
    'focus batches do not resurrect a task deleted behind an admitted batch',
    () async {
      final native = NativeProbe();
      final service = NotificationService.forTesting(
        native,
        usesNativeNotifications: true,
      );
      final tasks = List.generate(300, (i) => task('focus-batch-$i', 3));
      await Future.wait(tasks.map(service.scheduleReminder));
      final gate = Completer<void>();
      native.cancellation = gate;
      final apply = service.applyFocusMode(true);
      await Future<void>.delayed(Duration.zero);
      final deletion = service.cancelReminder(tasks.last.id);
      gate.complete();
      final result = await apply;
      await deletion;
      expect(result, (attempted: 299, failed: 0));
      expect(native.pending, isEmpty);
      native.cancellation = null;
      await service.applyFocusMode(false);
      expect(native.pending, hasLength(299));
      expect(
        native.pending.containsKey(stableNotificationId(tasks.last.id)),
        false,
      );
      await Future.wait(tasks.map((task) => service.cancelReminder(task.id)));
    },
  );
}
