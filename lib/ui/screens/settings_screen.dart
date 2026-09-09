import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/providers.dart';
import '../../services/llm_service.dart';
import '../../services/lan_sync_service.dart';
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

  // Edge AI Probe State
  bool _isProbing = false;
  List<LocalInferenceEndpoint>? _probeResults;

  // LAN Sync State
  bool _isLanServerRunning = false;
  String _lanIp = '';
  String _lanPin = '';
  final _targetIpController = TextEditingController();
  final _targetPinController = TextEditingController();
  bool _isSyncing = false;

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

    final lanSync = LanSyncService.instance;
    _isLanServerRunning = lanSync.isRunning;
    _lanIp = lanSync.localIp;
    _lanPin = lanSync.pin;
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelNameController.dispose();
    _targetIpController.dispose();
    _targetPinController.dispose();
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

  Future<void> _probeLocalEngines() async {
    if (_isProbing) return;
    setState(() => _isProbing = true);
    try {
      final llmService = ref.read(llmServiceProvider);
      final results = await llmService.probeLocalInferenceEndpoints();
      setState(() => _probeResults = results);
    } catch (_) {
    } finally {
      setState(() => _isProbing = false);
    }
  }

  void _applyLocalEngine(LocalInferenceEndpoint endpoint) {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _baseUrlController.text = endpoint.url;
      _modelNameController.text = endpoint.recommendedModel ?? 'default-model';
      _apiKeyController.text = 'ollama';
      _selectedProvider = null;
    });

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text('${l10n.get('appliedLocalEngine')} (${endpoint.name})'),
      ),
    );
  }

  Future<void> _toggleLanServer() async {
    final lanSync = LanSyncService.instance;
    final dbHelper = ref.read(databaseHelperProvider);
    if (_isLanServerRunning) {
      await lanSync.stopServer();
      setState(() {
        _isLanServerRunning = false;
        _lanPin = '';
      });
    } else {
      try {
        final info = await lanSync.startServer(
          dbHelper: dbHelper,
          onDataChanged: () {
            ref.read(remindersProvider.notifier).refreshReminders();
          },
        );
        setState(() {
          _isLanServerRunning = true;
          _lanIp = info.ip;
          _lanPin = info.pin;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('启动服务失败: $e')),
          );
        }
      }
    }
  }

  Future<void> _syncWithTarget() async {
    final l10n = AppLocalizations.of(context);
    final ip = _targetIpController.text.trim();
    final pin = _targetPinController.text.trim();
    if (ip.isEmpty || pin.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.get('syncFailed'))),
      );
      return;
    }

    setState(() => _isSyncing = true);
    final lanSync = LanSyncService.instance;
    final dbHelper = ref.read(databaseHelperProvider);

    final success = await lanSync.syncWithPeer(
      peerIp: ip,
      pin: pin,
      dbHelper: dbHelper,
      onDataChanged: () {
        ref.read(remindersProvider.notifier).refreshReminders();
      },
    );

    if (mounted) {
      setState(() => _isSyncing = false);
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          content: Text(success ? l10n.get('syncSuccess') : l10n.get('syncFailed')),
          backgroundColor: success ? Colors.green.shade700 : Colors.redAccent,
        ),
      );
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
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.arrow_outward, size: 10, color: Theme.of(context).colorScheme.primary),
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
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          l10n.get('settings'),
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: AiBackgroundEffect(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Privacy Shield Guarantee
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? Colors.teal.shade900.withValues(alpha: 0.25) : Colors.teal.shade50.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? Colors.tealAccent.withValues(alpha: 0.3) : Colors.teal.shade300,
                    width: 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.security_rounded, color: isDark ? Colors.tealAccent : Colors.teal.shade700, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.get('privacyShieldTitle'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.tealAccent : Colors.teal.shade900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.get('privacyShieldDesc'),
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.grey.shade300 : Colors.teal.shade900.withValues(alpha: 0.8),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Language Setting
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

              const SizedBox(height: 14),

              // Edge AI Inference Probe Card
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
                        Icon(Icons.radar_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.get('localEngineProbe'),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          onPressed: _isProbing ? null : _probeLocalEngines,
                          icon: _isProbing
                              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                              : const Icon(Icons.refresh_rounded, size: 14),
                          label: Text(_isProbing ? l10n.get('probing') : l10n.get('probeNow'), style: const TextStyle(fontSize: 11)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.get('probeDesc'),
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    if (_probeResults != null) ...[
                      const SizedBox(height: 10),
                      for (final ep in _probeResults!)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: ep.isAvailable ? Colors.green.withValues(alpha: 0.4) : Colors.grey.withValues(alpha: 0.2),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  ep.isAvailable ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                                  size: 16,
                                  color: ep.isAvailable ? Colors.green : Colors.grey,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${ep.name} (Port ${ep.port})',
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                      ),
                                      Text(
                                        ep.isAvailable
                                            ? '${ep.recommendedModel} · ${ep.latencyMs}ms'
                                            : '端口未监听',
                                        style: TextStyle(fontSize: 10, color: ep.isAvailable ? Colors.green.shade700 : Colors.grey),
                                      ),
                                    ],
                                  ),
                                ),
                                if (ep.isAvailable)
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                    ),
                                    onPressed: () => _applyLocalEngine(ep),
                                    child: Text(l10n.get('applyToSettings'), style: const TextStyle(fontSize: 10)),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Decentralized LAN Sync Card
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
                        Icon(Icons.wifi_tethering_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.get('lanSyncTitle'),
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                        ),
                        Switch(
                          value: _isLanServerRunning,
                          onChanged: (_) => _toggleLanServer(),
                        ),
                      ],
                    ),
                    Text(
                      l10n.get('lanSyncDesc'),
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    if (_isLanServerRunning) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.blueGrey.shade900.withValues(alpha: 0.3) : Colors.blueGrey.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.blueGrey.withValues(alpha: 0.3), width: 0.8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.router_rounded, size: 14, color: Colors.blueAccent),
                                const SizedBox(width: 6),
                                Text(
                                  '${l10n.get('lanServerRunning')}$_lanIp:42888',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(Icons.vpn_key_rounded, size: 14, color: Colors.amber),
                                const SizedBox(width: 6),
                                Text(
                                  '${l10n.get('syncPin')}$_lanPin',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: Colors.amber),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    const Divider(height: 20),
                    Text(
                      l10n.get('connectToDevice'),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _targetIpController,
                            style: const TextStyle(fontSize: 12),
                            decoration: InputDecoration(
                              labelText: l10n.get('enterTargetIp'),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _targetPinController,
                            style: const TextStyle(fontSize: 12),
                            decoration: InputDecoration(
                              labelText: l10n.get('enterPin'),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        ),
                        onPressed: _isSyncing ? null : _syncWithTarget,
                        icon: _isSyncing
                            ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                            : const Icon(Icons.sync_rounded, size: 14),
                        label: Text(_isSyncing ? l10n.get('syncing') : l10n.get('syncNow'), style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),
              
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
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
