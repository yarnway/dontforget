import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/desktop_shutdown.dart';

void main() {
  test('storage closes before the window is destroyed and before exit', () async {
    final order = <String>[];
    await shutdownDesktopApp(
      closeStorage: () async => order.add('storage'),
      destroyWindow: () async => order.add('window'),
      exitProcess: (code) => order.add('exit:$code'),
    );
    expect(order, ['storage', 'window', 'exit:0']);
  });

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
