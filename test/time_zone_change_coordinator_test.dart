import 'dart:async';

import 'package:dont_forget/services/time_zone_change_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stable identity does no reload; equal-offset zone change does',
    () async {
      var identifier = 'America/New_York';
      var reloads = 0;
      final monitor = TimeZoneChangeCoordinator(
        localSignature: () => 'same seasonal offsets',
        readIdentifier: () async => identifier,
        reload: () async => reloads++,
      );
      await monitor.tick();
      await monitor.tick();
      expect(reloads, 0);
      identifier = 'America/Toronto';
      await monitor.tick();
      expect(reloads, 1);
      await monitor.tick();
      expect(reloads, 1);
      await monitor.stop();
    },
  );

  test(
    'offset transition and change during initial read are detected',
    () async {
      var local = 'winter';
      final firstRead = Completer<String?>();
      var reloads = 0;
      final monitor = TimeZoneChangeCoordinator(
        localSignature: () => local,
        readIdentifier: () => firstRead.future,
        reload: () async => reloads++,
      );
      final checking = monitor.tick();
      local = 'summer';
      firstRead.complete('America/New_York');
      await checking;
      expect(reloads, 1);
      local = 'winter';
      await monitor.tick();
      expect(reloads, 2);
      await monitor.stop();
    },
  );

  test(
    'failed read and failed reload do not acknowledge a changed zone',
    () async {
      var local = 'old';
      var failRead = false;
      var failReload = true;
      var attempts = 0;
      final monitor = TimeZoneChangeCoordinator(
        localSignature: () => local,
        readIdentifier: () async {
          if (failRead) throw StateError('platform read failed');
          return 'zone';
        },
        reload: () async {
          attempts++;
          if (failReload) throw StateError('SQL read failed');
        },
      );
      await monitor.tick();
      local = 'new';
      failRead = true;
      await monitor.tick();
      expect(attempts, 0);
      failRead = false;
      await monitor.tick();
      expect(attempts, 1);
      failReload = false;
      await monitor.tick();
      await monitor.tick();
      expect(attempts, 2);
      await monitor.stop();
    },
  );

  test('coalesces in-flight ticks and rechecks a later transition', () async {
    var local = 'first';
    var attempts = 0;
    final started = Completer<void>();
    final release = Completer<void>();
    final monitor = TimeZoneChangeCoordinator(
      localSignature: () => local,
      readIdentifier: () async => null,
      reload: () async {
        attempts++;
        if (attempts == 1) {
          started.complete();
          await release.future;
        }
      },
    );
    local = 'second';
    final first = monitor.tick();
    await started.future;
    local = 'third';
    final second = monitor.tick();
    expect(identical(first, second), isTrue);
    release.complete();
    await second;
    await monitor.tick();
    expect(attempts, 2);
    await monitor.stop();
  });

  test('stop drops a late identity read before any reload', () async {
    var local = 'old';
    var attempts = 0;
    final read = Completer<String?>();
    final monitor = TimeZoneChangeCoordinator(
      localSignature: () => local,
      readIdentifier: () => read.future,
      reload: () async => attempts++,
    );
    local = 'new';
    final tick = monitor.tick();
    final stopping = monitor.stop();
    read.complete('zone');
    await Future.wait([tick, stopping]);
    await monitor.tick();
    expect(attempts, 0);
  });

  test('stop drains an already admitted reload before recovery', () async {
    var local = 'old';
    final started = Completer<void>();
    final release = Completer<void>();
    final monitor = TimeZoneChangeCoordinator(
      localSignature: () => local,
      readIdentifier: () async => null,
      reload: () async {
        started.complete();
        await release.future;
      },
    );
    local = 'new';
    final tick = monitor.tick();
    await started.future;
    var stopped = false;
    final stopping = monitor.stop().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    release.complete();
    await Future.wait([tick, stopping]);
    expect(stopped, isTrue);
  });
}
