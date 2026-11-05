import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/speech_settings.dart';
import '../models/tencent_speech_credentials.dart';
import 'recording_duration_reader.dart';

final speechRecognitionServiceProvider = Provider<SpeechRecognitionService>((
  ref,
) {
  final service = SpeechRecognitionService();
  ref.onDispose(service.dispose);
  return service;
});

/// Only safe codes cross the service boundary: transport errors may contain credentials.
class SpeechRecognitionException implements Exception {
  const SpeechRecognitionException(this.code);
  final String code;
  @override
  String toString() => 'SpeechRecognitionException($code)';
}

/// Tencent Flash recorded-file ASR, shared by gesture and explicit attachment retry.
/// Upload is streamed, with no base64 expansion or public audio URL.
class SpeechRecognitionService {
  SpeechRecognitionService({
    Dio? dio,
    DateTime Function()? now,
    this.requestTimeout = const Duration(seconds: 90),
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10))),
       _now = now ?? DateTime.now;
  final Dio _dio;
  final DateTime Function() _now;
  final Duration requestTimeout;
  final _requests = <Object, CancelToken>{};
  int _epoch = 0;
  bool _disposed = false;
  static const maxBytes = 10 * 1024 * 1024;
  static const maxResponseBytes = 2 * 1024 * 1024;

  void _active(int epoch, CancelToken token) {
    if (_disposed || epoch != _epoch || token.isCancelled) {
      throw const SpeechRecognitionException('cancelled');
    }
  }

  Future<String> transcribe(
    String path,
    SpeechSettings settings, {
    CancelToken? cancelToken,
  }) async {
    final epoch = _epoch;
    final token = cancelToken ?? CancelToken();
    _active(epoch, token);
    final credentials = TencentSpeechCredentials.decode(settings.apiKey);
    if (!settings.enabled ||
        credentials == null ||
        settings.endpoint != TencentSpeechCredentials.endpoint ||
        settings.model != TencentSpeechCredentials.engine) {
      throw const SpeechRecognitionException('not_configured');
    }
    final id = Object();
    _requests[id] = token;
    try {
      return await _recognize(path, credentials, epoch, token).timeout(
        requestTimeout,
        onTimeout: () {
          token.cancel();
          throw const SpeechRecognitionException('timeout');
        },
      );
    } on SpeechRecognitionException {
      rethrow;
    } on DioException catch (error) {
      if (error.error is SpeechRecognitionException) throw error.error!;
      if (_disposed || epoch != _epoch || CancelToken.isCancel(error)) {
        throw const SpeechRecognitionException('cancelled');
      }
      throw SpeechRecognitionException(switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => 'timeout',
        _ => 'network',
      });
    } on FileSystemException {
      throw const SpeechRecognitionException('file');
    } catch (_) {
      throw const SpeechRecognitionException('invalid_response');
    } finally {
      _requests.remove(id);
    }
  }

  Future<String> _recognize(
    String path,
    TencentSpeechCredentials credentials,
    int epoch,
    CancelToken token,
  ) async {
    final ext = path.split('.').last.toLowerCase();
    if (!const {'wav', 'mp3', 'm4a', 'aac', 'amr'}.contains(ext)) {
      throw const SpeechRecognitionException('format');
    }
    final file = File(path);
    final stat = await file.stat();
    _active(epoch, token);
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        stat.size > maxBytes) {
      throw const SpeechRecognitionException('too_large');
    }
    final duration = await const RecordingDurationReader().read(path);
    _active(epoch, token);
    if (duration != null && duration > const Duration(minutes: 5)) {
      throw const SpeechRecognitionException('too_long');
    }
    final params = <String, String>{
      'engine_type': TencentSpeechCredentials.engine,
      'first_channel_only': '1',
      'secretid': credentials.secretId,
      'timestamp': '${_now().toUtc().millisecondsSinceEpoch ~/ 1000}',
      'voice_format': ext,
      'word_info': '0',
    };
    final keys = params.keys.toList()..sort();
    final query = keys.map((key) => '$key=${params[key]}').join('&');
    // Every admitted parameter is ASCII alphanumeric/underscore. Canonical query
    // bytes and actual URI bytes therefore match without ambiguous escaping.
    final hostPath = 'asr.cloud.tencent.com/asr/flash/v1/${credentials.appId}';
    final signature = base64Encode(
      Hmac(
        sha1,
        utf8.encode(credentials.secretKey),
      ).convert(utf8.encode('POST$hostPath?$query')).bytes,
    );
    Stream<List<int>> upload() async* {
      var sent = 0;
      await for (final chunk in file.openRead(0, stat.size + 1)) {
        _active(epoch, token);
        sent += chunk.length;
        if (sent > stat.size) {
          throw const SpeechRecognitionException('audio_changed');
        }
        yield chunk;
      }
      if (sent != stat.size) {
        throw const SpeechRecognitionException('audio_changed');
      }
      final current = await file.stat();
      _active(epoch, token);
      if (current.size != stat.size || current.modified != stat.modified) {
        throw const SpeechRecognitionException('audio_changed');
      }
    }

    final response = await _dio.post<ResponseBody>(
      'https://$hostPath?$query',
      data: upload(),
      cancelToken: token,
      options: Options(
        headers: {
          'Authorization': signature,
          'Content-Type': 'application/octet-stream',
          'Content-Length': '${stat.size}',
        },
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 45),
        validateStatus: (_) => true,
      ),
    );
    _active(epoch, token);
    final body = response.data;
    if (body == null) {
      throw const SpeechRecognitionException('invalid_response');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      _active(epoch, token);
      if (bytes.length + chunk.length > maxResponseBytes) {
        token.cancel();
        throw const SpeechRecognitionException('invalid_response');
      }
      bytes.add(chunk);
    }
    _active(epoch, token);
    if (response.statusCode != 200) {
      throw SpeechRecognitionException(switch (response.statusCode) {
        401 || 403 => 'authentication',
        429 => 'throttled',
        _ => 'network',
      });
    }
    final data = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (data is! Map || data['code'] is! int) {
      throw const SpeechRecognitionException('invalid_response');
    }
    if (data['code'] != 0) {
      throw SpeechRecognitionException(switch (data['code']) {
        4002 => 'authentication',
        4003 => 'not_activated',
        4004 || 4005 => 'quota',
        4006 => 'throttled',
        4007 => 'format',
        4011 => 'too_large',
        4012 => 'empty',
        5003 => 'timeout',
        _ => 'service',
      });
    }
    final results = data['flash_result'];
    if (results is! List ||
        results.length != 1 ||
        results.single is! Map ||
        results.single['channel_id'] != 0 ||
        results.single['text'] is! String) {
      throw const SpeechRecognitionException('invalid_response');
    }
    final text = (results.single['text'] as String).trim();
    if (text.isEmpty) throw const SpeechRecognitionException('empty');
    if (text.length > 32000) {
      throw const SpeechRecognitionException('invalid_response');
    }
    return text;
  }

  void cancel() {
    _epoch++;
    for (final token in _requests.values.toList()) {
      token.cancel();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    _dio.close(force: true);
  }
}
