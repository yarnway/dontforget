import 'settings.dart';

/// A user-ordered endpoint. Credentials never belong to shared router state.
class AiProfile {
  const AiProfile({
    required this.id,
    required this.label,
    required this.settings,
    this.enabled = true,
  });
  final String id;
  final String label;
  final AppSettings settings;
  final bool enabled;

  AiProfile copyWith({String? label, AppSettings? settings, bool? enabled}) =>
      AiProfile(
        id: id,
        label: label ?? this.label,
        settings: settings ?? this.settings,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'enabled': enabled,
    'base_url': settings.baseUrl,
    'model_name': settings.modelName,
    'api_key': settings.apiKey,
  };
  factory AiProfile.fromJson(Map<String, dynamic> value) {
    if (value.length != 6 ||
        value['id'] is! String ||
        value['label'] is! String ||
        value['enabled'] is! bool ||
        value['base_url'] is! String ||
        value['model_name'] is! String ||
        value['api_key'] is! String) {
      throw const FormatException('Invalid model configuration');
    }
    if ((value['id'] as String).trim().isEmpty ||
        (value['id'] as String).length > 128 ||
        (value['label'] as String).length > 200 ||
        (value['base_url'] as String).length > 2048 ||
        (value['model_name'] as String).length > 256 ||
        (value['api_key'] as String).length > 8192) {
      throw const FormatException('Invalid model configuration');
    }
    return AiProfile(
      id: value['id'],
      label: value['label'],
      enabled: value['enabled'],
      settings: AppSettings.defaults().copyWith(
        baseUrl: value['base_url'],
        modelName: value['model_name'],
        apiKey: value['api_key'],
      ),
    );
  }

  bool get isConfigured {
    final uri = Uri.tryParse(settings.baseUrl.trim());
    return id.isNotEmpty &&
        label.trim().isNotEmpty &&
        uri != null &&
        const ['https', 'http'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        settings.modelName.trim().isNotEmpty &&
        settings.apiKey.trim().isNotEmpty;
  }
}
