import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/preferences_strings.dart';
import '../../l10n/content_management_strings.dart';
import '../../l10n/data_protection_strings.dart';
import '../../models/settings.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../widgets/content_management_panel.dart';
import '../widgets/global_capture_shortcut_panel.dart';
import '../widgets/portable_backup_panel.dart';
import '../widgets/unsaved_editor_scope.dart';
import 'settings_screen.dart';
import 'about_screen.dart';
import '../../l10n/about_strings.dart';

typedef _Preferences = AppPreferences;

/// Opening everyday preferences never mounts notification observers, LAN sync,
/// model probes or secret editors. Advanced work starts only after navigation.
class PreferencesScreen extends ConsumerStatefulWidget {
  const PreferencesScreen({super.key});
  @override
  ConsumerState<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends ConsumerState<PreferencesScreen> {
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  _Preferences _saved = (
    language: 'zh',
    appearance: AppAppearance.system,
    send: InputSendMode.enter,
  );
  late _Preferences _draft = _saved;
  bool _ready = false, _saving = false;
  String? _error;
  _Preferences _from(AppSettings s) =>
      (language: s.language, appearance: s.appearance, send: s.inputSendMode);
  bool get _dirty => _draft != _saved;
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      ref.read(databaseHelperProvider).isCurrent(_generation);
  void _check() {
    _runtime.check(_birth);
    ref.read(databaseHelperProvider).checkGeneration(_generation);
  }

  @override
  void initState() {
    super.initState();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
    _generation = ref.read(databaseHelperProvider).captureGeneration();
    _load();
  }

  Future<void> _load() async {
    try {
      await ref.read(settingsProvider.notifier).ready;
      if (!_current) return;
      setState(() {
        _saved = _draft = _from(ref.read(settingsProvider));
        _ready = true;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'settingsSaveFailed');
    }
  }

  Future<bool> _save() async {
    if (!_current || !_ready || _saving) return false;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _check();
      await ref
          .read(settingsProvider.notifier)
          .updatePreferences(expected: _saved, value: _draft);
      if (!_current) return false;
      _saved = _draft;
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is PreferencesConflict
              ? 'conflict'
              : 'settingsSaveFailed';
        });
      }
      return false;
    }
  }

  Future<void> _open(Widget page, {bool needsCleanDraft = false}) async {
    if (!_current || !_ready || _saving) return;
    if (needsCleanDraft && _dirty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(protectionText(context, 'retryDirty'))),
      );
      return;
    }
    _check();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    if (!_current) return;
    if (!_dirty) {
      setState(() {
        _saved = _draft = _from(ref.read(settingsProvider));
      });
    }
  }

  Widget _choice<T>({
    required String id,
    required IconData icon,
    required String label,
    required T value,
    required Map<T, String> choices,
    required void Function(T) change,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: DropdownButtonFormField<T>(
      key: ValueKey(id),
      initialValue: value,
      isExpanded: true,
      itemHeight: null,
      decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
      items: choices.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: !_ready || _saving
          ? null
          : (v) {
              if (v != null) {
                setState(() {
                  change(v);
                  _error = null;
                });
              }
            },
    ),
  );
  Widget _entry({
    required String id,
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback action,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 88),
    child: ListTile(
      key: ValueKey(id),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      horizontalTitleGap: 12,
      leading: MediaQuery.textScalerOf(context).scale(14) > 18.2
          ? null
          : ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .09),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
      title: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      trailing: ExcludeSemantics(
        child: Icon(
          Icons.chevron_right,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: !_ready || _saving ? null : action,
    ),
  );
  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    String t(String key) => preferencesText(loc.locale.languageCode, key);
    final sections = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
        child: Text(t('common'), style: Theme.of(context).textTheme.titleSmall),
      ),
      Card.outlined(
        child: Column(
          children: [
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    constraints.maxWidth >= 840 &&
                        MediaQuery.textScalerOf(context).scale(14) <= 18.2
                    ? 3
                    : 1;
                final choices = <Widget>[
                  _choice<String>(
                    id: 'preferences-language',
                    icon: Icons.language,
                    label: loc.get('language'),
                    value: _draft.language,
                    choices: const {'zh': '简体中文', 'en': 'English', 'ja': '日本語'},
                    change: (v) => _draft = (
                      language: v,
                      appearance: _draft.appearance,
                      send: _draft.send,
                    ),
                  ),
                  _choice<AppAppearance>(
                    id: 'preferences-appearance',
                    icon: Icons.palette_outlined,
                    label: loc.get('appearanceTitle'),
                    value: _draft.appearance,
                    choices: {
                      for (final v in AppAppearance.values)
                        v: loc.get('appearance_${v.name}'),
                    },
                    change: (v) => _draft = (
                      language: _draft.language,
                      appearance: v,
                      send: _draft.send,
                    ),
                  ),
                  _choice<InputSendMode>(
                    id: 'preferences-send-mode',
                    icon: Icons.keyboard_return,
                    label: loc.get('inputSendTitle'),
                    value: _draft.send,
                    choices: {
                      for (final v in InputSendMode.values)
                        v: loc.get('inputSend_${v.name}'),
                    },
                    change: (v) => _draft = (
                      language: _draft.language,
                      appearance: _draft.appearance,
                      send: v,
                    ),
                  ),
                ];
                return Wrap(
                  children: [
                    for (final choice in choices)
                      SizedBox(
                        width: constraints.maxWidth / columns,
                        child: choice,
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
      if (Platform.isWindows)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: GlobalCaptureShortcutPanel(),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
        child: Text(
          t('features'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      LayoutBuilder(
        builder: (context, constraints) {
          final columns =
              constraints.maxWidth >= 680 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 18.2
              ? 2
              : 1;
          final width = (constraints.maxWidth - (columns - 1) * 20) / columns;
          final entries = <Widget>[
            _entry(
              id: 'preferences-ai',
              icon: Icons.auto_awesome_outlined,
              title: t('ai'),
              description: t('aiHint'),
              action: () => _open(const SettingsScreen(area: SettingsArea.ai)),
            ),
            _entry(
              id: 'preferences-notifications',
              icon: Icons.notifications_none,
              title: t('notifications'),
              description: t('notificationsHint'),
              action: () =>
                  _open(const SettingsScreen(area: SettingsArea.notifications)),
            ),
            _entry(
              id: 'preferences-protection',
              icon: Icons.shield_outlined,
              title: protectionText(context, 'title'),
              description: t('protectionHint'),
              action: () => _open(
                Scaffold(
                  appBar: AppBar(title: Text(protectionText(context, 'title'))),
                  body: const PortableBackupPanel(),
                ),
                needsCleanDraft: true,
              ),
            ),
            _entry(
              id: 'preferences-content',
              icon: Icons.inventory_2_outlined,
              title: contentText(context, 'title'),
              description: t('contentHint'),
              action: () => _open(
                Scaffold(
                  appBar: AppBar(title: Text(contentText(context, 'title'))),
                  body: const ContentManagementPanel(),
                ),
              ),
            ),
            _entry(
              id: 'preferences-sync',
              icon: Icons.devices_outlined,
              title: t('sync'),
              description: t('syncHint'),
              action: () =>
                  _open(const SettingsScreen(area: SettingsArea.sync)),
            ),
            _entry(
              id: 'preferences-about',
              icon: Icons.info_outline,
              title: aboutText(loc.locale.languageCode, 'title'),
              description: t('aboutHint'),
              action: () => _open(const AboutScreen()),
            ),
          ];
          if (columns == 1) {
            return Card.outlined(
              key: const ValueKey('preferences-feature-grid'),
              child: Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Divider(height: 1),
                      ),
                    entries[i],
                  ],
                ],
              ),
            );
          }
          return Wrap(
            key: const ValueKey('preferences-feature-grid'),
            spacing: 20,
            runSpacing: 20,
            children: [
              for (final entry in entries)
                SizedBox(
                  width: width,
                  child: Card.outlined(child: entry),
                ),
            ],
          );
        },
      ),
      const SizedBox(height: 24),
    ];
    return UnsavedEditorScope(
      dirty: _dirty,
      busy: _saving || (!_ready && _error == null),
      onSave: _save,
      builder: (context, save, exit) => Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: exit),
          title: Text(loc.get('settings')),
        ),
        bottomNavigationBar: !_dirty
            ? null
            : SafeArea(
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      child: FilledButton.icon(
                        key: const ValueKey('preferences-save'),
                        icon: const Icon(Icons.check_rounded),
                        onPressed: _ready && !_saving ? save : null,
                        label: Text(loc.get('save')),
                      ),
                    ),
                  ),
                ),
              ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView(
              key: const ValueKey('preferences-list'),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              children: [
                if (!_ready && _error == null) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error == 'conflict' ? t('conflict') : loc.get(_error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ...sections,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
