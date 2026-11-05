import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/speech_settings.dart';
import 'package:dont_forget/models/tencent_speech_credentials.dart';
import 'package:dont_forget/services/speech_recognition_service.dart';
import 'support/m4a_metadata_fixture.dart';

class _Adapter implements HttpClientAdapter {
  int calls = 0;
  RequestOptions? options;
  List<int>? audio;
  ResponseBody response = ResponseBody.fromString(
    '{"code":0,"flash_result":[{"channel_id":0,"text":"ok"}]}',
    200,
  );
  Completer<ResponseBody>? pending;
  Object? failure;
  final entered = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    this.options = options;
    audio = await requestStream!.expand((x) => x).toList();
    if (!entered.isCompleted) entered.complete();
    if (failure != null) throw failure!;
    if (pending == null) return response;
    return Future.any([
      pending!.future,
      if (cancelFuture != null)
        cancelFuture.then(
          (_) => throw DioException.requestCancelled(
            requestOptions: options,
            reason: 'redacted',
          ),
        ),
    ]);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory root;
  late File audio;
  late _Adapter adapter;
  late SpeechRecognitionService service;
  final config = SpeechSettings(
    enabled: true,
    endpoint: TencentSpeechCredentials.endpoint,
    model: TencentSpeechCredentials.engine,
    apiKey: const TencentSpeechCredentials(
      appId: '1259000000',
      secretId: 'AKIDTESTID12345678',
      secretKey: 'test-secret-key-for-unit-only',
    ).encode(),
  );
  Matcher code(String value) => throwsA(
    isA<SpeechRecognitionException>().having((e) => e.code, 'safe code', value),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tencent-speech-');
    audio = await File(
      '${root.path}/recording.m4a',
    ).writeAsBytes(m4aMetadata(ticks: 2000));
    adapter = _Adapter();
    service = SpeechRecognitionService(
      dio: Dio()..httpClientAdapter = adapter,
      now: () =>
          DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    );
  });
  tearDown(() async {
    service.dispose();
    await root.delete(recursive: true);
  });
  for (final text in [
    '明天早上买牛奶。',
    'Buy milk tomorrow morning.',
    '明天 meeting at nine',
  ]) {
    test('Tencent returns Chinese/English draft: $text', () async {
      adapter.response = ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'flash_result': [
            {'channel_id': 0, 'text': text},
          ],
        }),
        200,
      );
      expect(await service.transcribe(audio.path, config), text);
      expect(adapter.audio, await audio.readAsBytes());
    });
  }
  test(
    'signature matches independent fixed vector and audio is binary, with fixed destination and no redirect',
    () async {
      await service.transcribe(audio.path, config);
      final request = adapter.options!;
      expect(request.headers['Authorization'], 'zaVFCCTCwt2SalwpFJzKVbjeOsA=');
      expect(request.uri.host, 'asr.cloud.tencent.com');
      expect(request.uri.path, '/asr/flash/v1/1259000000');
      expect(request.uri.queryParameters['engine_type'], '16k_zh_en');
      expect(request.uri.queryParameters['word_info'], '0');
      expect(request.uri.toString(), isNot(contains('test-secret-key')));
      expect(request.contentType, 'application/octet-stream');
      expect(request.followRedirects, false);
      expect(request.headers['Content-Length'], '${await audio.length()}');
    },
  );
  test(
    'invalid or redirected credential metadata cannot send audio or secrets',
    () async {
      for (final invalid in [
        config.copyWith(enabled: false),
        config.copyWith(apiKey: 'other-provider-key'),
        config.copyWith(endpoint: 'https://other.invalid'),
        config.copyWith(model: 'other-model'),
      ]) {
        await expectLater(
          service.transcribe(audio.path, invalid),
          code('not_configured'),
        );
      }
      expect(adapter.calls, 0);
    },
  );
  test(
    'size and duration bounds reject before network without deleting original',
    () async {
      await audio.writeAsBytes(m4aMetadata(ticks: 301000));
      await expectLater(
        service.transcribe(audio.path, config),
        code('too_long'),
      );
      final oversized = File(
        '${root.path}/oversized.m4a',
      ).openSync(mode: FileMode.write);
      oversized.truncateSync(SpeechRecognitionService.maxBytes + 1);
      oversized.closeSync();
      await expectLater(
        service.transcribe('${root.path}/oversized.m4a', config),
        code('too_large'),
      );
      expect(adapter.calls, 0);
      expect(await audio.exists(), true);
    },
  );
  test(
    'provider errors use safe codes without echoing messages or credentials',
    () async {
      for (final pair in {
        4002: 'authentication',
        4003: 'not_activated',
        4004: 'quota',
        4006: 'throttled',
        4007: 'format',
        5003: 'timeout',
      }.entries) {
        adapter.response = ResponseBody.fromString(
          jsonEncode({'code': pair.key, 'message': config.apiKey}),
          200,
        );
        await expectLater(
          service.transcribe(audio.path, config),
          code(pair.value),
        );
      }
    },
  );
  test(
    'empty/malformed and oversized provider responses stay failures',
    () async {
      for (final data in [
        null,
        {'code': 0},
        {'code': 0, 'flash_result': []},
        {
          'code': 0,
          'flash_result': [
            {'channel_id': 0, 'text': 12},
          ],
        },
      ]) {
        adapter.response = ResponseBody.fromString(jsonEncode(data), 200);
        await expectLater(
          service.transcribe(audio.path, config),
          code('invalid_response'),
        );
      }
      adapter.response = ResponseBody.fromString(
        '{"code":0,"flash_result":[{"channel_id":0,"text":" "}]}',
        200,
      );
      await expectLater(service.transcribe(audio.path, config), code('empty'));
      adapter.response = ResponseBody(
        Stream.value(Uint8List(SpeechRecognitionService.maxResponseBytes + 1)),
        200,
      );
      await expectLater(
        service.transcribe(audio.path, config),
        code('invalid_response'),
      );
    },
  );
  test(
    'HTTP redirect and authentication never follow a different destination',
    () async {
      adapter.response = ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://other.invalid'],
        },
      );
      await expectLater(
        service.transcribe(audio.path, config),
        code('network'),
      );
      expect(adapter.calls, 1);
      expect(adapter.options!.followRedirects, false);
    },
  );
  test(
    'recovery cancellation rejects late success and preserves original audio',
    () async {
      adapter.pending = Completer<ResponseBody>();
      final result = service.transcribe(audio.path, config);
      final rejected = expectLater(result, code('cancelled'));
      await adapter.entered.future;
      service.cancel();
      await rejected;
      adapter.pending!.complete(
        ResponseBody.fromString(
          '{"code":0,"flash_result":[{"channel_id":0,"text":"stale"}]}',
          200,
        ),
      );
      expect(await audio.exists(), true);
    },
  );
  test('bounded request timeout cancels an unresponsive request', () async {
    service.dispose();
    adapter.pending = Completer<ResponseBody>();
    service = SpeechRecognitionService(
      dio: Dio()..httpClientAdapter = adapter,
      requestTimeout: const Duration(milliseconds: 40),
    );
    await expectLater(service.transcribe(audio.path, config), code('timeout'));
  });
}
