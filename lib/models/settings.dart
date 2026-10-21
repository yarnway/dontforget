class AppSettings {
  final String id;
  final String apiKey;
  final String baseUrl;
  final String modelName;
  final String language;

  AppSettings({
    required this.id,
    required this.apiKey,
    required this.baseUrl,
    required this.modelName,
    required this.language,
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
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'api_key': apiKey,
    'base_url': baseUrl,
    'model_name': modelName,
    'language': language,
  };

  AppSettings copyWith({
    String? apiKey,
    String? baseUrl,
    String? modelName,
    String? language,
  }) {
    return AppSettings(
      id: id,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      modelName: modelName ?? this.modelName,
      language: language ?? this.language,
    );
  }
}
