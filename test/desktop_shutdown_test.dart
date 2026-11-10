import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/desktop_shutdown.dart';

void main() {
  test(
    'shutdown drains writes enqueued while an earlier draft is saving',
    () async {
      final first = Completer<void>(), second = Completer<void>();
      Future<void> pending = first.future;
      var done = false;
      final drain = drainDesktopWrites(
        () => pending,
        () => false,
      ).then((_) => done = true);
      pending = second.future;
      first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      second.complete();
      await drain;
      expect(done, isTrue);
    },
  );
  test(
    'upgrade exit waits for local preparation and coalesces duplicate requests',
    () async {
      final prepared = Completer<void>();
      final calls = <String>[];
      final upgrade = DesktopUpgradeExit(
        canExit: () => true,
        prepare: () async {
          calls.add('drafts');
          await prepared.future;
          calls.add('flushed');
        },
        exitApp: () async {
          calls.add('exit');
        },
      );
      final first = upgrade.request();
      expect(identical(first, upgrade.request()), isTrue);
      expect(calls, ['drafts']);
      prepared.complete();
      expect(await first, isTrue);
      expect(await upgrade.request(), isTrue);
      expect(calls, ['drafts', 'flushed', 'exit']);
    },
  );
  test(
    'recording or recovery veto leaves capture and storage untouched',
    () async {
      var idle = false, exits = 0, prepares = 0;
      final upgrade = DesktopUpgradeExit(
        canExit: () => idle,
        prepare: () async {
          prepares++;
        },
        exitApp: () async {
          exits++;
        },
      );
      expect(await upgrade.request(), isFalse);
      expect([prepares, exits], [0, 0]);
      idle = true;
      expect(await upgrade.request(), isTrue);
      expect([prepares, exits], [1, 1]);
    },
  );
  test(
    'failed draft preparation vetoes exit and permits an explicit retry',
    () async {
      var fail = true, exits = 0;
      final errors = <Object>[];
      final upgrade = DesktopUpgradeExit(
        canExit: () => true,
        prepare: () async {
          if (fail) throw StateError('draft write failed');
        },
        exitApp: () async {
          exits++;
        },
        onError: (e, _) => errors.add(e),
      );
      expect(await upgrade.request(), isFalse);
      expect(exits, 0);
      fail = false;
      expect(await upgrade.request(), isTrue);
      expect(exits, 1);
      expect(errors.single, isA<StateError>());
    },
  );
  test(
    'storage closes before the window is destroyed and before exit',
    () async {
      final order = <String>[];
      await shutdownDesktopApp(
        closeStorage: () async => order.add('storage'),
        destroyWindow: () async => order.add('window'),
        exitProcess: (code) => order.add('exit:$code'),
      );
      expect(order, ['storage', 'window', 'exit:0']);
    },
  );

  test('a failing storage close still tears down and exits', () async {
    final order = <String>[];
    final errors = <Object>[];
    await shutdownDesktopApp(
      closeStorage: () async => throw StateError('busy'),
      destroyWindow: () async => order.add('window'),
      exitProcess: (code) => order.add('exit:$code'),
      onError: (error, _) => errors.add(error),
    );
    expect(order, ['window', 'exit:0']);
    expect(errors.single, isA<StateError>());
  });

  test('a failing window destroy still exits', () async {
    final order = <String>[];
    await shutdownDesktopApp(
      closeStorage: () async => order.add('storage'),
      destroyWindow: () async => throw StateError('no window'),
      exitProcess: (code) => order.add('exit:$code'),
    );
    expect(order, ['storage', 'exit:0']);
  });

  test('exit is called exactly once even when both steps fail', () async {
    var exits = 0;
    await shutdownDesktopApp(
      closeStorage: () async => throw StateError('a'),
      destroyWindow: () async => throw StateError('b'),
      exitProcess: (_) => exits++,
    );
    expect(exits, 1);
  });
}
