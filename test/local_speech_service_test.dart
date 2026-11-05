import 'dart:async';
import 'package:dont_forget/services/local_speech_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/local_speech');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'Android uses finalized audio and never opens a live speech session',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'transcribe' ? ' 明天下午开会 ' : null;
      });
      final service = LocalSpeechService(
        isIOS: false,
        isAndroid: true,
        channel: channel,
      );
      expect(service.supported, isTrue);
      expect(service.android, isTrue);
      expect(await service.transcribe('/private/capture.m4a', 'zh'), '明天下午开会');
      expect(calls.single.method, 'transcribe');
      expect(calls.single.arguments, {
        'path': '/private/capture.m4a',
        'locale': 'zh-CN',
      });
      await service.cancel();
      expect(calls.last.method, 'cancel');
    },
  );
  test(
    'Android capability and language errors retain their native codes',
    () async {
      for (final code in [
        'speech_unavailable',
        'speech_language_unavailable',
        'speech_permission_denied',
      ]) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: code),
        );
        await expectLater(
          LocalSpeechService(
            isIOS: false,
            isAndroid: true,
            channel: channel,
          ).transcribe('/private/capture.m4a', 'zh'),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
        );
      }
    },
  );
  for (final language in ['zh', 'ja', 'en']) {
    test('$language is recognized through the local channel only', () async {
      MethodCall? request;
      messenger.setMockMethodCallHandler(channel, (call) async {
        request = call;
        return '  Editable text  ';
      });
      final service = LocalSpeechService(isIOS: true, channel: channel);
      expect(
        await service.transcribe('/isolated/audio.m4a', language),
        'Editable text',
      );
      expect(request!.method, 'transcribe');
      expect(
        (request!.arguments as Map)['locale'],
        {'zh': 'zh-CN', 'ja': 'ja-JP', 'en': 'en-US'}[language],
      );
    });
  }
  test('cancel invalidates a late native result', () async {
    final result = Completer<String>();
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'cancel' ? null : await result.future,
    );
    final service = LocalSpeechService(isIOS: true, channel: channel);
    final pending = service.transcribe('/isolated/audio.m4a', 'zh');
    final rejected = expectLater(
      pending,
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'speech_cancelled',
        ),
      ),
    );
    await service.cancel();
    result.complete('stale');
    await rejected;
  });
  test(
    'empty speech stays a failure rather than a successful empty draft',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => '  ');
      await expectLater(
        LocalSpeechService(
          isIOS: true,
          channel: channel,
        ).transcribe('/isolated/audio.m4a', 'zh'),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
