import 'dart:convert';

/// This entire envelope lives in the existing encrypted speech credential slot.
/// Never serialize it into ordinary settings, backups, errors or logs.
class TencentSpeechCredentials {
  const TencentSpeechCredentials({
    required this.appId,
    required this.secretId,
    required this.secretKey,
  });
  static const endpoint = 'https://asr.cloud.tencent.com/asr/flash/v1';
  static const realtimeEndpoint = 'wss://asr.cloud.tencent.com/asr/v2';
  static const engine = '16k_zh_en';
  final String appId, secretId, secretKey;
  bool get valid =>
      RegExp(r'^[1-9][0-9]{4,15}$').hasMatch(appId) &&
      RegExp(r'^[A-Za-z0-9]{8,128}$').hasMatch(secretId) &&
      secretKey.isNotEmpty &&
      secretKey.length <= 2048 &&
      !secretKey.contains(RegExp(r'[\x00-\x20\x7f]'));
  String encode() => jsonEncode({
    'provider': 'tencent',
    'version': 1,
    'app_id': appId,
    'secret_id': secretId,
    'secret_key': secretKey,
  });
  static TencentSpeechCredentials? decode(String value) {
    try {
      if (value.length > 8192) return null;
      final json = jsonDecode(value);
      if (json is! Map ||
          json.length != 5 ||
          json['provider'] != 'tencent' ||
          json['version'] != 1 ||
          json['app_id'] is! String ||
          json['secret_id'] is! String ||
          json['secret_key'] is! String) {
        return null;
      }
      final result = TencentSpeechCredentials(
        appId: json['app_id'],
        secretId: json['secret_id'],
        secretKey: json['secret_key'],
      );
      return result.valid ? result : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'TencentSpeechCredentials(redacted)';
}
