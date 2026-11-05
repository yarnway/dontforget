import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/global_capture_shortcut.dart';
import 'package:dont_forget/services/recovery/runtime_gate.dart';

class _Backend implements CaptureShortcutBackend {
  late void Function(String) receive;
  final calls = <bool>[];
  bool conflict = false, failDisable = false, disposed = false;
  String? nonce;
  @override
  void listen(void Function(String) listener) => receive = listener;
  @override
  Future<bool> setEnabled(bool enabled, String token) async {
    calls.add(enabled);
    if (enabled && conflict || !enabled && failDisable) return false;
    nonce = enabled ? token : null;
    return true;
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Backend backend;
  late RuntimeRecoveryGate gate;
  late GlobalCaptureShortcut shortcut;
  bool saved = false, failWrite = false;
  int activations = 0;
  final writes = <bool>[];
  Completer<void>? blocked;
  setUp(() {
    saved = false;
    failWrite = false;
    activations = 0;
    writes.clear();
    blocked = null;
    backend = _Backend();
    gate = RuntimeRecoveryGate();
    shortcut = GlobalCaptureShortcut(
      backend: backend,
      runtime: gate,
      readSaved: () async => saved,
      writeSaved: (value) async {
        if (blocked != null) await blocked!.future;
        if (failWrite) throw StateError('Disk unavailable');
        writes.add(value);
        saved = value;
      },
    );
  });
  tearDown(() async {
    shortcut.dispose();
    await shortcut.flushed;
  });
  Future<void> start() => shortcut.start(() => activations++);

  test(
    'opt-in defaults off; enable and disable persist only explicit changes',
    () async {
      await start();
      expect(shortcut.ready, isTrue);
      expect(shortcut.enabled, isFalse);
      expect(backend.calls, [false]);
      expect(writes, isEmpty);
      await shortcut.setEnabled(true);
      final nonce = backend.nonce!;
      backend.receive(nonce);
      expect(activations, 1);
      await shortcut.setEnabled(true);
      expect(writes, [true]);
      backend.receive('stale-or-untrusted');
      expect(activations, 1);
      await shortcut.setEnabled(false);
      backend.receive(nonce);
      expect(activations, 1);
      expect(writes, [true, false]);
      expect(shortcut.registered, isFalse);
    },
  );

  test(
    'OS conflict does not persist a new opt-in or dispatch capture',
    () async {
      await start();
      backend.conflict = true;
      await shortcut.setEnabled(true);
      expect(shortcut.error, 'conflict');
      expect(shortcut.enabled, isFalse);
      expect(shortcut.registered, isFalse);
      expect(writes, isEmpty);
      backend.receive('');
      expect(activations, 0);
      backend.conflict = false;
      await shortcut.setEnabled(true);
      expect(shortcut.error, isNull);
      expect(shortcut.registered, isTrue);
    },
  );

  test(
    'startup conflict preserves saved opt-in and permits disabling it',
    () async {
      saved = true;
      backend.conflict = true;
      await start();
      expect(shortcut.enabled, isTrue);
      expect(shortcut.registered, isFalse);
      expect(shortcut.error, 'conflict');
      expect(writes, isEmpty);
      await shortcut.setEnabled(false);
      expect(saved, isFalse);
      expect(shortcut.error, isNull);
    },
  );

  test('failed persistence restores old binding with a fresh nonce', () async {
    saved = true;
    await start();
    final old = backend.nonce!;
    failWrite = true;
    await shortcut.setEnabled(false);
    expect(saved, isTrue);
    expect(shortcut.enabled, isTrue);
    expect(shortcut.registered, isTrue);
    expect(shortcut.error, 'saveFailed');
    expect(backend.nonce, isNot(old));
    backend.receive(old);
    expect(activations, 0);
    backend.receive(backend.nonce!);
    expect(activations, 1);
  });

  test(
    'recovery rejects queued events immediately and rebinds a new session',
    () async {
      saved = true;
      await start();
      final old = backend.nonce!;
      final pausing = gate.pause();
      backend.receive(old);
      expect(activations, 0);
      final token = await pausing;
      expect(shortcut.ready, isFalse);
      expect(shortcut.registered, isFalse);
      gate.resume(token);
      backend.receive(old);
      expect(activations, 0);
      await start();
      expect(backend.nonce, isNot(old));
      backend.receive(old);
      backend.receive(backend.nonce!);
      expect(activations, 1);
    },
  );

  test('recovery drains an in-flight local write before unbinding', () async {
    await start();
    blocked = Completer<void>();
    final enabling = shortcut.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(shortcut.busy, isTrue);
    final old = backend.nonce!;
    var completed = false;
    final pausing = gate.pause().then((token) {
      completed = true;
      return token;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    backend.receive(old);
    expect(activations, 0);
    blocked!.complete();
    await enabling;
    final token = await pausing;
    expect(saved, isTrue);
    expect(backend.nonce, isNull);
    gate.resume(token);
    await start();
    expect(shortcut.enabled, isTrue);
    expect(shortcut.registered, isTrue);
  });

  test(
    'failed native cleanup leaves recovery paused and can be retried',
    () async {
      saved = true;
      await start();
      final old = backend.nonce!;
      backend.failDisable = true;
      await expectLater(gate.pause(), throwsStateError);
      expect(gate.paused, isTrue);
      backend.receive(old);
      expect(activations, 0);
      backend.failDisable = false;
      final token = await gate.pause();
      gate.resume(token);
      await start();
      expect(shortcut.ready, isTrue);
    },
  );

  test(
    'older MethodChannel backend cannot clear or disable its successor',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(
        WindowsCaptureShortcutBackend.channel,
        (call) async {
          calls.add(call);
          return true;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          WindowsCaptureShortcutBackend.channel,
          null,
        ),
      );
      final first = WindowsCaptureShortcutBackend()..listen((_) {});
      final received = <String>[];
      final second = WindowsCaptureShortcutBackend()..listen(received.add);
      expect(await first.setEnabled(false, ''), isTrue);
      first.dispose();
      expect(calls, isEmpty);
      await messenger.handlePlatformMessage(
        WindowsCaptureShortcutBackend.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onCapture', 'current'),
        ),
        (_) {},
      );
      expect(received, ['current']);
      expect(await second.setEnabled(true, 'current'), isTrue);
      expect(calls.single.arguments, {'enabled': true, 'nonce': 'current'});
      second.dispose();
    },
  );
}
