import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/windows_protocol_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(WindowsProtocolService.dispose);
  test(
    'upgrade event waits for cleanup and never becomes a task route',
    () async {
      var called = false, routed = false;
      final release = Completer<void>();
      WindowsProtocolService.initialize(
        onRoute: (_) => routed = true,
        onUpgradeExit: () async {
          called = true;
          await release.future;
        },
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();
      final done = Completer<void>();
      unawaited(
        messenger.handlePlatformMessage(
          'com.yarnway.dontforget/protocol',
          codec.encodeMethodCall(const MethodCall('onUpgradeExit')),
          (_) => done.complete(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(called, isTrue);
      expect(done.isCompleted, isFalse);
      expect(routed, isFalse);
      release.complete();
      await done.future;
    },
  );
}
