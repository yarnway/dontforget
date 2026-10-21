import 'dart:async';

import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/recovery/runtime_gate.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'pause synchronously invalidates old tokens and drains every participant',
    () async {
      final gate = RuntimeRecoveryGate();
      final old = gate.capture();
      final release = Completer<void>();
      var calls = 0;
      gate.register(Object(), () async {
        calls++;
        await release.future;
      });
      final pausing = gate.pause();
      expect(gate.paused, isTrue);
      expect(gate.isCurrent(old), isFalse);
      expect(gate.capture, throwsA(isA<RuntimeRecoveryException>()));
      expect(identical(gate.pause(), pausing), isTrue);
      expect(calls, 1);
      release.complete();
      final lease = await pausing;
      gate.resume(lease);
      expect(gate.isCurrent(old), isFalse);
      expect(gate.isCurrent(gate.capture()), isTrue);
      expect(
        () => gate.resume(lease),
        throwsA(isA<RuntimeRecoveryException>()),
      );
      final next = await gate.pause();
      expect(
        () => gate.resume(lease),
        throwsA(isA<RuntimeRecoveryException>()),
      );
      expect(gate.paused, isTrue);
      gate.resume(next);
    },
  );

  test(
    'failed participant keeps gate closed until all cleanup can be retried',
    () async {
      final gate = RuntimeRecoveryGate();
      final release = Completer<void>();
      var failing = true;
      var drained = false;
      gate.register(Object(), () async {
        if (failing) throw StateError('cancel failed');
      });
      gate.register(Object(), () async {
        await release.future;
        drained = true;
      });
      final pause = gate.pause();
      final failure = expectLater(pause, throwsStateError);
      release.complete();
      await failure;
      expect(drained, isTrue);
      expect(gate.paused, isTrue);
      failing = false;
      final token = await gate.pause();
      gate.resume(token);
      expect(gate.paused, isFalse);
    },
  );

  test('tokens cannot resume or operate another gate', () async {
    final first = RuntimeRecoveryGate();
    final second = RuntimeRecoveryGate();
    expect(second.isCurrent(first.capture()), isFalse);
    final token = await first.pause();
    final secondToken = await second.pause();
    expect(
      () => second.resume(token),
      throwsA(isA<RuntimeRecoveryException>()),
    );
    second.resume(secondToken);
    first.resume(token);
  });

  test(
    'context recovery forgets old tasks while preserving focus policy',
    () async {
      final context = ContextTriggerService.forTesting();
      final reminder = Reminder(
        id: 'same-id',
        taskTitle: 'old',
        quadrantLevel: 3,
        contextTrigger: const ContextTriggerRule(
          type: 'profile',
          value: 'deepWork',
        ).toJsonString(),
      );
      context.switchProfile(ContextProfile.deepWork);
      expect(context.shouldInterceptNotification(reminder), isTrue);
      expect(context.evaluateContextTriggers([reminder]), [reminder]);
      expect(context.evaluateContextTriggers([reminder]), isEmpty);
      var digests = 0;
      final subscription = context.onCatchUpDigestReady.listen(
        (_) => digests++,
      );
      context.resetForRecovery();
      expect(context.currentProfile, ContextProfile.deepWork);
      expect(context.suppressedReminders, isEmpty);
      expect(context.detectedSsid, isNull);
      expect(context.evaluateContextTriggers([reminder]), [reminder]);
      context.switchProfile(ContextProfile.general);
      await Future<void>.delayed(Duration.zero);
      expect(digests, 0);
      await subscription.cancel();
    },
  );
}
