import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:dont_forget/services/tencent_recording_profile.dart';
import 'package:dont_forget/services/recording_duration_reader.dart';
import 'package:dont_forget/models/speech_settings.dart';
import 'package:dont_forget/models/tencent_speech_credentials.dart';
import 'package:dont_forget/services/pcm_wave_reader.dart';
import 'package:dont_forget/services/speech_recognition_service.dart';
import 'package:dont_forget/services/tencent_realtime_recognizer.dart';
import 'support/pcm_wave_fixture.dart';

void main() {
  const credentials = TencentSpeechCredentials(
    appId: '1259000000',
    secretId: 'AKIDTESTID12345678',
    secretKey: 'unit-secret-realtime',
  );
  final config = SpeechSettings(enabled: true, apiKey: credentials.encode());
  late Directory root;
  late File audio;
  late HttpServer server;
  late Uri signed;
  late List<WebSocket> sockets;
  late List<int> received;
  late List<int> packetSizes;
  late List<Duration> delays;
  late TencentRealtimeRecognizer realtime;
  late SpeechRecognitionService service;
  late void Function(WebSocket, String) connected;
  late void Function(WebSocket, String) end;
  late void Function(WebSocket, String) audioReceived;
  void event(WebSocket socket, String voiceId, Map<String, dynamic> data) {
    socket.add(jsonEncode({'code': 0, 'voice_id': voiceId, ...data}));
  }

  Matcher code(String expected) => throwsA(
    isA<SpeechRecognitionException>().having(
      (error) => error.code,
      'safe code',
      expected,
    ),
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('realtime-asr-');
    audio = await File('${root.path}/voice.wav').writeAsBytes(pcmWave());
    sockets = [];
    received = [];
    packetSizes = [];
    delays = [];
    connected = (socket, id) => event(socket, id, {});
    audioReceived = (_, _) {};
    end = (socket, id) {
      event(socket, id, {
        'result': {'slice_type': 1, 'index': 0, 'voice_text_str': 'unstable'},
      });
      event(socket, id, {
        'result': {
          'slice_type': 2,
          'index': 0,
          'voice_text_str': '明天 meeting at nine。',
        },
      });
      event(socket, id, {'final': 1});
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      final id = signed.queryParameters['voice_id']!;
      socket.listen((message) {
        if (message is List<int>) {
          received.addAll(message);
          packetSizes.add(message.length);
          audioReceived(socket, id);
        } else if (message == '{"type":"end"}') {
          end(socket, id);
        }
      });
      connected(socket, id);
    });
    realtime = TencentRealtimeRecognizer(
      connect: (uri) {
        signed = uri;
        return WebSocket.connect('ws://127.0.0.1:${server.port}');
      },
      now: () =>
          DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      delay: (duration) async {
        delays.add(duration);
        await Future<void>.delayed(Duration.zero);
      },
    );
    service = SpeechRecognitionService(realtime: realtime);
  });
  tearDown(() async {
    service.dispose();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test(
    'PCM is paced and signed, unstable text replaced, editable final returned',
    () async {
      expect(
        await service.transcribe(audio.path, config),
        '明天 meeting at nine。',
      );
      expect(received, (await audio.readAsBytes()).sublist(44));
      expect(delays, [
        const Duration(milliseconds: 200),
        const Duration(milliseconds: 200),
      ]);
      expect(signed.scheme, 'wss');
      expect(signed.host, 'asr.cloud.tencent.com');
      expect(signed.path, '/asr/v2/1259000000');
      final params = Map<String, String>.from(signed.queryParameters);
      final signature = params.remove('signature');
      final keys = params.keys.toList()..sort();
      final canonical =
          '${signed.host}${signed.path}?${keys.map((k) => '$k=${params[k]}').join('&')}';
      expect(
        signature,
        base64Encode(
          Hmac(
            sha1,
            utf8.encode(credentials.secretKey),
          ).convert(utf8.encode(canonical)).bytes,
        ),
      );
      expect(signed.toString(), isNot(contains(credentials.secretKey)));
      expect(params['voice_format'], '1');
      expect(params['engine_model_type'], '16k_zh_en');
      expect(params['expired'], '1700000600');
      expect(await audio.exists(), isTrue);
    },
  );
  for (final item in {
    4002: 'authentication',
    4003: 'not_activated',
    4004: 'quota',
    4005: 'quota',
    4006: 'throttled',
    4007: 'format',
    4008: 'timeout',
  }.entries) {
    test(
      'handshake ${item.key} returns ${item.value}, sends no audio',
      () async {
        connected = (socket, id) => event(socket, id, {
          'code': item.key,
          'message': credentials.secretKey,
        });
        await expectLater(
          service.transcribe(audio.path, config),
          code(item.value),
        );
        expect(received, isEmpty);
        expect(await audio.exists(), isTrue);
      },
    );
  }
  test('cancel during handshake closes the connection without audio', () async {
    final arrived = Completer<void>();
    connected = (_, _) => arrived.complete();
    final work = service.transcribe(audio.path, config);
    final result = expectLater(work, code('cancelled'));
    await arrived.future;
    service.cancel();
    await result;
    expect(received, isEmpty);
  });
  test('cancel during PCM pacing stops upload and keeps file', () async {
    final paused = Completer<void>(), release = Completer<void>();
    final client = TencentRealtimeRecognizer(
      connect: (uri) {
        signed = uri;
        return WebSocket.connect('ws://127.0.0.1:${server.port}');
      },
      delay: (_) {
        paused.complete();
        return release.future;
      },
    );
    final token = CancelToken();
    final result = expectLater(
      client.recognize(audio.path, credentials, token),
      code('cancelled'),
    );
    await paused.future;
    token.cancel();
    await result;
    release.complete();
    expect(received.length, lessThan(12800));
    expect(await audio.exists(), isTrue);
  });
  test('interim alone is never accepted as final transcript', () async {
    end = (socket, id) {
      event(socket, id, {
        'result': {'slice_type': 1, 'index': 0, 'voice_text_str': 'partial'},
      });
      event(socket, id, {'final': 1});
    };
    await expectLater(service.transcribe(audio.path, config), code('empty'));
  });
  test(
    'segments are ordered and repeated stable messages do not duplicate',
    () async {
      end = (socket, id) {
        for (final segment in [(1, 'English.'), (0, '中文。'), (0, '中文。')]) {
          event(socket, id, {
            'result': {
              'slice_type': 2,
              'index': segment.$1,
              'voice_text_str': segment.$2,
            },
          });
        }
        event(socket, id, {'final': 1});
      };
      expect(await service.transcribe(audio.path, config), '中文。English.');
    },
  );
  test(
    'early final, wrong identity and oversized results fail safely',
    () async {
      for (final message in [
        {'final': 1},
        {'voice_id': 'other'},
        {
          'result': {
            'slice_type': 2,
            'index': 0,
            'voice_text_str': 'a' * 32001,
          },
        },
      ]) {
        connected = (socket, id) => event(socket, id, message);
        await expectLater(
          service.transcribe(audio.path, config),
          code('invalid_response'),
        );
      }
    },
  );
  test('dropped connection never returns partial success', () async {
    end = (socket, id) => unawaited(socket.close());
    await expectLater(service.transcribe(audio.path, config), code('network'));
  });
  test('new attempts get fresh voice ids', () async {
    await service.transcribe(audio.path, config);
    final first = signed.queryParameters['voice_id'];
    await service.transcribe(audio.path, config);
    expect(signed.queryParameters['voice_id'], isNot(first));
  });
  test(
    'wrong audio specification and truncated RIFF fail before connecting',
    () async {
      for (final bytes in [
        pcmWave(sampleRate: 44100),
        pcmWave(channels: 2),
        pcmWave().sublist(0, 100),
        Uint8List(100),
      ]) {
        await audio.writeAsBytes(bytes);
        await expectLater(
          service.transcribe(audio.path, config),
          code('format'),
        );
        expect(sockets, isEmpty);
      }
    },
  );
  test(
    'PCM duration is exact, malformed format and duplicate data are rejected',
    () async {
      expect(
        (await PcmWaveInfo.read(audio.path))?.duration,
        const Duration(milliseconds: 400),
      );
      final bytes = pcmWave();
      ByteData.sublistView(bytes).setUint16(34, 24, Endian.little);
      await audio.writeAsBytes(bytes);
      expect(await PcmWaveInfo.read(audio.path), isNull);
    },
  );
  test('oversized and overlong audio rejected before connection', () async {
    await audio.writeAsBytes(pcmWave(samples: 16000 * 301));
    await expectLater(service.transcribe(audio.path, config), code('too_long'));
    final handle = await audio.open(mode: FileMode.write);
    await handle.truncate(10 * 1024 * 1024 + 1);
    await handle.close();
    await expectLater(
      service.transcribe(audio.path, config),
      code('too_large'),
    );
    expect(sockets, isEmpty);
  });
  test(
    'native profiles retain 16k mono and let the Windows WAV sink finalize its header',
    () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.linux,
      ]) {
        final profile = tencentRecordingProfile(platform);
        expect(profile.sampleRate, 16000);
        expect(profile.numChannels, 1);
        expect(
          profile.encoder,
          platform == TargetPlatform.windows
              ? AudioEncoder.pcm16bits
              : AudioEncoder.wav,
        );
      }
    },
  );
  test('WAV duration guards include short recordings', () async {
    await audio.writeAsBytes(pcmWave(samples: 3200));
    expect(
      await const RecordingDurationReader().read(audio.path),
      const Duration(milliseconds: 200),
    );
  });
  test(
    'standard extensible PCM is admitted but incomplete or non-PCM subtypes are rejected',
    () async {
      final simple = pcmWave();
      final bytes = Uint8List(simple.length + 24);
      bytes.setRange(0, 36, simple);
      final fields = ByteData.sublistView(bytes);
      fields.setUint32(4, bytes.length - 8, Endian.little);
      fields.setUint32(16, 40, Endian.little);
      fields.setUint16(20, 0xfffe, Endian.little);
      fields.setUint16(36, 22, Endian.little);
      fields.setUint16(38, 16, Endian.little);
      bytes.setRange(44, 60, [
        1,
        0,
        0,
        0,
        0,
        0,
        16,
        0,
        128,
        0,
        0,
        170,
        0,
        56,
        155,
        113,
      ]);
      bytes.setRange(60, bytes.length, simple.sublist(36));
      await audio.writeAsBytes(bytes);
      expect((await PcmWaveInfo.read(audio.path))?.bytes, 12800);
      bytes[44] = 3;
      await audio.writeAsBytes(bytes);
      expect(await PcmWaveInfo.read(audio.path), isNull);
    },
  );
  test(
    'live speech publishes partial text before microphone stream ends',
    () async {
      final input = StreamController<List<int>>();
      addTearDown(() {
        unawaited(input.close());
      });
      final preview = Completer<String>();
      audioReceived = (socket, id) => event(socket, id, {
        'result': {'slice_type': 1, 'index': 0, 'voice_text_str': '正在识别'},
      });
      final session = service.startRealtime(
        (_) => input.stream,
        config,
        onText: (text) {
          if (!preview.isCompleted) preview.complete(text);
        },
      );
      var complete = false;
      unawaited(
        session.result.then((_) {
          complete = true;
        }),
      );
      input.add(List.filled(3200, 1));
      expect(await preview.future.timeout(const Duration(seconds: 5)), '正在识别');
      expect(complete, isFalse);
      await input.close();
      expect(await session.result, '明天 meeting at nine。');
      expect(packetSizes, [1280, 1280, 640]);
      expect(received.length, 3200);
    },
  );
  test(
    'server failure interrupts a live source waiting for its next packet',
    () async {
      final input = StreamController<List<int>>();
      addTearDown(() {
        unawaited(input.close());
      });
      audioReceived = (socket, id) {
        // A service rejects the request once and then closes it; smaller live
        // packets can already be queued when that rejection reaches the client.
        audioReceived = (_, _) {};
        event(socket, id, {'code': 4004});
      };
      final session = service.startRealtime(
        (_) => input.stream,
        config,
        onText: (_) {},
      );
      final assertion = expectLater(
        session.result.timeout(const Duration(seconds: 5)),
        code('quota'),
      );
      input.add(List.filled(3200, 0));
      await assertion;
      expect(await audio.exists(), isTrue);
    },
  );
  test('only official secure WebSocket endpoint is admitted', () {
    expect(config.isConfigured, isTrue);
    expect(
      SpeechSettings.validEndpoint(Uri.parse('wss://other.invalid/asr')),
      isFalse,
    );
    expect(
      SpeechSettings.validEndpoint(
        Uri.parse('${TencentSpeechCredentials.realtimeEndpoint}?secret=x'),
      ),
      isFalse,
    );
  });
}
