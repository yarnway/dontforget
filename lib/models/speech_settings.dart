import 'credential_reference.dart';

/// Preserves settings from the already-installed +54 prototype.
/// Realtime dictation uses the Android service, never these cloud credentials.
class SpeechSettings {
  const SpeechSettings({
    this.enabled = false,
    this.endpoint = defaultEndpoint,
    this.model = 'qwen-audio-3.0-asr-flash',
    this.apiKey = '',
  });
  static const defaultEndpoint =
      'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';
  final bool enabled;
  final String endpoint, model, apiKey;

  bool get isConfigured {
    final uri = Uri.tryParse(endpoint.trim());
    return enabled &&
        validEndpoint(uri) &&
        model.trim().isNotEmpty &&
        apiKey.trim().isNotEmpty &&
        !isCredentialReference(apiKey);
  }

  static bool validEndpoint(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;

  SpeechSettings copyWith({
    bool? enabled,
    String? endpoint,
    String? model,
    String? apiKey,
  }) => SpeechSettings(
    enabled: enabled ?? this.enabled,
    endpoint: endpoint ?? this.endpoint,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'enabled': enabled,
    'endpoint': endpoint,
    'model': model,
    'api_key': apiKey,
  };
  factory SpeechSettings.fromJson(Map<String, dynamic> value) {
    if (value.isEmpty) return const SpeechSettings();
    if (value.length != 5 ||
        value['version'] != 1 ||
        value['enabled'] is! bool ||
        value['endpoint'] is! String ||
        value['model'] is! String ||
        value['api_key'] is! String ||
        (value['endpoint'] as String).length > 2048 ||
        (value['model'] as String).length > 256 ||
        (value['api_key'] as String).length > 8192) {
      throw const FormatException('Invalid speech configuration');
    }
    return SpeechSettings(
      enabled: value['enabled'],
      endpoint: value['endpoint'],
      model: value['model'],
      apiKey: value['api_key'],
    );
  }
}
