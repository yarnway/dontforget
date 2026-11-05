import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final localSpeechServiceProvider = Provider<LocalSpeechService>((ref) {
  final service = LocalSpeechService();
  ref.onDispose(service.cancel);
  return service;
});

/// Recorded-file native recognition. Live Android input uses LiveDictationService.
/// Unsupported Android languages remain explicit failures.
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

  Future<String> transcribe(String path, String language) async {
    if (!supported) throw UnsupportedError('Native speech is unavailable');
    final epoch = _epoch;
    final text = await _channel
        .invokeMethod<String>('transcribe', {
          'path': path,
          'locale': switch (language) {
            'zh' => 'zh-CN',
            'ja' => 'ja-JP',
            _ => 'en-US',
          },
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
