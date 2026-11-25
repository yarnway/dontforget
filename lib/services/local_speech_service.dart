import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'speech_recognition_service.dart';

final localSpeechServiceProvider = Provider<LocalSpeechService>((ref) {
  final service = LocalSpeechService();
  ref.onDispose(service.cancel);
  return service;
});

/// On-device speech recognition supporting both finalized audio files and
/// real-time PCM streaming when the user swipes up-right while holding.
/// Unsupported device languages stay explicit failures (never silent cloud).
class LocalSpeechService {
  LocalSpeechService({bool? isIOS, bool? isAndroid, MethodChannel? channel})
    : android = isAndroid ?? (isIOS == null && Platform.isAndroid),
      supported =
          (isIOS ?? Platform.isIOS) ||
          (isAndroid ?? (isIOS == null && Platform.isAndroid)),
      _channel = channel ?? const MethodChannel('dontforget/local_speech');

  final bool supported;
  final bool android;
  final MethodChannel _channel;
  int _epoch = 0;
  int _nextSessionId = 0;
  bool _handlerAttached = false;
  final Map<int, _LiveLocalSessionState> _sessions = {};

  static String _localeFor(String language) => switch (language) {
    'zh' => 'zh-CN',
    'ja' => 'ja-JP',
    _ => 'en-US',
  };

  void _ensureHandler() {
    if (_handlerAttached) return;
    _handlerAttached = true;
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (args is! Map) return null;
      final id = args['sessionId'];
      if (id is! int) return null;
      final session = _sessions[id];
      if (session == null) return null;
      switch (call.method) {
        case 'onLiveText':
          final text = args['text'];
          if (text is String && text.trim().isNotEmpty) {
            final trimmed = text.trim();
            session.latestText = trimmed;
            session.onText(trimmed);
          }
        case 'onLiveError':
          final code = args['code'] is String
              ? args['code'] as String
              : 'speech_failed';
          session.error = PlatformException(code: code);
      }
      return null;
    });
  }

  /// Streams 16kHz 16-bit mono PCM chunks to the native on-device recognizer,
  /// delivering partial transcripts immediately before finger release.
  LiveSpeechSession startLive(
    Stream<List<int>> Function(CancelToken token) audio,
    String language, {
    required void Function(String text) onText,
  }) {
    if (!supported) throw UnsupportedError('Native speech is unavailable');
    _ensureHandler();
    final epoch = _epoch;
    final sessionId = ++_nextSessionId;
    final token = CancelToken();
    final sessionState = _LiveLocalSessionState(onText);
    _sessions[sessionId] = sessionState;

    void checkActive() {
      if (epoch != _epoch || token.isCancelled) {
        throw PlatformException(code: 'speech_cancelled');
      }
      if (sessionState.error != null) {
        throw sessionState.error!;
      }
    }

    final result = (() async {
      var startedNative = false;
      try {
        checkActive();
        await _channel
            .invokeMethod<void>('startStream', {
              'sessionId': sessionId,
              'locale': _localeFor(language),
            })
            .timeout(const Duration(seconds: 10));
        startedNative = true;
        checkActive();
        await for (final chunk in audio(token)) {
          checkActive();
          if (chunk.isEmpty) continue;
          await _channel.invokeMethod<void>('pushPcm', {
            'sessionId': sessionId,
            'bytes': chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
          });
        }
        checkActive();
        final finalText = await _channel
            .invokeMethod<String>('finishStream', {'sessionId': sessionId})
            .timeout(
              const Duration(seconds: 25),
              onTimeout: () async {
                await _cancelNativeStream(sessionId);
                throw PlatformException(code: 'speech_timeout');
              },
            );
        if (epoch != _epoch || token.isCancelled) {
          throw PlatformException(code: 'speech_cancelled');
        }
        final resolved = (finalText ?? sessionState.latestText ?? '').trim();
        if (resolved.isEmpty || resolved.length > 32000) {
          throw PlatformException(code: 'speech_empty');
        }
        return resolved;
      } catch (error) {
        if (startedNative && (epoch != _epoch || token.isCancelled)) {
          unawaited(_cancelNativeStream(sessionId));
        }
        if (epoch != _epoch || token.isCancelled) {
          throw PlatformException(code: 'speech_cancelled');
        }
        rethrow;
      } finally {
        _sessions.remove(sessionId);
        if (!token.isCancelled) token.cancel();
      }
    })();

    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return LiveSpeechSession(result, () {
      if (!token.isCancelled) {
        token.cancel();
        unawaited(_cancelNativeStream(sessionId));
      }
    });
  }

  Future<void> _cancelNativeStream(int sessionId) async {
    if (!supported) return;
    try {
      await _channel
          .invokeMethod<void>('cancel', {'sessionId': sessionId})
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<String> transcribe(String path, String language) async {
    if (!supported) throw UnsupportedError('Native speech is unavailable');
    final epoch = _epoch;
    final text = await _channel
        .invokeMethod<String>('transcribe', {
          'path': path,
          'locale': _localeFor(language),
        })
        .timeout(
          const Duration(seconds: 50),
          onTimeout: () async {
            await cancel();
            throw PlatformException(code: 'speech_timeout');
          },
        );
    if (epoch != _epoch) throw PlatformException(code: 'speech_cancelled');
    if (text == null || text.trim().isEmpty || text.length > 32000) {
      throw PlatformException(code: 'speech_empty');
    }
    return text.trim();
  }

  Future<void> cancel() async {
    _epoch++;
    for (final id in _sessions.keys.toList()) {
      _sessions.remove(id);
    }
    if (!supported) return;
    try {
      await _channel
          .invokeMethod<void>('cancel')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      /* The native request has its own bounded timeout. */
    }
  }
}

class _LiveLocalSessionState {
  _LiveLocalSessionState(this.onText);
  final void Function(String text) onText;
  String? latestText;
  PlatformException? error;
}
