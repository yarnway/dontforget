import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../models/ai_profile.dart';
import '../../models/settings.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/providers.dart';
import '../../data/database_helper.dart';
import '../../services/recovery/runtime_gate.dart';

/// A local draft: ordering or typing never sends a network request.
class AiProfilesScreen extends ConsumerStatefulWidget {
  const AiProfilesScreen({super.key, this.initialDraft});
  final AppSettings? initialDraft;
  @override
  ConsumerState<AiProfilesScreen> createState() => _AiProfilesScreenState();
}

class _AiProfilesScreenState extends ConsumerState<AiProfilesScreen> {
  List<AiProfile> profiles = [];
  bool fallback = false;
  bool ready = false;
  late final DataGeneration generation;
  late final RuntimeRecoveryToken birth;
  bool saving = false;
  String? error;
  final Map<String, int> keyRevisions = {};

  @override
  void initState() {
    super.initState();
    generation = ref.read(databaseHelperProvider).captureGeneration();
    birth = ref.read(runtimeRecoveryGateProvider).capture();
    load();
  }

  String t(String key) =>
      (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
              AppLocalizations(const Locale('zh')))
          .get(key);

  void checkCurrent() {
    ref.read(runtimeRecoveryGateProvider).check(birth);
    ref.read(databaseHelperProvider).checkGeneration(generation);
  }

  Future<void> load() async {
    try {
      await ref.read(settingsProvider.notifier).ready;
      if (!mounted) return;
      checkCurrent();
      final AppSettings settings = widget.initialDraft ?? ref.read(settingsProvider);
      setState(() {
        profiles = settings.effectiveProfiles.toList();
        fallback = settings.aiFallbackEnabled;
        ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => error = t('aiProfilesUnavailable'));
    }
  }

  void change(int index, AiProfile value) => setState(() {
    profiles[index] = value;
    error = null;
  });

  void changeUrl(int index, String value) {
    final profile = profiles[index];
    final url = value.trim();
    final sameOrigin = profile.settings.baseUrl.trim() == url;
    if (!sameOrigin && profile.settings.apiKey.isNotEmpty) {
      keyRevisions[profile.id] = (keyRevisions[profile.id] ?? 0) + 1;
    }
    change(
      index,
      profile.copyWith(
        settings: profile.settings.copyWith(
          baseUrl: url,
          apiKey: sameOrigin ? profile.settings.apiKey : '',
        ),
      ),
    );
  }

  void move(int index, int offset) => setState(() {
    final item = profiles.removeAt(index);
    profiles.insert(index + offset, item);
  });

  Future<void> save() async {
    if (saving || !ready) return;
    if (profiles.any((p) => p.enabled && !p.isConfigured)) {
      setState(() => error = t('aiProfilesIncomplete'));
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      checkCurrent();
      final current = ref.read(settingsProvider);
      final enabled = profiles.where((p) => p.enabled);
      final primary = enabled.isEmpty ? null : enabled.first.settings;
      await ref
          .read(settingsProvider.notifier)
          .updateSettings(
            current.copyWith(
              language: widget.initialDraft?.language ?? current.language,
              aiProfiles: profiles,
              aiFallbackEnabled: fallback,
              apiKey: primary?.apiKey ?? '',
              baseUrl: primary?.baseUrl ?? current.baseUrl,
              modelName: primary?.modelName ?? current.modelName,
            ),
          );
      if (mounted) {
        checkCurrent();
        Navigator.pop(context, true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = t('aiProfilesSaveFailed');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t('aiProfilesTitle'))),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: saving || !ready ? null : save,
          child: Text(saving ? t('aiProfilesSaving') : t('aiProfilesSave')),
        ),
      ),
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!ready && error == null) const LinearProgressIndicator(),
            Text(t('aiProfilesScope')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('aiProfilesFallback')),
              subtitle: Text(t('aiProfilesFallbackHint')),
              value: fallback,
              onChanged: saving || !ready
                  ? null
                  : (value) => setState(() => fallback = value),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            for (var index = 0; index < profiles.length; index++)
              profileCard(index),
            OutlinedButton.icon(
              onPressed: saving || !ready || profiles.length >= 16
                  ? null
                  : () => setState(
                      () => profiles.add(
                        AiProfile(
                          id: const Uuid().v4(),
                          label: t(
                            'aiProfilesNameDefault',
                          ).replaceAll('{n}', '${profiles.length + 1}'),
                          settings: AppSettings.defaults(),
                          enabled: false,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.add),
              label: Text(t('aiProfilesAdd')),
            ),
            const SizedBox(height: 12),
            Text(t('aiProfilesStorage')),
          ],
        ),
      ),
    ),
  );

  Widget profileCard(int index) {
    final profile = profiles[index];
    return Card(
      key: ValueKey(profile.id),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('aiProfilesPriority').replaceAll('{n}', '${index + 1}'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Switch(
                  value: profile.enabled,
                  onChanged: saving || !ready
                      ? null
                      : (value) =>
                            change(index, profile.copyWith(enabled: value)),
                ),
                IconButton(
                  tooltip: t('aiProfilesUp'),
                  onPressed: saving || index == 0
                      ? null
                      : () => move(index, -1),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: t('aiProfilesDown'),
                  onPressed: saving || index == profiles.length - 1
                      ? null
                      : () => move(index, 1),
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: t('aiProfilesRemove'),
                  onPressed: saving || profiles.length == 1
                      ? null
                      : () => setState(() => profiles.removeAt(index)),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
            field(
              profile.id,
              'name',
              t('aiProfilesName'),
              profile.label,
              (v) => change(index, profile.copyWith(label: v)),
            ),
            field(
              profile.id,
              'url',
              t('aiProfilesUrl'),
              profile.settings.baseUrl,
              (v) => changeUrl(index, v),
            ),
            field(
              profile.id,
              'model',
              t('aiProfilesModel'),
              profile.settings.modelName,
              (v) => change(
                index,
                profile.copyWith(
                  settings: profile.settings.copyWith(modelName: v.trim()),
                ),
              ),
            ),
            field(
              profile.id,
              'key',
              'API Key',
              profile.settings.apiKey,
              (v) => change(
                index,
                profile.copyWith(
                  settings: profile.settings.copyWith(apiKey: v.trim()),
                ),
              ),
              secret: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget field(
    String id,
    String kind,
    String label,
    String value,
    ValueChanged<String> onChanged, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextFormField(
      key: ValueKey(
        secret ? '$id/$kind/${keyRevisions[id] ?? 0}' : '$id/$kind',
      ),
      initialValue: value,
      enabled: !saving,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: kind == 'url' ? t('aiProfilesUrlHint') : null,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    ),
  );
}
