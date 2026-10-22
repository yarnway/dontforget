import 'dart:async';

import 'package:dont_forget/services/notification_retry_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'foreground pump serializes work and respects one minute cooldown',
    () async {
      var now = DateTime.utc(2026, 10, 22);
      var calls = 0;
      final gate = Completer<void>();
      final coordinator = NotificationRetryCoordinator(
        now: () => now,
        run: (_) async {
          calls++;
          await gate.future;
        },
      );
      await coordinator.tick();
      expect(calls, 0);
      coordinator.setForeground(true);
      final first = coordinator.tick();
      expect(coordinator.tick(), same(first));
      expect(calls, 1);
      gate.complete();
      await first;
      now = now.add(const Duration(seconds: 59));
      await coordinator.tick();
      expect(calls, 1);
      now = now.add(const Duration(seconds: 1));
      await coordinator.tick();
      expect(calls, 2);
      await coordinator.stop();
      now = now.add(const Duration(minutes: 1));
      await coordinator.tick();
      expect(calls, 2);
    },
  );

  test('leaving foreground invalidates an in-flight permission read', () async {
    final gate = Completer<void>();
    var nativeCalls = 0;
    final coordinator = NotificationRetryCoordinator(
      run: (isActive) async {
        await gate.future;
        if (isActive()) nativeCalls++;
      },
    );
    coordinator.setForeground(true);
    final running = coordinator.tick();
    coordinator.setForeground(false);
    coordinator.setForeground(true);
    gate.complete();
    await running;
    expect(nativeCalls, 0);
    await coordinator.stop();
  });

  test('stop invalidates and drains the active worker', () async {
    final gate = Completer<void>();
    var drained = false;
    final coordinator = NotificationRetryCoordinator(
      run: (isActive) async {
        await gate.future;
        expect(isActive(), isFalse);
        drained = true;
      },
    );
    coordinator.setForeground(true);
    final running = coordinator.tick();
    final stopped = coordinator.stop();
    expect(drained, isFalse);
    gate.complete();
    await stopped;
    await running;
    expect(drained, isTrue);
  });

  test(
    'failed reads remain bounded and a backward clock can recover',
    () async {
      var now = DateTime.utc(2026, 10, 22);
      var calls = 0;
      final coordinator = NotificationRetryCoordinator(
        now: () => now,
        run: (_) async {
          calls++;
          throw StateError('unavailable');
        },
      );
      coordinator.setForeground(true);
      await coordinator.tick();
      await coordinator.tick();
      expect(calls, 1);
      now = now.subtract(const Duration(hours: 1));
      await coordinator.tick();
      expect(calls, 2);
      await coordinator.tick();
      expect(calls, 2);
      await coordinator.stop();
    },
  );
}
