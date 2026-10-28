import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/data_protection_strings.dart';
import '../../data/database_helper.dart';
import '../../services/recovery/runtime_gate.dart';
import '../../providers/providers.dart';
import '../../services/security/credential_repository.dart';

class CredentialStatusPanel extends ConsumerStatefulWidget {
  const CredentialStatusPanel({
    super.key,
    this.onRetry,
    this.allowRemove = true,
  });
  final Future<void> Function()? onRetry;
  final bool allowRemove;
  @override
  ConsumerState<CredentialStatusPanel> createState() =>
      _CredentialStatusPanelState();
}

class _CredentialStatusPanelState extends ConsumerState<CredentialStatusPanel> {
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  bool get _current =>
      mounted && _database.isCurrent(_generation) && _runtime.isCurrent(_birth);
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _generation = _database.captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
  }

  bool _busy = false;
  String? _error;
  Future<void> _retry() async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      if (widget.onRetry != null) {
        await widget.onRetry!();
      } else {
        await ref.read(settingsProvider.notifier).reloadCredentials();
      }
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = 'failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (!_current || _busy) return;
    final expectedSettings = ref.read(settingsProvider);
    String t(String k) => protectionText(context, k);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('forget')),
        content: Text(t('forgetHint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('confirm')),
          ),
        ],
      ),
    );
    if (!_current || confirmed != true || _busy) return;
    if (!identical(ref.read(settingsProvider), expectedSettings)) {
      setState(() => _error = 'failed');
      return;
    }
    setState(() => _busy = true);
    try {
      final settings = ref.read(settingsProvider);
      await ref
          .read(settingsProvider.notifier)
          .updateSettings(
            settings.copyWith(
              apiKey: '',
              aiProfiles: settings.effectiveProfiles
                  .map(
                    (p) => p.copyWith(
                      enabled: false,
                      settings: p.settings.copyWith(apiKey: ''),
                    ),
                  )
                  .toList(),
            ),
            clearCredentials: true,
          );
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = 'failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider),
        notifier = ref.read(settingsProvider.notifier);
    String t(String k) => protectionText(context, k);
    final status = notifier.credentialStatus;
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('credentialTitle'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(t(status.name), key: const ValueKey('credential-status')),
            if (_error != null) Text(t(_error!)),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const ValueKey('credential-retry'),
                  onPressed: _busy ? null : _retry,
                  icon: const Icon(Icons.refresh),
                  label: Text(t('retry')),
                ),
                if (widget.allowRemove &&
                    (status != CredentialStatus.notConfigured ||
                        settings.apiKey.isNotEmpty))
                  TextButton(
                    key: const ValueKey('credential-remove'),
                    onPressed: _busy ? null : _remove,
                    child: Text(t('forget')),
                  ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
