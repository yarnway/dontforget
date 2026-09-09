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
