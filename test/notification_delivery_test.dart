import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';

class NativeProbe implements FlutterLocalNotificationsPlugin {
  Completer<void>? initialization;
  Completer<void>? scheduling;
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
        pending.remove(i.positionalArguments[0]);
        return Future<void>.value();
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
    final emitted = <Reminder>[];
    final subscription = service.onReminderDue.listen(emitted.add);
    try {
      service.fireReminderNow(task('focus', 3));
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);
    } finally {
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
        expect(native.pending.keys, ['urgent'.hashCode]);
        await service.cancelReminder('quiet');
        service.isImmersiveModeActive = false;
        await service.reconcileNotificationPolicy();
        expect(native.pending.keys, ['urgent'.hashCode]);
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
        expect(native.pending.keys, ['context'.hashCode]);
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

  test('low priority due reminder does not request an in-app sound', () async {
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
        hasLength(1),
      );
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });
}
