import 'dart:async';
import 'package:dont_forget/services/security/credential_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const store = SystemCredentialStore();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'read' ? 'public synthetic value' : null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'ad hoc macOS uses login Keychain consistently for all operations',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await store.write('synthetic-id', 'public synthetic value');
      expect(await store.read('synthetic-id'), 'public synthetic value');
      await store.delete('synthetic-id');
      expect(calls.map((c) => c.method), ['write', 'read', 'delete']);
      for (final call in calls) {
        final options = call.arguments['options'] as Map;
        expect(options['accountName'], 'dontforget.ai.v1');
        expect(options['usesDataProtectionKeychain'], 'false');
        expect(options['synchronizable'], 'false');
        expect(options['useSecureEnclave'], 'false');
      }
    },
  );
  test(
    'iOS secrets are device only and Android does not reset on failure',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await store.read('synthetic-id');
      expect(
        calls.last.arguments['options']['accessibility'],
        'unlocked_this_device',
      );
      expect(calls.last.arguments['options']['synchronizable'], 'false');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await store.read('synthetic-id');
      expect(calls.last.arguments['options']['resetOnError'], 'false');
      expect(
        calls.last.arguments['options']['storageNamespace'],
        'dontforget.ai.v1',
      );
    },
  );
  test(
    'platform failure propagates without a fallback or automatic delete',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            throw PlatformException(code: 'synthetic_locked');
          });
      await expectLater(
        store.read('synthetic-id'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        store.write('synthetic-id', 'public'),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.map((c) => c.method), ['read', 'write']);
    },
  );
  testWidgets('an unavailable native callback has a bounded timeout', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => pending.future);
    final result = store.read('synthetic-id');
    final checked = expectLater(result, throwsA(isA<TimeoutException>()));
    await tester.pump(SystemCredentialStore.operationTimeout);
    await checked;
    pending.complete(null);
    await tester.pump();
  });
}
