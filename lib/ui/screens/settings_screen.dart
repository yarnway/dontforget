import '../widgets/inline_feedback.dart';
import '../widgets/unsaved_editor_scope.dart';
import '../widgets/editable_text_menu.dart';
import '../widgets/appearance_picker.dart';
import '../widgets/input_send_mode_picker.dart';
import '../../data/database_helper.dart';
import '../../services/recovery/runtime_gate.dart';
import '../widgets/notification_permission_panel.dart';
import '../widgets/notification_diagnostics_panel.dart';
import '../widgets/credential_status_panel.dart';
import '../widgets/portable_backup_panel.dart';
import '../widgets/content_management_panel.dart';
import '../../l10n/content_management_strings.dart';
import '../../l10n/data_protection_strings.dart';
import '../../services/notification_diagnostics_service.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/providers.dart';
import '../../services/llm_service.dart';
import '../../models/settings.dart';
import '../../l10n/app_localizations.dart';
import 'backup_preview_screen.dart';
import 'ai_profiles_screen.dart';

typedef ConsoleProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Desktop browser handoff, injectable without launching real apps in tests.
class ConsoleUrlLauncher {
  const ConsoleUrlLauncher({this.runProcess = Process.run});
  final ConsoleProcessRunner runProcess;

  Future<bool> open(String url, {TargetPlatform? platform}) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return false;
    }
    final target = platform ?? defaultTargetPlatform;
    final (String, List<String>)? command = switch (target) {
      TargetPlatform.windows => (
        'rundll32',
        ['url.dll,FileProtocolHandler', url],
      ),
      TargetPlatform.macOS => ('open', [url]),
      TargetPlatform.linux => ('xdg-open', [url]),
      _ => null,
    };
    if (command == null) return false;
    try {
      final result = await runProcess(command.$1, command.$2);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

final consoleUrlLauncherProvider = Provider<ConsoleUrlLauncher>(
  (_) => const ConsoleUrlLauncher(),
);

final notificationFailureHistoryReaderProvider =
    Provider<Future<NotificationFailureHistory> Function()>((ref) {
      final database = ref.read(databaseHelperProvider);
      return () => NotificationFailureHistory.read(database);
    });

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

const List<ModelProvider> _providers = [
  ModelProvider(
    'DeepSeek (推荐默认)',
    'https://api.deepseek.com',
    'deepseek-flash',
  ),
  ModelProvider(
    'Gemini (Google 官方)',
    'https://generativelanguage.googleapis.com/v1beta/openai',
    'gemini-3.6-flash',
  ),
  ModelProvider(
    'Ollama (本地离线大模型)',
    'http://localhost:11434/v1',
    'llama3',
    'ollama',
  ),
  ModelProvider('OpenAI (ChatGPT)', 'https://api.openai.com/v1', 'gpt-4o-mini'),
  ModelProvider(
    'Kimi (Moonshot)',
    'https://api.moonshot.cn/v1',
    'moonshot-v1-8k',
  ),
  ModelProvider(
    'Qwen (DashScope)',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'qwen-plus',
  ),
  ModelProvider('Grok (xAI)', 'https://api.x.ai/v1', 'grok-beta'),
  ModelProvider(
    'Doubao (Volcengine)',
    'https://ark.volces.com/api/v3',
    'ep-xxx',
  ),
];

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

typedef _SettingsDraft = ({
  String key,
  String url,
  String model,
  String language,
  AppAppearance appearance,
  InputSendMode inputSendMode,
});

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late _SettingsDraft _savedDraft;
  late final DataGeneration _generation;
  late final RuntimeRecoveryToken _birth;
  late final NotificationDiagnosticsService _notificationDiagnostics;
  bool _ready = false, _dirty = false;
  String? _loadError;

  _SettingsDraft _captureDraft() => (
    key: _apiKeyController.text,
    url: _baseUrlController.text,
    model: _modelNameController.text,
    language: _selectedLang,
    appearance: _selectedAppearance,
    inputSendMode: _selectedSendMode,
  );

  void _draftChanged() {
    final dirty = _captureDraft() != _savedDraft;
    if (mounted && dirty != _dirty) setState(() => _dirty = dirty);
  }

  void _checkCurrent() {
    ref.read(databaseHelperProvider).checkGeneration(_generation);
    ref.read(runtimeRecoveryGateProvider).check(_birth);
  }

  Future<void> _load() async {
    try {
      await ref.read(settingsProvider.notifier).ready;
      if (!mounted) return;
      _checkCurrent();
      final current = ref.read(settingsProvider);
      setState(() {
        _apiKeyController.text = current.apiKey;
        _baseUrlController.text = current.baseUrl;
        _modelNameController.text = current.modelName;
        _selectedLang = current.language;
        _selectedAppearance = current.appearance;
        _selectedSendMode = current.inputSendMode;
        _selectedProvider = null;
        for (final provider in _providers) {
          if (provider.defaultBaseUrl == current.baseUrl &&
              provider.defaultModel == current.requestModelName) {
            _selectedProvider = provider;
            break;
          }
        }
        _savedDraft = _captureDraft();
        _dirty = false;
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = 'aiProfilesUnavailable');
    }
  }

  late TextEditingController _apiKeyController;
  late TextEditingController _baseUrlController;
  late TextEditingController _modelNameController;
  String _selectedLang = 'zh';
  AppAppearance _selectedAppearance = AppAppearance.system;
  InputSendMode _selectedSendMode = InputSendMode.enter;
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
    _generation = ref.read(databaseHelperProvider).captureGeneration();
    _birth = ref.read(runtimeRecoveryGateProvider).capture();
    _notificationDiagnostics = NotificationDiagnosticsService.forNotifications(
      ref.read(notificationServiceProvider),
      database: ref.read(databaseHelperProvider),
      readSchedule: ref.read(notificationScheduleStatusReaderProvider),
      readFailureHistory: ref.read(notificationFailureHistoryReaderProvider),
      checkCurrent: _checkCurrent,
    );
    final settings = ref.read(settingsProvider);
    _apiKeyController = TextEditingController(text: settings.apiKey);
    _baseUrlController = TextEditingController(text: settings.baseUrl);
    _modelNameController = TextEditingController(text: settings.modelName);
    _selectedLang = settings.language;
    _selectedAppearance = settings.appearance;
    _selectedSendMode = settings.inputSendMode;
    _savedDraft = _captureDraft();
    for (final controller in [
      _apiKeyController,
      _baseUrlController,
      _modelNameController,
    ]) {
      controller.addListener(_draftChanged);
    }
    _load();

    for (var p in _providers) {
      if (p.defaultBaseUrl == settings.baseUrl &&
          p.defaultModel == settings.requestModelName) {
        _selectedProvider = p;
        break;
      }
    }

    final lanSync = ref.read(lanSyncServiceProvider);
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
      if (_baseUrlController.text.trim() != provider.defaultBaseUrl) {
        _apiKeyController.clear();
      }
      _selectedProvider = provider;
      _baseUrlController.text = provider.defaultBaseUrl;
      _modelNameController.text = provider.defaultModel;
      if (provider.defaultApiKey != null &&
          provider.defaultApiKey!.isNotEmpty) {
        _apiKeyController.text = provider.defaultApiKey!;
      }
    });
  }

  Future<void> _openModelProfiles() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AiProfilesScreen(
          initialDraft: _modelDraft(ref.read(settingsProvider)),
        ),
      ),
    );
    if (!mounted || saved != true) return;
    final current = ref.read(settingsProvider);
    setState(() {
      _apiKeyController.text = current.apiKey;
      _baseUrlController.text = current.baseUrl;
      _modelNameController.text = current.modelName;
      _selectedProvider = null;
      // The nested editor saved models only; other preferences remain drafts.
      _savedDraft = (
        key: current.apiKey,
        url: current.baseUrl,
        model: current.modelName,
        language: current.language,
        appearance: current.appearance,
        inputSendMode: current.inputSendMode,
      );
      _dirty = _captureDraft() != _savedDraft;
    });
  }

  Future<void> _reloadCredentials() async {
    if (_dirty) {
      InlineFeedback.of(context).showSnackBar(
        SnackBar(content: Text(protectionText(context, 'retryDirty'))),
      );
      return;
    }
    _checkCurrent();
    await ref.read(settingsProvider.notifier).reloadCredentials();
    if (!mounted) return;
    _checkCurrent();
    await _load();
  }

  Future<void> _openDataProtection() async {
    if (_dirty) {
      InlineFeedback.of(context).showSnackBar(
        SnackBar(content: Text(protectionText(context, 'retryDirty'))),
      );
      return;
    }
    _checkCurrent();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(protectionText(context, 'title'))),
          body: const PortableBackupPanel(),
        ),
      ),
    );
    if (!mounted) return;
    try {
      _checkCurrent();
      await _load();
    } catch (_) {}
  }

  bool _isSaving = false;
  bool _isBackingUp = false;

  Future<void> _backupNow() async {
    if (_isBackingUp) return;
    setState(() => _isBackingUp = true);
    var messageKey = 'backupSuccess';
    try {
      await ref.read(databaseHelperProvider).createMirrorBackup();
    } catch (_) {
      messageKey = 'backupFailed';
    }
    if (!mounted) return;
    setState(() => _isBackingUp = false);
    InlineFeedback.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).get(messageKey))),
    );
  }

  AppSettings _modelDraft(AppSettings settings) {
    final profiles = settings.effectiveProfiles.toList();
    final changed =
        _apiKeyController.text.trim() != settings.apiKey ||
        _baseUrlController.text.trim() != settings.baseUrl ||
        _modelNameController.text.trim() != settings.modelName;
    var primary = profiles.indexWhere((p) => p.enabled);
    if (primary < 0 && changed && profiles.isNotEmpty) primary = 0;
    if (primary >= 0 && changed) {
      profiles[primary] = profiles[primary].copyWith(
        enabled: _apiKeyController.text.trim().isNotEmpty,
        settings: profiles[primary].settings.copyWith(
          apiKey: _apiKeyController.text.trim(),
          baseUrl: _baseUrlController.text.trim(),
          modelName: _modelNameController.text.trim(),
        ),
      );
    }
    return settings.copyWith(
      aiProfiles: profiles,
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      modelName: _modelNameController.text.trim(),
      language: _selectedLang,
      appearance: _selectedAppearance,
      inputSendMode: _selectedSendMode,
    );
  }

  Future<bool> _saveSettings() async {
    if (_isSaving || !_ready) return false;
    setState(() => _isSaving = true);
    final settings = ref.read(settingsProvider);
    final newSettings = _modelDraft(settings);
    try {
      _checkCurrent();
      await ref.read(settingsProvider.notifier).updateSettings(newSettings);
      if (!mounted) return false;
      _checkCurrent();
      _savedDraft = _captureDraft();
      _dirty = false;
      return true;
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('settingsSaveFailed'),
            ),
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  bool _isOpeningConsole = false;

  Future<void> _openConsoleUrl(String url) async {
    if (_isOpeningConsole) return;
    setState(() => _isOpeningConsole = true);
    try {
      final opened = await ref.read(consoleUrlLauncherProvider).open(url);
      if (!mounted || opened) return;
      final l10n = AppLocalizations.of(context);
      var copying = false;
      var copyFailed = false;
      final copied = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (dialogContext, updateDialog) => AlertDialog(
            title: Text(l10n.get('consoleOpenFallbackTitle')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.get('consoleOpenFallbackHint')),
                  const SizedBox(height: 12),
                  SelectableText(
                    url,
                    key: const ValueKey('console-fallback-url'),
                  ),
                  if (copyFailed) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.get('linkCopyFailed'),
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l10n.get('close')),
              ),
              FilledButton.icon(
                onPressed: copying
                    ? null
                    : () async {
                        updateDialog(() => copying = true);
                        try {
                          await Clipboard.setData(ClipboardData(text: url));
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (_) {
                          if (dialogContext.mounted) {
                            updateDialog(() {
                              copying = false;
                              copyFailed = true;
                            });
                          }
                        }
                      },
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: Text(l10n.get('copyLink')),
              ),
            ],
          ),
        ),
      );
      if (copied == true && mounted) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.get('linkCopied'))));
      }
    } finally {
      if (mounted) setState(() => _isOpeningConsole = false);
    }
  }

  Future<void> _probeLocalEngines() async {
    if (_isProbing) return;
    setState(() => _isProbing = true);
    try {
      final llmService = ref.read(llmServiceProvider);
      final results = await llmService.probeLocalInferenceEndpoints();
      if (mounted) setState(() => _probeResults = results);
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).get('probeFailed')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProbing = false);
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

    InlineFeedback.of(context).hideCurrentSnackBar();
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text('${l10n.get('appliedLocalEngine')} (${endpoint.name})'),
      ),
    );
  }

  Future<void> _toggleLanServer() async {
    final lanSync = ref.read(lanSyncServiceProvider);
    final dbHelper = ref.read(databaseHelperProvider);
    if (_isLanServerRunning) {
      await lanSync.stopServer();
      if (!mounted) return;
      setState(() {
        _isLanServerRunning = false;
        _lanPin = '';
      });
    } else {
      try {
        final reminders = ref.read(remindersProvider.notifier);
        final info = await lanSync.startServer(
          dbHelper: dbHelper,
          onDataChanged: () {
            if (reminders.mounted) reminders.refreshReminders();
          },
        );
        if (!mounted) return;
        setState(() {
          _isLanServerRunning = true;
          _lanIp = info.ip;
          _lanPin = info.pin;
        });
      } catch (e) {
        if (mounted) {
          InlineFeedback.of(
            context,
          ).showSnackBar(SnackBar(content: Text('启动服务失败: $e')));
        }
      }
    }
  }

  Future<void> _syncWithTarget() async {
    final l10n = AppLocalizations.of(context);
    final ip = _targetIpController.text.trim();
    final pin = _targetPinController.text.trim();
    if (ip.isEmpty || pin.isEmpty) {
      InlineFeedback.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.get('syncFailed'))));
      return;
    }

    setState(() => _isSyncing = true);
    final lanSync = ref.read(lanSyncServiceProvider);
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
      InlineFeedback.of(context).hideCurrentSnackBar();
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          content: Text(
            success ? l10n.get('syncSuccess') : l10n.get('syncFailed'),
          ),
          backgroundColor: success ? Colors.green.shade700 : Colors.redAccent,
        ),
      );
    }
  }

  Widget _buildConsoleLinkChip(String label, String url) {
    return InkWell(
      onTap: _isOpeningConsole ? null : () => _openConsoleUrl(url),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.7),
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
            Icon(
              Icons.arrow_outward,
              size: 10,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return UnsavedEditorScope(
      dirty: _dirty,
      busy:
          _isSaving ||
          _isBackingUp ||
          _isSyncing ||
          (!_ready && _loadError == null),
      onSave: _saveSettings,
      builder: (context, save, exit) => Scaffold(
        extendBodyBehindAppBar: false,
        appBar: AppBar(
          leading: BackButton(onPressed: exit),
          title: Text(
            l10n.get('settings'),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  12,
                  16,
                  12 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isBackingUp ? null : _backupNow,
                        icon: const Icon(Icons.backup_outlined, size: 18),
                        label: Text(
                          l10n.get('backupNow'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: !_ready || _isSaving ? null : save,
                        child: Text(l10n.get('save')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  children: [
                    if (!_ready && _loadError == null)
                      const LinearProgressIndicator(),
                    if (_loadError != null)
                      Text(
                        l10n.get(_loadError!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    AppearancePicker(
                      value: _selectedAppearance,
                      onChanged: !_ready || _isSaving
                          ? null
                          : (value) {
                              setState(() => _selectedAppearance = value);
                              _draftChanged();
                            },
                    ),
                    const SizedBox(height: 14),
                    InputSendModePicker(
                      value: _selectedSendMode,
                      onChanged: !_ready || _isSaving
                          ? null
                          : (value) {
                              setState(() => _selectedSendMode = value);
                              _draftChanged();
                            },
                    ),
                    const SizedBox(height: 14),
                    // Privacy Shield Guarantee
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.teal.shade900.withValues(alpha: 0.25)
                            : Colors.teal.shade50.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isDark
                              ? Colors.tealAccent.withValues(alpha: 0.3)
                              : Colors.teal.shade300,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.security_rounded,
                            color: isDark
                                ? Colors.tealAccent
                                : Colors.teal.shade700,
                            size: 22,
                          ),
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
                                    color: isDark
                                        ? Colors.tealAccent
                                        : Colors.teal.shade900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  l10n.get('privacyShieldDesc'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark
                                        ? Colors.grey.shade300
                                        : Colors.teal.shade900.withValues(
                                            alpha: 0.8,
                                          ),
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

                    Card.outlined(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        key: const ValueKey('settings-model-profiles'),
                        leading: const Icon(Icons.swap_vert),
                        title: Text(l10n.get('aiProfilesEntry')),
                        subtitle: Text(l10n.get('aiProfilesEntryHint')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _isSaving ? null : _openModelProfiles,
                      ),
                    ),
                    Card.outlined(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        key: const ValueKey('settings-content-management'),
                        leading: const Icon(Icons.inventory_2_outlined),
                        title: Text(contentText(context, 'title')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _isSaving || !_ready
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (context) => Scaffold(
                                    appBar: AppBar(
                                      title: Text(
                                        contentText(context, 'title'),
                                      ),
                                    ),
                                    body: const ContentManagementPanel(),
                                  ),
                                ),
                              ),
                      ),
                    ),
                    CredentialStatusPanel(
                      onRetry: _reloadCredentials,
                      allowRemove: false,
                    ),
                    Card.outlined(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        key: const ValueKey('settings-data-protection'),
                        leading: const Icon(Icons.enhanced_encryption_outlined),
                        title: Text(protectionText(context, 'title')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _isSaving || !_ready
                            ? null
                            : _openDataProtection,
                      ),
                    ),
                    ValueListenableBuilder<AiExtractionStatus?>(
                      valueListenable: ref
                          .watch(llmServiceProvider)
                          .lastExtraction,
                      builder: (context, status, _) => status == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                status.label == null
                                    ? l10n.get('aiProfilesAllFailed')
                                    : '${l10n.get('aiProfilesLast').replaceAll('{name}', status.label!)}${status.usedFallback ? ' · ${l10n.get('aiProfilesUsedFallback')}' : ''}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                    ),
                    const SizedBox(height: 14),

                    Card.outlined(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        key: const ValueKey('settings-backup-preview'),
                        leading: const Icon(Icons.fact_check_outlined),
                        title: Text(l10n.get('backupPreviewTitle')),
                        subtitle: Text(l10n.get('backupPreviewReadOnly')),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const BackupPreviewScreen(),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 14),

                    NotificationPermissionPanel(
                      onReadSystemNotifications: ref
                          .read(notificationServiceProvider)
                          .readSystemNotifications,
                      onReadScheduleStatus: ref.read(
                        notificationScheduleStatusReaderProvider,
                      ),
                      onRetryReminders: () => ref
                          .read(remindersProvider.notifier)
                          .retryNotificationDelivery(),
                    ),
                    const SizedBox(height: 14),

                    NotificationDiagnosticsPanel(
                      service: _notificationDiagnostics,
                    ),
                    const SizedBox(height: 14),

                    // Language Setting
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.black26
                            : Colors.white.withValues(alpha: 0.6),
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
                              Icon(
                                Icons.language_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                l10n.get('language'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            key: ValueKey('settings-language-$_ready'),
                            initialValue: _selectedLang,
                            items: const [
                              DropdownMenuItem(
                                value: 'zh',
                                child: Text('简体中文'),
                              ),
                              DropdownMenuItem(
                                value: 'en',
                                child: Text('English'),
                              ),
                              DropdownMenuItem(value: 'ja', child: Text('日本語')),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setState(() {
                                  _selectedLang = val;
                                  _dirty = _captureDraft() != _savedDraft;
                                });
                              }
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
                        color: isDark
                            ? Colors.black26
                            : Colors.white.withValues(alpha: 0.6),
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
                              Icon(
                                Icons.radar_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l10n.get('localEngineProbe'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                                onPressed: _isProbing
                                    ? null
                                    : _probeLocalEngines,
                                icon: _isProbing
                                    ? const SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.refresh_rounded,
                                        size: 14,
                                      ),
                                label: Text(
                                  _isProbing
                                      ? l10n.get('probing')
                                      : l10n.get('probeNow'),
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            l10n.get('probeDesc'),
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          if (_probeResults != null) ...[
                            const SizedBox(height: 10),
                            for (final ep in _probeResults!)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.03)
                                        : Colors.grey.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: ep.isAvailable
                                          ? Colors.green.withValues(alpha: 0.4)
                                          : Colors.grey.withValues(alpha: 0.2),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        ep.isAvailable
                                            ? Icons.check_circle_rounded
                                            : Icons.radio_button_unchecked,
                                        size: 16,
                                        color: ep.isAvailable
                                            ? Colors.green
                                            : Colors.grey,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '${ep.name} (Port ${ep.port})',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            Text(
                                              ep.isAvailable
                                                  ? '${ep.recommendedModel} · ${ep.latencyMs}ms'
                                                  : '端口未监听',
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: ep.isAvailable
                                                    ? Colors.green.shade700
                                                    : Colors.grey,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (ep.isAvailable)
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            visualDensity:
                                                VisualDensity.compact,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                          ),
                                          onPressed: () =>
                                              _applyLocalEngine(ep),
                                          child: Text(
                                            l10n.get('applyToSettings'),
                                            style: const TextStyle(
                                              fontSize: 10,
                                            ),
                                          ),
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
                        color: isDark
                            ? Colors.black26
                            : Colors.white.withValues(alpha: 0.6),
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
                              Icon(
                                Icons.wifi_tethering_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l10n.get('lanSyncTitle'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
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
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          if (_isLanServerRunning) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.blueGrey.shade900.withValues(
                                        alpha: 0.3,
                                      )
                                    : Colors.blueGrey.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.blueGrey.withValues(alpha: 0.3),
                                  width: 0.8,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.router_rounded,
                                        size: 14,
                                        color: Colors.blueAccent,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${l10n.get('lanServerRunning')}$_lanIp:42888',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.vpn_key_rounded,
                                        size: 14,
                                        color: Colors.amber,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${l10n.get('syncPin')}$_lanPin',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1.5,
                                          color: Colors.amber,
                                        ),
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
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
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
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
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
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
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
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                              ),
                              onPressed: _isSyncing ? null : _syncWithTarget,
                              icon: _isSyncing
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.sync_rounded, size: 14),
                              label: Text(
                                _isSyncing
                                    ? l10n.get('syncing')
                                    : l10n.get('syncNow'),
                                style: const TextStyle(fontSize: 12),
                              ),
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
                        color: isDark
                            ? Colors.black26
                            : Colors.white.withValues(alpha: 0.6),
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
                              Icon(
                                Icons.memory_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l10n.get('llmConfigTitle'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ActionChip(
                                avatar: const Icon(
                                  Icons.bolt_rounded,
                                  size: 15,
                                  color: Colors.blue,
                                ),
                                label: Text(
                                  l10n.get('quickDeepSeek'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  side: BorderSide(
                                    color: Colors.blue.withValues(alpha: 0.4),
                                    width: 1,
                                  ),
                                ),
                                onPressed: () =>
                                    _onProviderChanged(_providers[0]),
                              ),
                              ActionChip(
                                avatar: const Icon(
                                  Icons.auto_awesome,
                                  size: 15,
                                  color: Colors.deepPurple,
                                ),
                                label: Text(
                                  l10n.get('quickGemini'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  side: BorderSide(
                                    color: Colors.deepPurple.withValues(
                                      alpha: 0.4,
                                    ),
                                    width: 1,
                                  ),
                                ),
                                onPressed: () =>
                                    _onProviderChanged(_providers[1]),
                              ),
                              ActionChip(
                                avatar: const Icon(
                                  Icons.download_for_offline_rounded,
                                  size: 15,
                                  color: Colors.teal,
                                ),
                                label: Text(
                                  l10n.get('ollamaLocal'),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  side: BorderSide(
                                    color: Colors.teal.withValues(alpha: 0.4),
                                    width: 1,
                                  ),
                                ),
                                onPressed: () =>
                                    _onProviderChanged(_providers[2]),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<ModelProvider>(
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: l10n.get('presetProvider'),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            initialValue: _selectedProvider,
                            items: [
                              DropdownMenuItem(
                                value: null,
                                child: Text(l10n.get('customProvider')),
                              ),
                              ..._providers.map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: _onProviderChanged,
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            key: const ValueKey('settings-api-key'),
                            controller: _apiKeyController,
                            decoration: InputDecoration(
                              labelText: l10n.get('apiKey'),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              helperText: l10n.get('apiKeyHelper'),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
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
                                    Icon(
                                      Icons.open_in_new_rounded,
                                      size: 13,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      l10n.get('openOfficialSite'),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    _buildConsoleLinkChip(
                                      'DeepSeek',
                                      'https://platform.deepseek.com/api_keys',
                                    ),
                                    _buildConsoleLinkChip(
                                      'Google AI Studio',
                                      'https://aistudio.google.com/app/apikey',
                                    ),
                                    _buildConsoleLinkChip(
                                      'OpenAI',
                                      'https://platform.openai.com/api-keys',
                                    ),
                                    _buildConsoleLinkChip(
                                      'Moonshot (Kimi)',
                                      'https://platform.moonshot.cn/console/api-keys',
                                    ),
                                    _buildConsoleLinkChip(
                                      '阿里百炼 (Qwen)',
                                      'https://bailian.console.aliyun.com/',
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            key: const ValueKey('settings-base-url'),
                            contextMenuBuilder: buildEditableTextMenu,
                            controller: _baseUrlController,
                            onChanged: (_) => _apiKeyController.clear(),
                            decoration: InputDecoration(
                              labelText: l10n.get('baseUrl'),
                              helperText: l10n.get('aiProfilesUrlHint'),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            key: const ValueKey('settings-model-name'),
                            contextMenuBuilder: buildEditableTextMenu,
                            controller: _modelNameController,
                            decoration: InputDecoration(
                              labelText: l10n.get('modelNameLabel'),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),
                    Text(
                      l10n.get('backupDescription'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
