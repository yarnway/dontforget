import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/speech_recognition_strings.dart';
import '../../models/speech_settings.dart';
import '../../models/tencent_speech_credentials.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../../services/security/credential_repository.dart';
import '../widgets/unsaved_editor_scope.dart';

class SpeechSettingsScreen extends ConsumerStatefulWidget {
  const SpeechSettingsScreen({super.key});
  @override
  ConsumerState<SpeechSettingsScreen> createState() =>
      _SpeechSettingsScreenState();
}

class _SpeechSettingsScreenState extends ConsumerState<SpeechSettingsScreen> {
  final _appId = TextEditingController(),
      _secretId = TextEditingController(),
      _secretKey = TextEditingController();
  late final DataGeneration _generation;
  late final RuntimeRecoveryToken _birth;
  SpeechSettings _saved = const SpeechSettings();
  bool _ready = false, _saving = false, _enabled = false, _edited = false;
  String? _error;
  String t(String key) =>
      speechText(Localizations.localeOf(context).languageCode, key);
  TencentSpeechCredentials get _credentials => TencentSpeechCredentials(
    appId: _appId.text.trim(),
    secretId: _secretId.text.trim(),
    secretKey: _secretKey.text.trim(),
  );
  SpeechSettings get _draft => !_edited
      ? _saved.copyWith(enabled: _enabled)
      : SpeechSettings(
          enabled: _enabled,
          endpoint: TencentSpeechCredentials.realtimeEndpoint,
          model: TencentSpeechCredentials.engine,
          apiKey:
              _appId.text.isEmpty &&
                  _secretId.text.isEmpty &&
                  _secretKey.text.isEmpty
              ? ''
              : _credentials.encode(),
        );
  bool get _dirty =>
      _ready &&
      (_draft.enabled != _saved.enabled ||
          _draft.endpoint != _saved.endpoint ||
          _draft.model != _saved.model ||
          _draft.apiKey != _saved.apiKey);
  void _check() {
    ref.read(runtimeRecoveryGateProvider).check(_birth);
    ref.read(databaseHelperProvider).checkGeneration(_generation);
  }

  @override
  void initState() {
    super.initState();
    _generation = ref.read(databaseHelperProvider).captureGeneration();
    _birth = ref.read(runtimeRecoveryGateProvider).capture();
    _load();
  }

  Future<void> _load() async {
    try {
      await ref.read(settingsProvider.notifier).ready;
      if (!mounted) return;
      _check();
      _saved = ref.read(settingsProvider).speech;
      final credentials = TencentSpeechCredentials.decode(_saved.apiKey);
      _appId.text = credentials?.appId ?? '';
      _secretId.text = credentials?.secretId ?? '';
      _secretKey.text = credentials?.secretKey ?? '';
      setState(() {
        _ready = true;
        _enabled = _saved.enabled;
        if (_saved.apiKey.isNotEmpty && credentials == null) _error = 'legacy';
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'unavailable');
    }
  }

  @override
  void dispose() {
    _secretId.clear();
    _secretKey.clear();
    _appId.dispose();
    _secretId.dispose();
    _secretKey.dispose();
    super.dispose();
  }

  Future<bool> _save() async {
    if (!_ready || _saving) return false;
    final draft = _draft;
    if ((draft.enabled || (_edited && draft.apiKey.isNotEmpty)) &&
        TencentSpeechCredentials.decode(draft.apiKey) == null) {
      setState(() => _error = 'incomplete');
      return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _check();
      final notifier = ref.read(settingsProvider.notifier);
      if (const {
        CredentialStatus.unavailable,
        CredentialStatus.missing,
        CredentialStatus.migrationPending,
      }.contains(notifier.credentialStatus)) {
        throw const CredentialStorageException();
      }
      final latest = ref.read(settingsProvider);
      await notifier.updateSettings(
        latest.copyWith(speech: draft),
        clearCredentials: _saved.apiKey.isNotEmpty && draft.apiKey.isEmpty,
      );
      if (!mounted) return false;
      _check();
      _saved = draft;
      return true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'saveFailed';
        });
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => UnsavedEditorScope(
    dirty: _dirty,
    busy: _saving || (!_ready && _error == null),
    onSave: _save,
    savedResult: true,
    builder: (context, save, exit) => Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: exit),
        title: Text(t('title')),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            key: const ValueKey('speech-save'),
            onPressed: _ready && !_saving ? save : null,
            child: Text(AppLocalizations.of(context).get('save')),
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (!_ready && _error == null) const LinearProgressIndicator(),
              Text(
                t('provider'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(t('scope')),
              const SizedBox(height: 16),
              Card.outlined(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      SwitchListTile(
                        key: const ValueKey('speech-enabled'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(t('enabled')),
                        value: _enabled,
                        onChanged: !_ready || _saving
                            ? null
                            : (value) => setState(() => _enabled = value),
                      ),
                      const SizedBox(height: 16),
                      for (final field in [
                        (_appId, 'AppID', 'appid'),
                        (_secretId, 'SecretId', 'secret-id'),
                        (_secretKey, 'SecretKey', 'secret-key'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: TextField(
                            key: ValueKey('speech-${field.$3}'),
                            controller: field.$1,
                            enabled: _ready && !_saving,
                            obscureText: field.$1 != _appId,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            keyboardType: field.$1 == _appId
                                ? TextInputType.number
                                : TextInputType.visiblePassword,
                            decoration: InputDecoration(labelText: field.$2),
                            onChanged: (_) => setState(() {
                              _edited = true;
                              _error = null;
                            }),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const ValueKey('speech-clear'),
                          onPressed: !_ready || _saving
                              ? null
                              : () => setState(() {
                                  _appId.clear();
                                  _secretId.clear();
                                  _secretKey.clear();
                                  _edited = true;
                                  _enabled = false;
                                  _error = null;
                                }),
                          child: Text(t('remove')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    t(_error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              ExpansionTile(
                title: Text(t('help')),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(t('privacy')),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(t('limit')),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(t('guide')),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: SelectableText(
                      'https://console.cloud.tencent.com/asr\nhttps://console.cloud.tencent.com/cam/capi',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
