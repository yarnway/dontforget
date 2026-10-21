import 'dart:convert';
import 'ai_profile.dart';

class AppSettings {
  final String id;
  final String apiKey;
  final String baseUrl;
  final String modelName;
  final String language;
  final List<AiProfile> aiProfiles;
  final bool aiFallbackEnabled;
  List<AiProfile> get effectiveProfiles => aiProfiles.isNotEmpty
      ? aiProfiles
      : [AiProfile(id: 'primary', label: 'Primary', settings: this)];
  bool get hasConfiguredExtraction {
    final enabled = effectiveProfiles.where((p) => p.enabled);
    return (aiFallbackEnabled ? enabled : enabled.take(1)).any(
      (p) => p.isConfigured,
    );
  }

  static List<AiProfile> _readProfiles(Object? raw) {
    if (raw == null || raw == '') return const [];
    final values = jsonDecode(raw as String);
    if (values is! List || values.length > 16) {
      throw const FormatException('Invalid model list');
    }
    final profiles = values
        .map((v) => AiProfile.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    if (profiles.map((p) => p.id).toSet().length != profiles.length) {
      throw const FormatException('Duplicate model IDs');
    }
    return List.unmodifiable(profiles);
  }

  AppSettings({
    required this.id,
    required this.apiKey,
    required this.baseUrl,
    required this.modelName,
    required this.language,
    this.aiProfiles = const [],
    this.aiFallbackEnabled = false,
  });

  /// API identifiers differ from product/version display names. Only normalize
  /// known Flash aliases on DeepSeek's official endpoint; custom gateways and
  /// unknown models must keep the user's choice. Do not rewrite saved data.
  String get requestModelName {
    final uri = Uri.tryParse(baseUrl.trim());
    final model = modelName.trim();
    if (uri?.scheme == 'https' &&
        uri?.host == 'api.deepseek.com' &&
        const ['', '/', '/v1', '/v1/'].contains(uri?.path) &&
        const {
          'deepseek-v4.1-flash',
          'deepseek-v4-flash',
          'deepseek-v4-flash-vision-exp',
        }.contains(model)) {
      return 'deepseek-flash';
    }
    return model;
  }

  factory AppSettings.defaults() => AppSettings(
    id: 'default',
    apiKey: '',
    baseUrl: 'https://api.deepseek.com',
    modelName: 'deepseek-flash',
    language: 'zh',
  );

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    id: json['id'] as String,
    apiKey: json['api_key'] as String? ?? '',
    baseUrl: json['base_url'] as String? ?? '',
    modelName: json['model_name'] as String? ?? '',
    language: json['language'] as String? ?? 'zh',
    aiProfiles: _readProfiles(json['ai_profiles_json']),
    aiFallbackEnabled: json['ai_fallback_enabled'] == 1,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'api_key': apiKey,
    'base_url': baseUrl,
    'model_name': modelName,
    'language': language,
    'ai_profiles_json': jsonEncode(aiProfiles.map((p) => p.toJson()).toList()),
    'ai_fallback_enabled': aiFallbackEnabled ? 1 : 0,
  };

  AppSettings copyWith({
    String? apiKey,
    String? baseUrl,
    String? modelName,
    String? language,
    List<AiProfile>? aiProfiles,
    bool? aiFallbackEnabled,
  }) {
    return AppSettings(
      id: id,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      modelName: modelName ?? this.modelName,
      language: language ?? this.language,
      aiProfiles: List.unmodifiable(aiProfiles ?? this.aiProfiles),
      aiFallbackEnabled: aiFallbackEnabled ?? this.aiFallbackEnabled,
    );
  }
}
