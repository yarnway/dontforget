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

  bool get isConfigured {
    final uri = Uri.tryParse(settings.baseUrl);
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
