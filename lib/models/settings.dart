import 'dart:convert';
import 'ai_profile.dart';

enum AppAppearance { system, light, dark }

enum InputSendMode { enter, button }

class AppSettings {
  final String id;
  final String apiKey;
  final String baseUrl;
  final String modelName;
  final String language;
  final AppAppearance appearance;
  final InputSendMode inputSendMode;
  final String? workspaceDraftsJson;
  final List<AiProfile>? _profiles;
  final bool aiFallbackEnabled;
  List<AiProfile> get aiProfiles => _profiles ?? const [];
  List<AiProfile> get effectiveProfiles =>
      _profiles ??
      List.unmodifiable([
        AiProfile(
          id: 'primary',
          label: 'Primary',
          settings: this,
          enabled: apiKey.trim().isNotEmpty,
        ),
      ]);

  /// Ancillary operations intentionally use only the first enabled profile.
  /// Never fall back to a legacy credential when the explicit list is disabled.
  AppSettings get primaryModelSettings {
    final enabled = effectiveProfiles.where((p) => p.enabled);
    final chosen = enabled.isEmpty ? null : enabled.first.settings;
    return AppSettings(
      id: id,
      apiKey: chosen?.apiKey ?? '',
      baseUrl: chosen?.baseUrl ?? baseUrl,
      modelName: chosen?.modelName ?? modelName,
      language: language,
      appearance: appearance,
      inputSendMode: inputSendMode,
    );
  }

  bool get hasConfiguredExtraction {
    final enabled = effectiveProfiles.where((p) => p.enabled);
    return (aiFallbackEnabled ? enabled : enabled.take(1)).any(
      (p) => p.isConfigured,
    );
  }

  static List<AiProfile>? _readProfiles(Object? raw) {
    if (raw == null) return null; // Only historical schemas omit the list.
    if (raw is! String || raw.length > 131072) {
      throw const FormatException('Invalid model list');
    }
    final values = jsonDecode(raw);
    if (values is! List || values.length > 16 || values.any((v) => v is! Map)) {
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
    this.appearance = AppAppearance.system,
    this.inputSendMode = InputSendMode.enter,
    this.workspaceDraftsJson,
    List<AiProfile>? aiProfiles,
    this.aiFallbackEnabled = false,
  }) : _profiles = aiProfiles == null ? null : List.unmodifiable(aiProfiles);

  /// API identifiers differ from product/version display names. Only normalize
  /// known aliases on DeepSeek's official endpoint; custom gateways and
  /// unknown models must keep the user's choice. Do not rewrite saved data.
  String get requestModelName {
    final uri = Uri.tryParse(baseUrl.trim());
    final model = modelName.trim();
    if (uri?.scheme == 'https' &&
        uri?.host == 'api.deepseek.com' &&
        uri?.port == 443 &&
        uri?.userInfo == '' &&
        uri?.hasQuery == false &&
        uri?.hasFragment == false &&
        const ['', '/', '/v1', '/v1/'].contains(uri?.path)) {
      return const {
            'deepseek-flash': 'deepseek-flash',
            'deepseek-v4.1-flash': 'deepseek-flash',
            'deepseek-v4.1-flash-1017': 'deepseek-flash',
            'deepseek-v4-flash': 'deepseek-flash',
            'deepseek-v4-flash-vision-exp': 'deepseek-flash',
            'deepseek-v4-pro': 'deepseek-v4-pro',
            'deepseek-v4-pro-0813': 'deepseek-v4-pro',
          }[model.toLowerCase()] ??
          model;
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

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final appearance = json['appearance'] ?? 'system';
    if (!AppAppearance.values.any((value) => value.name == appearance)) {
      throw const FormatException('Invalid appearance preference');
    }
    final sendMode = json['input_send_mode'] ?? 'enter';
    if (!InputSendMode.values.any((value) => value.name == sendMode)) {
      throw const FormatException('Invalid input send preference');
    }
    if (json.containsKey('ai_fallback_enabled') &&
        !const [0, 1].contains(json['ai_fallback_enabled'])) {
      throw const FormatException('Invalid fallback preference');
    }
    return AppSettings(
      id: json['id'] as String,
      apiKey: json['api_key'] as String? ?? '',
      baseUrl: json['base_url'] as String? ?? '',
      modelName: json['model_name'] as String? ?? '',
      language: json['language'] as String? ?? 'zh',
      appearance: AppAppearance.values.byName(appearance as String),
      inputSendMode: InputSendMode.values.byName(sendMode as String),
      aiProfiles: _readProfiles(json['ai_profiles_json']),
      aiFallbackEnabled: json['ai_fallback_enabled'] == 1,
      workspaceDraftsJson: json['workspace_drafts_json'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'api_key': apiKey,
    'base_url': baseUrl,
    'model_name': modelName,
    'language': language,
    'appearance': appearance.name,
    'input_send_mode': inputSendMode.name,
    'workspace_drafts_json': workspaceDraftsJson,
    'ai_profiles_json': jsonEncode(
      effectiveProfiles.map((p) => p.toJson()).toList(),
    ),
    'ai_fallback_enabled': aiFallbackEnabled ? 1 : 0,
  };

  AppSettings copyWith({
    String? apiKey,
    String? baseUrl,
    String? modelName,
    String? language,
    AppAppearance? appearance,
    InputSendMode? inputSendMode,
    List<AiProfile>? aiProfiles,
    bool? aiFallbackEnabled,
  }) {
    var profiles = aiProfiles ?? _profiles;
    if (aiProfiles == null &&
        profiles != null &&
        (apiKey != null || baseUrl != null || modelName != null)) {
      var first = profiles.indexWhere((p) => p.enabled);
      if (first < 0 &&
          profiles.isNotEmpty &&
          (apiKey?.trim().isNotEmpty ?? false)) {
        first = 0;
      }
      if (first >= 0) {
        profiles = profiles.toList();
        profiles[first] = profiles[first].copyWith(
          enabled: apiKey == null
              ? profiles[first].enabled
              : apiKey.trim().isNotEmpty,
          settings: profiles[first].settings.copyWith(
            apiKey: apiKey,
            baseUrl: baseUrl,
            modelName: modelName,
          ),
        );
      }
    }
    return AppSettings(
      id: id,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      modelName: modelName ?? this.modelName,
      language: language ?? this.language,
      appearance: appearance ?? this.appearance,
      inputSendMode: inputSendMode ?? this.inputSendMode,
      workspaceDraftsJson: workspaceDraftsJson,
      aiProfiles: profiles,
      aiFallbackEnabled: aiFallbackEnabled ?? this.aiFallbackEnabled,
    );
  }
}
