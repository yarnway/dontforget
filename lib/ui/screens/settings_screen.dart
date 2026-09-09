import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/ai_background_effect.dart';

class ModelProvider {
  final String name;
  final String defaultBaseUrl;
  final String defaultModel;
  final String? defaultApiKey;

  const ModelProvider(
    this.name,
    this.defaultBaseUrl,
    this.defaultModel, [
    this.defaultApiKey,
  ]);
}

String _decodeSecret(String b64) {
  try {
    return utf8.decode(base64.decode(b64));
  } catch (_) {
    return '';
  }
}

final List<ModelProvider> _providers = [
  ModelProvider(
    'DeepSeek (推荐默认)',
    'https://api.deepseek.com',
    'deepseek-v4-flash-vision-exp',
    _decodeSecret('c2stZDdmZmNiNTAzMGMzNDI5OGExZTQ3NDEzN2JmODNmYjk='),
  ),
  ModelProvider(
    'Gemini (Google 官方)',
    'https://generativelanguage.googleapis.com/v1beta/openai',
    'gemini-3.6-flash',
    _decodeSecret('QVEuQWI4Uk42SUVydFNsUVZ6TzlGRmRFdXpjcnBraUppdjZMUF80VTFrTnFXekswWkl4ckE='),
  ),
  const ModelProvider(
    'Ollama (本地离线大模型)',
    'http://localhost:11434/v1',
    'llama3',
    'ollama',
  ),
  const ModelProvider('OpenAI (ChatGPT)', 'https://api.openai.com/v1', 'gpt-4o-mini'),
  const ModelProvider('Kimi (Moonshot)', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k'),
  const ModelProvider('Qwen (DashScope)', 'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus'),
  const ModelProvider('Grok (xAI)', 'https://api.x.ai/v1', 'grok-beta'),
  const ModelProvider('Doubao (Volcengine)', 'https://ark.volces.com/api/v3', 'ep-xxx'),
];

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _apiKeyController;
  late TextEditingController _baseUrlController;
  late TextEditingController _modelNameController;
  String _selectedLang = 'zh';
  ModelProvider? _selectedProvider;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _apiKeyController = TextEditingController(text: settings.apiKey);
    _baseUrlController = TextEditingController(text: settings.baseUrl);
    _modelNameController = TextEditingController(text: settings.modelName);
    _selectedLang = settings.language;
    
    for (var p in _providers) {
      if (p.defaultBaseUrl == settings.baseUrl && p.defaultModel == settings.modelName) {
        _selectedProvider = p;
        break;
      }
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelNameController.dispose();
    super.dispose();
  }

  void _onProviderChanged(ModelProvider? provider) {
    if (provider == null) return;
    setState(() {
      _selectedProvider = provider;
      _baseUrlController.text = provider.defaultBaseUrl;
      _modelNameController.text = provider.defaultModel;
      if (provider.defaultApiKey != null && provider.defaultApiKey!.isNotEmpty) {
        _apiKeyController.text = provider.defaultApiKey!;
      }
    });
  }

  void _saveSettings() {
    final settings = ref.read(settingsProvider);
    final newSettings = settings.copyWith(
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      modelName: _modelNameController.text.trim(),
      language: _selectedLang,
    );
    ref.read(settingsProvider.notifier).updateSettings(newSettings);
    Navigator.pop(context);
  }

  void _openConsoleUrl(String url) {
    if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', url]);
    }
  }

  Widget _buildConsoleLinkChip(String label, String url) {
    return InkWell(
      onTap: () => _openConsoleUrl(url),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.launch_rounded, size: 11, color: Theme.of(context).colorScheme.primary),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.get('settings'),
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: AiBackgroundEffect(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top: Privacy Shield Card (Wireframe Security)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0D251A) : const Color(0xFFEAF8F0),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.45 : 0.6),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.security_rounded,
                          color: Color(0xFF10B981),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.get('privacyShieldTitle'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: Color(0xFF10B981),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.get('privacyShieldDesc'),
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.4,
                                color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Language selection card (Wireframe)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.black26 : Colors.white.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.language_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            l10n.get('language'),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        initialValue: _selectedLang,
                        items: const [
                          DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                          DropdownMenuItem(value: 'en', child: Text('English')),
                          DropdownMenuItem(value: 'ja', child: Text('日本語')),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => _selectedLang = val);
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),
                
                // AI Configuration (Wireframe style)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.black26 : Colors.white.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.memory_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            l10n.get('llmConfigTitle'),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ActionChip(
                            avatar: const Icon(Icons.bolt_rounded, size: 15, color: Colors.blue),
                            label: Text(l10n.get('quickDeepSeek'), style: const TextStyle(fontSize: 12)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                              side: BorderSide(color: Colors.blue.withValues(alpha: 0.4), width: 1),
                            ),
                            onPressed: () => _onProviderChanged(_providers[0]),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.auto_awesome, size: 15, color: Colors.deepPurple),
                            label: Text(l10n.get('quickGemini'), style: const TextStyle(fontSize: 12)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                              side: BorderSide(color: Colors.deepPurple.withValues(alpha: 0.4), width: 1),
                            ),
                            onPressed: () => _onProviderChanged(_providers[1]),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.download_for_offline_rounded, size: 15, color: Colors.teal),
                            label: Text(l10n.get('ollamaLocal'), style: const TextStyle(fontSize: 12)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                              side: BorderSide(color: Colors.teal.withValues(alpha: 0.4), width: 1),
                            ),
                            onPressed: () => _onProviderChanged(_providers[2]),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<ModelProvider>(
                        decoration: InputDecoration(
                          labelText: l10n.get('presetProvider'),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        initialValue: _selectedProvider,
                        items: [
                          DropdownMenuItem(value: null, child: Text(l10n.get('customProvider'))),
                          ..._providers.map((p) => DropdownMenuItem(value: p, child: Text(p.name))),
                        ],
                        onChanged: _onProviderChanged,
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _apiKeyController,
                        decoration: InputDecoration(
                          labelText: l10n.get('apiKey'),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          helperText: l10n.get('apiKeyHelper'),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: 8),
                      // Platform Official Console Direct Links
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.open_in_new_rounded, size: 13, color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 4),
                                Text(
                                  l10n.get('openOfficialSite'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                _buildConsoleLinkChip('DeepSeek', 'https://platform.deepseek.com/api_keys'),
                                _buildConsoleLinkChip('Google AI Studio', 'https://aistudio.google.com/app/apikey'),
                                _buildConsoleLinkChip('OpenAI', 'https://platform.openai.com/api-keys'),
                                _buildConsoleLinkChip('Moonshot (Kimi)', 'https://platform.moonshot.cn/console/api-keys'),
                                _buildConsoleLinkChip('阿里百炼 (Qwen)', 'https://bailian.console.aliyun.com/'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _baseUrlController,
                        decoration: InputDecoration(
                          labelText: l10n.get('baseUrl'),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _modelNameController,
                        decoration: InputDecoration(
                          labelText: l10n.get('modelNameLabel'),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 24),
                FilledButton(
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _saveSettings,
                  child: Text(
                    l10n.get('save'),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
