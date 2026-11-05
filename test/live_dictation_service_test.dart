import 'dart:async';
import 'package:dont_forget/services/live_dictation_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/live_dictation');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late LiveDictationService service;
  late List<MethodCall> calls;
  late List<DictationEvent> events;
  Completer<void>? pendingStart, pendingCancel;
  String? failure;
  String locale = 'zh-CN';
  Future<void> event(
    String session,
    String type, {
    dynamic text = '',
    String? code,
  }) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('onEvent', {
          'session': session,
          'type': type,
          'text': text,
          'code': code,
        }),
      ),
      (_) {},
    );
  }

  setUp(() {
    calls = [];
    events = [];
    pendingStart = null;
    pendingCancel = null;
    failure = null;
    locale = 'zh-CN';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'start':
          if (failure != null) throw PlatformException(code: failure!);
          if (pendingStart != null) await pendingStart!.future;
          return null;
        case 'cancel':
          if (pendingCancel != null) await pendingCancel!.future;
          return null;
        case 'availability':
          return {'available': true, 'locale': locale};
        case 'setLanguage':
          locale = (call.arguments as Map)['locale'] as String;
          return null;
        default:
          return null;
      }
    });
    service = LiveDictationService(
      channel: channel,
      isAndroid: true,
      sessionTimeout: const Duration(seconds: 10),
      stopTimeout: const Duration(seconds: 2),
    );
    service.events.listen(events.add);
  });
  tearDown(() async {
    await service.cancel();
    service.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
  });
  test(
    'partial then final stays scoped to one live microphone session',
    () async {
      await service.start('one');
      await event('one', 'ready');
      await event('one', 'partial', text: '明天');
      await event('one', 'partial', text: '明天开会');
      await event('one', 'final', text: '明天开会。');
      expect(events.map((e) => e.text), ['', '', '明天', '明天开会', '明天开会。']);
      expect(service.active, false);
      expect(calls.single.arguments, {'session': 'one'});
      expect(calls.single.method, 'start');
    },
  );
  test(
    'old, malformed and oversized callbacks cannot mutate a new session',
    () async {
      await service.start('old');
      await service.cancel();
      await service.start('new');
      final count = events.length;
      await event('old', 'final', text: 'stale');
      await event('new', 'partial', text: 7);
      await event('new', 'partial', text: 'a' * 32001);
      await event('new', 'unknown', text: 'wrong type');
      expect(events.length, count);
      expect(service.active, true);
      await event('new', 'final', text: 'English dictation');
      expect(events.last.text, 'English dictation');
    },
  );
  test(
    'blank final and network error preserve the last recognized words',
    () async {
      for (final type in ['final', 'error']) {
        await service.start(type);
        await event(type, 'partial', text: 'Keep my words');
        await event(
          type,
          type,
          code: type == 'error' ? 'dictation_network' : null,
        );
        expect(events.last.text, 'Keep my words');
        expect(events.last.terminal, true);
      }
    },
  );
  test('stop waits for final and is idempotent', () async {
    await service.start('one');
    await service.stop();
    await service.stop();
    expect(service.active, true);
    expect(calls.where((c) => c.method == 'stop').length, 1);
    await event('one', 'final', text: 'complete');
    expect(service.active, false);
  });
  test(
    'cancel during permission prevents a late result entering any draft',
    () async {
      pendingStart = Completer<void>();
      final start = service.start('permission');
      await Future<void>.delayed(Duration.zero);
      await service.cancel();
      expect(service.active, false);
      expect(events.last.type, 'cancelled');
      pendingStart!.complete();
      await start;
      final count = events.length;
      await event('permission', 'final', text: 'late granted');
      expect(events.length, count);
    },
  );
  test(
    'cancel acknowledgement gates restart and ignores racing results',
    () async {
      await service.start('one');
      await event('one', 'partial', text: 'safe');
      pendingCancel = Completer<void>();
      final cancel = service.cancel();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        service.start('new'),
        throwsA(isA<PlatformException>()),
      );
      await event('one', 'final', text: 'racing');
      pendingCancel!.complete();
      await cancel;
      expect(events.last.text, 'safe');
      expect(service.active, false);
    },
  );
  test(
    'start permission rejection ends the session without dropping the draft',
    () async {
      failure = 'dictation_permission';
      await service.start('denied');
      expect(events.last.code, failure);
      expect(events.last.terminal, true);
      expect(service.active, false);
    },
  );
  test(
    'bounded stop timeout cancels native microphone before terminal event',
    () async {
      service.dispose();
      await Future<void>.delayed(Duration.zero);
      service = LiveDictationService(
        channel: channel,
        isAndroid: true,
        stopTimeout: const Duration(milliseconds: 15),
      );
      service.events.listen(events.add);
      await service.start('timeout');
      await event('timeout', 'partial', text: 'kept');
      await service.stop();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(calls.last.method, 'cancel');
      expect(service.active, false);
      expect(events.last.code, 'dictation_timeout');
      expect(events.last.text, 'kept');
    },
  );
  test(
    'background stops live capture, inactive permission overlay does not',
    () async {
      await service.start('background');
      service.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(service.active, true);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(service.active, false);
      expect(calls.last.method, 'cancel');
    },
  );
  test(
    'disposing an old service cannot remove a replacement service callback',
    () async {
      await service.start('old');
      pendingCancel = Completer<void>();
      service.dispose();
      await Future<void>.delayed(Duration.zero);
      service = LiveDictationService(channel: channel, isAndroid: true);
      service.events.listen(events.add);
      pendingCancel!.complete();
      await Future<void>.delayed(Duration.zero);
      await service.start('replacement');
      await event('replacement', 'final', text: 'new engine');
      expect(events.last.text, 'new engine');
      expect(service.active, false);
    },
  );

  test(
    'Chinese and English are explicit device preferences, not chat configuration',
    () async {
      expect((await service.availability()).locale, 'zh-CN');
      await service.setLanguage('en-US');
      expect((await service.availability()).locale, 'en-US');
      await expectLater(
        service.setLanguage('fr-FR'),
        throwsA(isA<PlatformException>()),
      );
      await service.start('one');
      await expectLater(
        service.setLanguage('zh-CN'),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
