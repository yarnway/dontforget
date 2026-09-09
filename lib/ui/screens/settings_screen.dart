import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';

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
    
    // Try to match current settings to a provider
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.get('settings')),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              decoration: InputDecoration(
                labelText: l10n.get('language'),
                border: const OutlineInputBorder(),
              ),
              initialValue: _selectedLang,
              items: const [
                DropdownMenuItem(value: 'en', child: Text('English')),
                DropdownMenuItem(value: 'zh', child: Text('中文')),
                DropdownMenuItem(value: 'ja', child: Text('日本語')),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _selectedLang = val);
              },
            ),
            const SizedBox(height: 24),
            
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('大模型服务接入配置', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.bolt_rounded, size: 16, color: Colors.blue),
                        label: const Text('一键选用 DeepSeek'),
                        onPressed: () => _onProviderChanged(_providers[0]),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.auto_awesome, size: 16, color: Colors.deepPurple),
                        label: const Text('一键选用 Gemini'),
                        onPressed: () => _onProviderChanged(_providers[1]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<ModelProvider>(
                    decoration: const InputDecoration(
                      labelText: '快捷预设服务商',
                      border: OutlineInputBorder(),
                    ),
                    initialValue: _selectedProvider,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('自定义 (Custom)')),
                      ..._providers.map((p) => DropdownMenuItem(value: p, child: Text(p.name))),
                    ],
                    onChanged: _onProviderChanged,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _apiKeyController,
                    decoration: InputDecoration(
                      labelText: l10n.get('apiKey'),
                      border: const OutlineInputBorder(),
                      helperText: '输入或粘贴模型服务商的 API Key',
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _baseUrlController,
                    decoration: InputDecoration(
                      labelText: l10n.get('baseUrl'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _modelNameController,
                    decoration: const InputDecoration(
                      labelText: '模型标识 (Model Name)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 32),
            FilledButton(
              onPressed: _saveSettings,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12.0),
                child: Text(l10n.get('save')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
