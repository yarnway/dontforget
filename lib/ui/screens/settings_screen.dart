import '../widgets/inline_feedback.dart';
import '../widgets/unsaved_editor_scope.dart';
import '../widgets/editable_text_menu.dart';
import '../widgets/appearance_picker.dart';
import '../widgets/input_send_mode_picker.dart';
import '../widgets/settings/lan_sync_section.dart';
import '../widgets/settings/local_engine_probe_section.dart';
import '../../data/database_helper.dart';
import '../../services/console_url_launcher.dart';
import '../../services/recovery/runtime_gate.dart';
import '../widgets/notification_permission_panel.dart';
import '../widgets/notification_diagnostics_panel.dart';
import '../widgets/credential_status_panel.dart';
import '../widgets/portable_backup_panel.dart';
import '../widgets/content_management_panel.dart';
import '../../l10n/content_management_strings.dart';
import '../../l10n/data_protection_strings.dart';
import '../../services/notification_diagnostics_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/providers.dart';
import '../../services/llm_service.dart';
import '../../models/settings.dart';
import '../../l10n/app_localizations.dart';
import 'backup_preview_screen.dart';
import 'ai_profiles_screen.dart';
import 'speech_settings_screen.dart';
import '../../l10n/preferences_strings.dart';
import '../../l10n/speech_recognition_strings.dart';

export '../../services/console_url_launcher.dart';

final notificationFailureHistoryReaderProvider =
    Provider<Future<NotificationFailureHistory> Function()>((ref) {
      final database = ref.read(databaseHelperProvider);
      return () => NotificationFailureHistory.read(database);
    });

class ModelProvider {
  final String name;
  final String defaultBaseUrl;
  final String defaultModel;

  const ModelProvider(this.name, this.defaultBaseUrl, this.defaultModel);
}

const _ollamaPreset = ModelProvider(
  'Ollama (本地离线大模型)',
  'http://localhost:11434/v1',
  'llama3',
);

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
  _ollamaPreset,
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

enum SettingsArea { ai, notifications, sync }

/// Advanced pages reuse the existing save/recovery logic. Null retains the
/// legacy full editor for compatibility with internal callers and fixtures.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.area});
  final SettingsArea? area;

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
  NotificationDiagnosticsService? _diagnostics;
  NotificationDiagnosticsService get _notificationDiagnostics =>
      _diagnostics ??= NotificationDiagnosticsService.forNotifications(
        ref.read(notificationServiceProvider),
        database: ref.read(databaseHelperProvider),
        readSchedule: ref.read(notificationScheduleStatusReaderProvider),
        readFailureHistory: ref.read(notificationFailureHistoryReaderProvider),
        checkCurrent: _checkCurrent,
      );
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

  ModelProvider? _matchProvider(AppSettings settings) {
    for (final provider in _providers) {
      if (provider.defaultBaseUrl == settings.baseUrl &&
          provider.defaultModel == settings.requestModelName) {
        return provider;
      }
    }
    return null;
  }

  Future<void> _load() async {
    if (_loadError != null && mounted) {
      setState(() => _loadError = null);
    }
    try {
      await ref.read(settingsProvider.notifier).ready;
      if (!mounted) return;
      _checkCurrent();
      final current = ref.read(settingsProvider);
      _apiKeyController.text = current.apiKey;
      _baseUrlController.text = current.baseUrl;
      _modelNameController.text = current.modelName;
      setState(() {
        _selectedLang = current.language;
        _selectedAppearance = current.appearance;
        _selectedSendMode = current.inputSendMode;
        _selectedProvider = _matchProvider(current);
        _savedDraft = _captureDraft();
        _dirty = false;
        _loadError = null;
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
  bool _obscureApiKey = true;
  bool _lanSyncBusy = false;

  bool get _syncCurrent =>
      mounted &&
      ref.read(databaseHelperProvider).isCurrent(_generation) &&
      ref.read(runtimeRecoveryGateProvider).isCurrent(_birth);

  @override
  void initState() {
    super.initState();
    _generation = ref.read(databaseHelperProvider).captureGeneration();
    _birth = ref.read(runtimeRecoveryGateProvider).capture();
    final settings = ref.read(settingsProvider);
    _apiKeyController = TextEditingController(text: settings.apiKey);
    _baseUrlController = TextEditingController(text: settings.baseUrl);
    _modelNameController = TextEditingController(text: settings.modelName);
    _selectedLang = settings.language;
    _selectedAppearance = settings.appearance;
    _selectedSendMode = settings.inputSendMode;
    _selectedProvider = _matchProvider(settings);
    _savedDraft = _captureDraft();
    for (final controller in [
      _apiKeyController,
      _baseUrlController,
      _modelNameController,
    ]) {
      controller.addListener(_draftChanged);
    }
    if (widget.area == SettingsArea.notifications) {
      _ready = true;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _apiKeyController.removeListener(_draftChanged);
    _baseUrlController.removeListener(_draftChanged);
    _modelNameController.removeListener(_draftChanged);
    _apiKeyController.clear();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelNameController.dispose();
    super.dispose();
  }

  void _onProviderChanged(ModelProvider? provider) {
    if (provider == null) return;
    if (_baseUrlController.text.trim() != provider.defaultBaseUrl) {
      _apiKeyController.clear();
    }
    _baseUrlController.text = provider.defaultBaseUrl;
    _modelNameController.text = provider.defaultModel;
    if (provider == _ollamaPreset) {
      _apiKeyController.text = 'ollama';
    }
    setState(() {
      _selectedProvider = provider;
      _dirty = _captureDraft() != _savedDraft;
    });
  }

  Future<void> _openModelProfiles() async {
    if (!_ready || _isSaving) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AiProfilesScreen(
          initialDraft: _modelDraft(ref.read(settingsProvider)),
        ),
      ),
    );
    if (!mounted || saved != true) return;
    try {
      _checkCurrent();
    } catch (_) {
      return;
    }
    final current = ref.read(settingsProvider);
    _apiKeyController.text = current.apiKey;
    _baseUrlController.text = current.baseUrl;
    _modelNameController.text = current.modelName;
    setState(() {
      _selectedProvider = _matchProvider(current);
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
        tone: FeedbackTone.warning,
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
        tone: FeedbackTone.warning,
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
    if (_isBackingUp || !_syncCurrent) return;
    setState(() => _isBackingUp = true);
    var messageKey = 'backupSuccess';
    var ok = true;
    try {
      _checkCurrent();
      await ref.read(databaseHelperProvider).createMirrorBackup();
    } catch (_) {
      ok = false;
      messageKey = 'backupFailed';
    }
    if (!mounted) return;
    setState(() => _isBackingUp = false);
    if (!_syncCurrent) return;
    InlineFeedback.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).get(messageKey))),
      tone: ok ? FeedbackTone.success : FeedbackTone.error,
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
    final clearedApiKey =
        settings.apiKey.trim().isNotEmpty && newSettings.apiKey.isEmpty;
    try {
      _checkCurrent();
      await ref.read(settingsProvider.notifier).updateSettings(newSettings);
      if (!mounted) return false;
      _checkCurrent();
      _savedDraft = _captureDraft();
      _dirty = false;
      if (clearedApiKey) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('settingsApiKeyClearedHint'),
            ),
          ),
          tone: FeedbackTone.info,
        );
      }
      return true;
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('settingsSaveFailed'),
            ),
          ),
          tone: FeedbackTone.error,
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
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('linkCopied'))),
          tone: FeedbackTone.success,
        );
      }
    } finally {
      if (mounted) setState(() => _isOpeningConsole = false);
    }
  }

  void _applyLocalEngine(LocalInferenceEndpoint endpoint) {
    final l10n = AppLocalizations.of(context);
    _baseUrlController.text = endpoint.url;
    _modelNameController.text = endpoint.recommendedModel ?? 'default-model';
    _apiKeyController.text = 'ollama';
    setState(() {
      _selectedProvider = null;
      _dirty = _captureDraft() != _savedDraft;
    });

    InlineFeedback.of(context).hideCurrentSnackBar();
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text('${l10n.get('appliedLocalEngine')} (${endpoint.name})'),
      ),
      tone: FeedbackTone.success,
    );
  }

  Widget _buildConsoleLinkChip(String label, String url) {
    return Semantics(
      link: true,
      child: ActionChip(
        onPressed: _isOpeningConsole ? null : () => _openConsoleUrl(url),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        avatar: Icon(
          Icons.arrow_outward,
          size: 14,
          color: Theme.of(context).colorScheme.primary,
        ),
        label: Text(label),
      ),
    );
  }

  Widget _section({required Widget child}) => Card.outlined(
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );

  Widget _advancedConnection(Widget child) => widget.area == null
      ? child
      : Card.outlined(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const ValueKey('settings-advanced-connection'),
            shape: const Border(),
            collapsedShape: const Border(),
            leading: const Icon(Icons.tune),
            title: Text(
              preferencesText(
                AppLocalizations.of(context).locale.languageCode,
                'connection',
              ),
            ),
            children: [child],
          ),
        );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return UnsavedEditorScope(
      dirty: _dirty,
      busy:
          _isSaving ||
          _isBackingUp ||
          _lanSyncBusy ||
          (!_ready && _loadError == null),
      onSave: _saveSettings,
      builder: (context, save, exit) => Scaffold(
        extendBodyBehindAppBar: false,
        appBar: AppBar(
          leading: BackButton(onPressed: exit),
          title: Text(
            widget.area == null
                ? l10n.get('settings')
                : preferencesText(l10n.locale.languageCode, widget.area!.name),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        bottomNavigationBar:
            widget.area == SettingsArea.notifications ||
                (widget.area == SettingsArea.sync && !_dirty)
            ? null
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  border: Border(
                    top: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                child: SafeArea(
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
                            if (widget.area == null)
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _isBackingUp ? null : _backupNow,
                                  icon: const Icon(
                                    Icons.backup_outlined,
                                    size: 18,
                                  ),
                                  label: Text(
                                    l10n.get('backupNow'),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            if (widget.area == null) const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed:
                                    !_ready ||
                                        _isSaving ||
                                        (widget.area != null && !_dirty)
                                    ? null
                                    : save,
                                child: Text(l10n.get('save')),
                              ),
                            ),
                          ],
                        ),
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
                      LinearProgressIndicator(
                        semanticsLabel: l10n.get('loading'),
                      ),
                    if (_loadError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Semantics(
                                container: true,
                                liveRegion: true,
                                child: Text(
                                  l10n.get(_loadError!),
                                  style: TextStyle(color: colors.error),
                                ),
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('settings-load-retry'),
                              onPressed: _load,
                              child: Text(l10n.get('retry')),
                            ),
                          ],
                        ),
                      ),
                    if (widget.area == null) ...[
                      AppearancePicker(
                        value: _selectedAppearance,
                        onChanged: !_ready || _isSaving
                            ? null
                            : (value) {
                                setState(() => _selectedAppearance = value);
                                _draftChanged();
                              },
                      ),
                    ],
                    if (widget.area == null) ...[const SizedBox(height: 20)],
                    if (widget.area == null) ...[
                      InputSendModePicker(
                        value: _selectedSendMode,
                        onChanged: !_ready || _isSaving
                            ? null
                            : (value) {
                                setState(() => _selectedSendMode = value);
                                _draftChanged();
                              },
                      ),
                    ],
                    if (widget.area == null) ...[const SizedBox(height: 20)],
                    if (widget.area == null ||
                        widget.area == SettingsArea.ai) ...[
                      Card.outlined(
                        child: ListTile(
                          key: const ValueKey('settings-speech'),
                          leading: const Icon(Icons.record_voice_over_outlined),
                          title: Text(
                            speechText(l10n.locale.languageCode, 'title'),
                          ),
                          subtitle: Text(
                            speechText(l10n.locale.languageCode, 'provider'),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: !_ready || _isSaving
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        const SpeechSettingsScreen(),
                                  ),
                                ),
                        ),
                      ),
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.ai) ...[
                      const SizedBox(height: 20),
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.ai) ...[
                      Card.outlined(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          key: const ValueKey('settings-model-profiles'),
                          leading: const Icon(Icons.swap_vert),
                          title: Text(l10n.get('aiProfilesEntry')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: !_ready || _isSaving
                              ? null
                              : _openModelProfiles,
                        ),
                      ),
                    ],
                    if (widget.area == null) ...[
                      const SizedBox(height: 20),
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
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.ai) ...[
                      const SizedBox(height: 20),
                      CredentialStatusPanel(
                        onRetry: _reloadCredentials,
                        allowRemove: false,
                      ),
                    ],
                    if (widget.area == null) ...[
                      const SizedBox(height: 20),
                      Card.outlined(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          key: const ValueKey('settings-data-protection'),
                          leading: const Icon(
                            Icons.enhanced_encryption_outlined,
                          ),
                          title: Text(protectionText(context, 'title')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _isSaving || !_ready
                              ? null
                              : _openDataProtection,
                        ),
                      ),
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.ai) ...[
                      ValueListenableBuilder<AiExtractionStatus?>(
                        valueListenable: ref
                            .watch(llmServiceProvider)
                            .lastExtraction,
                        builder: (context, status, _) => status == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(
                                  top: 12,
                                  bottom: 8,
                                ),
                                child: Text(
                                  status.label == null
                                      ? l10n.get('aiProfilesAllFailed')
                                      : '${l10n.get('aiProfilesLast').replaceAll('{name}', status.label!)}${status.usedFallback ? ' · ${l10n.get('aiProfilesUsedFallback')}' : ''}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                      ),
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.ai) ...[
                      const SizedBox(height: 20),
                    ],
                    if (widget.area == null) ...[
                      const SizedBox(height: 20),
                      Card.outlined(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          key: const ValueKey('settings-backup-preview'),
                          leading: const Icon(Icons.fact_check_outlined),
                          title: Text(l10n.get('backupPreviewTitle')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const BackupPreviewScreen(),
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (widget.area == null) ...[const SizedBox(height: 20)],
                    if (widget.area == null ||
                        widget.area == SettingsArea.notifications) ...[
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
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.notifications) ...[
                      const SizedBox(height: 20),
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.notifications) ...[
                      NotificationDiagnosticsPanel(
                        service: _notificationDiagnostics,
                      ),
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.notifications) ...[
                      const SizedBox(height: 20),
                    ],
                    if (widget.area == null) ...[
                      // Language Setting
                      _section(
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
                                DropdownMenuItem(
                                  value: 'ja',
                                  child: Text('日本語'),
                                ),
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
                    ],
                    if (widget.area == null) ...[const SizedBox(height: 20)],
                    if (widget.area == null ||
                        widget.area == SettingsArea.sync) ...[
                      LocalEngineProbeSection(
                        enabled: _ready && !_isSaving,
                        onApply: _applyLocalEngine,
                      ),
                      const SizedBox(height: 20),
                      LanSyncSection(
                        generation: _generation,
                        birth: _birth,
                        onBusyChanged: (busy) {
                          if (mounted && _lanSyncBusy != busy) {
                            setState(() => _lanSyncBusy = busy);
                          }
                        },
                      ),
                      const SizedBox(height: 20),
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.ai) ...[
                      // AI Configuration (Wireframe style)
                      _advancedConnection(
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: widget.area == null
                              ? BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                )
                              : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.memory_rounded,
                                    size: 18,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
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
                              const SizedBox(height: 20),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  ActionChip(
                                    avatar: Icon(
                                      Icons.bolt_rounded,
                                      size: 15,
                                      color: colors.primary,
                                    ),
                                    label: Text(
                                      l10n.get('quickDeepSeek'),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    side: BorderSide(
                                      color: colors.primary.withValues(
                                        alpha: 0.4,
                                      ),
                                    ),
                                    onPressed: () =>
                                        _onProviderChanged(_providers[0]),
                                  ),
                                  ActionChip(
                                    avatar: Icon(
                                      Icons.auto_awesome,
                                      size: 15,
                                      color: colors.tertiary,
                                    ),
                                    label: Text(
                                      l10n.get('quickGemini'),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    side: BorderSide(
                                      color: colors.tertiary.withValues(
                                        alpha: 0.4,
                                      ),
                                    ),
                                    onPressed: () =>
                                        _onProviderChanged(_providers[1]),
                                  ),
                                  ActionChip(
                                    avatar: Icon(
                                      Icons.download_for_offline_rounded,
                                      size: 15,
                                      color: colors.secondary,
                                    ),
                                    label: Text(
                                      l10n.get('ollamaLocal'),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    side: BorderSide(
                                      color: colors.secondary.withValues(
                                        alpha: 0.4,
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
                              const SizedBox(height: 20),
                              TextField(
                                key: const ValueKey('settings-api-key'),
                                contextMenuBuilder: buildEditableTextMenu,
                                controller: _apiKeyController,
                                autocorrect: false,
                                enableSuggestions: false,
                                enableIMEPersonalizedLearning: false,
                                decoration: InputDecoration(
                                  labelText: l10n.get('apiKey'),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  suffixIcon: IconButton(
                                    key: const ValueKey(
                                      'settings-api-key-toggle',
                                    ),
                                    tooltip: l10n.get(
                                      _obscureApiKey
                                          ? 'showApiKey'
                                          : 'hideApiKey',
                                    ),
                                    icon: Icon(
                                      _obscureApiKey
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      size: 18,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscureApiKey = !_obscureApiKey,
                                    ),
                                  ),
                                ),
                                obscureText: _obscureApiKey,
                              ),
                              const SizedBox(height: 8),
                              // Platform Official Console Direct Links
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 2,
                                  bottom: 6,
                                ),
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
                              const SizedBox(height: 20),
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
                      ),
                    ],
                    if (widget.area == SettingsArea.ai) ...[
                      const SizedBox(height: 20),
                      LocalEngineProbeSection(
                        enabled: _ready && !_isSaving,
                        onApply: _applyLocalEngine,
                      ),
                    ],
                    if (widget.area == null ||
                        widget.area == SettingsArea.ai) ...[
                      const SizedBox(height: 24),
                    ],
                    if (widget.area == null) ...[
                      Text(
                        l10n.get('backupDescription'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (widget.area == null) ...[const SizedBox(height: 16)],
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
