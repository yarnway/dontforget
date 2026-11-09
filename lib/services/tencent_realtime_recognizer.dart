import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../models/tencent_speech_credentials.dart';
import 'pcm_wave_reader.dart';
import 'speech_recognition_exception.dart';

/// Replays a user-approved recording through Tencent's real-time WebSocket API.
/// Recording alone never opens a connection. PCM is paced at 1:1 after the gesture.
class TencentRealtimeRecognizer {
  TencentRealtimeRecognizer({
    Future<WebSocket> Function(Uri)? connect,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : _connect = connect ?? _connectSecure,
       _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;
  final Future<WebSocket> Function(Uri) _connect;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  Future<String> recognize(
    String path,
    TencentSpeechCredentials credentials,
    CancelToken cancellation,
  ) async {
    void active() {
      if (cancellation.isCancelled) {
        throw const SpeechRecognitionException('cancelled');
      }
    }

    active();
    final file = File(path);
    final initial = await file.stat();
    if (initial.type != FileSystemEntityType.file) {
      throw const SpeechRecognitionException('file');
    }
    if (initial.size <= 0 || initial.size > 10 * 1024 * 1024) {
      throw const SpeechRecognitionException('too_large');
    }
    final wave = await PcmWaveInfo.read(path);
    active();
    if (wave == null || wave.sampleRate != 16000 || wave.channels != 1) {
      throw const SpeechRecognitionException('format');
    }
    if (wave.duration > const Duration(minutes: 5)) {
      throw const SpeechRecognitionException('too_long');
    }
    Stream<List<int>> audio() async* {
      final input = await file.open();
      try {
        await input.setPosition(wave.offset);
        var remaining = wave.bytes;
        while (remaining > 0) {
          active();
          final chunk = await input.read(min(6400, remaining));
          if (chunk.isEmpty || chunk.length.isOdd) {
            throw const SpeechRecognitionException('audio_changed');
          }
          remaining -= chunk.length;
          yield chunk;
        }
      } finally {
        await input.close();
      }
      final current = await file.stat();
      if (initial.size != current.size ||
          initial.modified != current.modified) {
        throw const SpeechRecognitionException('audio_changed');
      }
    }

    return recognizeStream(audio(), credentials, cancellation);
  }

  Future<String> recognizeStream(
    Stream<List<int>> audio,
    TencentSpeechCredentials credentials,
    CancelToken cancellation, {
    bool live = false,
    void Function(String text)? onText,
  }) async {
    void active() {
      if (cancellation.isCancelled) {
        throw const SpeechRecognitionException('cancelled');
      }
    }

    active();
    final voiceId = const Uuid().v4();
    final stamp = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final params = <String, String>{
      'engine_model_type': TencentSpeechCredentials.engine,
      'expired': '${stamp + 600}',
      'needvad': '1',
      'nonce': '${Random.secure().nextInt(0x7fffffff) + 1}',
      'secretid': credentials.secretId,
      'timestamp': '$stamp',
      'voice_format': '1',
      'voice_id': voiceId,
    };
    final keys = params.keys.toList()..sort();
    final hostPath = 'asr.cloud.tencent.com/asr/v2/${credentials.appId}';
    final canonical =
        '$hostPath?${keys.map((k) => '$k=${params[k]}').join('&')}';
    params['signature'] = base64Encode(
      Hmac(
        sha1,
        utf8.encode(credentials.secretKey),
      ).convert(utf8.encode(canonical)).bytes,
    );
    final uri = Uri(
      scheme: 'wss',
      host: 'asr.cloud.tencent.com',
      path: '/asr/v2/${credentials.appId}',
      queryParameters: params,
    );
    WebSocket? socket;
    StreamSubscription<dynamic>? subscription;
    StreamIterator<List<int>>? inputIterator;
    var abandoned = false;
    final handshake = Completer<void>(), finished = Completer<void>();
    String? failure;
    var totalBytes = 0;
    var endSent = false;
    final stable = <int, String>{};
    final partial = <int, String>{};
    String assembled(Map<int, String> values) {
      final keys = values.keys.toList()..sort();
      return keys.map((key) => values[key]).join().trim();
    }

    void fail(String code) {
      failure ??= code;
      if (!handshake.isCompleted) handshake.complete();
      if (!finished.isCompleted) finished.complete();
    }

    void check() {
      active();
      if (failure != null) throw SpeechRecognitionException(failure!);
    }

    Future<void> wait(Future<void> work, Duration timeout) async {
      await Future.any([
        work,
        cancellation.whenCancel.then((_) {}),
      ]).timeout(timeout, onTimeout: () => fail('timeout'));
      check();
    }

    try {
      // A late connection after cancellation/timeout is immediately closed.
      final connecting = _connect(uri).then((value) {
        if (abandoned || cancellation.isCancelled) {
          unawaited(value.close());
          throw const SpeechRecognitionException('cancelled');
        }
        return value;
      });
      socket = await Future.any([
        connecting,
        cancellation.whenCancel.then<WebSocket>(
          (_) => throw const SpeechRecognitionException('cancelled'),
        ),
      ]).timeout(const Duration(seconds: 10));
      check();
      socket.pingInterval = const Duration(seconds: 5);
      subscription = socket.listen(
        (message) {
          if (failure != null || finished.isCompleted) return;
          try {
            if (message is! String || message.length > 65536) {
              fail('invalid_response');
              return;
            }
            totalBytes += utf8.encode(message).length;
            if (totalBytes > 2 * 1024 * 1024) {
              fail('invalid_response');
              return;
            }
            final data = jsonDecode(message);
            if (data is! Map ||
                data['code'] is! int ||
                data['voice_id'] != voiceId) {
              fail('invalid_response');
              return;
            }
            if (data['code'] != 0) {
              fail(switch (data['code']) {
                4002 => 'authentication',
                4003 => 'not_activated',
                4004 || 4005 => 'quota',
                4006 => 'throttled',
                4007 => 'format',
                4008 => 'timeout',
                _ => 'service',
              });
              return;
            }
            if (!handshake.isCompleted) handshake.complete();
            final result = data['result'];
            if (result != null) {
              if (result is! Map ||
                  result['index'] is! int ||
                  (result['index'] as int) < 0 ||
                  (result['index'] as int) > 2048 ||
                  !const [0, 1, 2].contains(result['slice_type']) ||
                  result['voice_text_str'] is! String ||
                  (result['voice_text_str'] as String).length > 32000) {
                fail('invalid_response');
                return;
              }
              final index = result['index'] as int;
              if (!stable.containsKey(index)) {
                partial[index] = result['voice_text_str'] as String;
              }
              if (result['slice_type'] == 2) {
                partial.remove(index);
                stable[result['index'] as int] =
                    result['voice_text_str'] as String;
                if (stable.values.fold<int>(0, (n, s) => n + s.length) >
                    32000) {
                  fail('invalid_response');
                  return;
                }
              }
            }
            if (result != null && onText != null) {
              final preview = assembled({...partial, ...stable});
              if (preview.length > 32000) {
                fail('invalid_response');
                return;
              }
              onText(preview);
            }
            if (data['final'] == 1) {
              if (!endSent) {
                fail('invalid_response');
                return;
              }
              finished.complete();
            }
          } catch (_) {
            fail('invalid_response');
          }
        },
        onError: (Object _) => fail('network'),
        onDone: () {
          if (!finished.isCompleted) fail('network');
        },
      );
      await wait(handshake.future, const Duration(seconds: 10));
      final clock = Stopwatch()..start();
      var scheduledMicros = 0, sent = 0;
      inputIterator = StreamIterator(audio);
      while (await Future.any([
        inputIterator.moveNext(),
        finished.future.then((_) {
          check();
          return false;
        }),
        cancellation.whenCancel.then((_) {
          check();
          return false;
        }),
      ])) {
        final input = inputIterator.current;
        for (var offset = 0; offset < input.length; offset += 6400) {
          check();
          final chunk = input.sublist(offset, min(offset + 6400, input.length));
          if (chunk.length.isOdd) {
            throw const SpeechRecognitionException('format');
          }
          sent += chunk.length;
          if (sent > 32000 * 300) {
            throw const SpeechRecognitionException('too_long');
          }
          if (live) {
            final waitMicros = scheduledMicros - clock.elapsedMicroseconds;
            if (waitMicros > 0) {
              await wait(
                _delay(Duration(microseconds: waitMicros)),
                const Duration(seconds: 5),
              );
            }
          }
          check();
          socket.add(chunk);
          final micros = chunk.length * Duration.microsecondsPerSecond ~/ 32000;
          scheduledMicros += micros;
          if (!live) {
            await wait(
              _delay(Duration(microseconds: micros)),
              const Duration(seconds: 5),
            );
          }
        }
      }
      if (live && scheduledMicros > clock.elapsedMicroseconds) {
        await wait(
          _delay(
            Duration(microseconds: scheduledMicros - clock.elapsedMicroseconds),
          ),
          const Duration(seconds: 5),
        );
      }
      check();
      endSent = true;
      socket.add('{"type":"end"}');
      await wait(finished.future, const Duration(seconds: 20));
      final indexes = stable.keys.toList()..sort();
      final text = indexes.map((index) => stable[index]).join().trim();
      if (text.isEmpty) throw const SpeechRecognitionException('empty');
      return text;
    } on SpeechRecognitionException {
      rethrow;
    } on TimeoutException {
      throw const SpeechRecognitionException('timeout');
    } on FileSystemException {
      throw const SpeechRecognitionException('file');
    } catch (_) {
      throw const SpeechRecognitionException('network');
    } finally {
      abandoned = true;
      if (inputIterator != null) unawaited(inputIterator.cancel());
      await subscription?.cancel();
      if (socket != null) unawaited(socket.close());
    }
  }
}

// WebSocket.connect otherwise follows HTTP redirects with its signed query.
// Only openUrl is used by the SDK handshake; unsupported client operations fail.
class _HandshakeClient implements HttpClient {
  _HandshakeClient(this.inner);
  final HttpClient inner;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await inner.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<WebSocket> _connectSecure(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await WebSocket.connect(
      uri.toString(),
      customClient: _HandshakeClient(client),
      compression: CompressionOptions.compressionOff,
    ).timeout(const Duration(seconds: 10));
  } finally {
    // Upgraded sockets have detached from the HTTP client.
    client.close(force: true);
  }
}
