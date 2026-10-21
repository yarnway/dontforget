import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/recovery_coordinator.dart';

/// Replaces all old routes after the coordinator has rebuilt provider state.
class RecoveryOutcomeScreen extends StatelessWidget {
  const RecoveryOutcomeScreen({
    super.key,
    required this.phase,
    required this.rollbackDirectory,
    required this.onContinue,
    required this.onExit,
  });

  final RecoveryPhase phase;
  final String? rollbackDirectory;
  final VoidCallback onContinue;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (titleKey, bodyKey, icon) = switch (phase) {
      RecoveryPhase.succeeded => (
        'backupRestoreSucceededTitle',
        'backupRestoreSucceededBody',
        Icons.check_circle_outline,
      ),
      RecoveryPhase.rolledBack => (
        'backupRestoreRolledBackTitle',
        'backupRestoreRolledBackBody',
        Icons.restore,
      ),
      RecoveryPhase.notApplied => (
        'backupRestoreNotAppliedTitle',
        'backupRestoreNotAppliedBody',
        Icons.info_outline,
      ),
      RecoveryPhase.blocked => (
        'backupRestoreBlockedTitle',
        'backupRestoreBlockedBody',
        Icons.lock_outline,
      ),
      RecoveryPhase.reloading => (
        'backupRestoreBusyTitle',
        'backupRestoreReloading',
        Icons.sync,
      ),
      RecoveryPhase.restoring => (
        'backupRestoreBusyTitle',
        'backupRestoreRestoring',
        Icons.sync,
      ),
      _ => ('backupRestoreBusyTitle', 'backupRestoreQuiescing', Icons.sync),
    };
    final finished = {
      RecoveryPhase.succeeded,
      RecoveryPhase.rolledBack,
      RecoveryPhase.notApplied,
      RecoveryPhase.blocked,
    }.contains(phase);
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      icon,
                      size: 40,
                      color: phase == RecoveryPhase.blocked
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.get(titleKey),
                        key: const ValueKey('recovery-outcome-title'),
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(l10n.get(bodyKey)),
                    if (!finished) ...[
                      const SizedBox(height: 24),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(l10n.get('backupRestoreBusyNotice')),
                    ],
                    if (finished && rollbackDirectory != null) ...[
                      const SizedBox(height: 28),
                      Text(
                        l10n.get('backupRestoreOperationDirectory'),
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(l10n.get('backupRestoreOperationNotice')),
                      const SizedBox(height: 8),
                      SelectableText(
                        rollbackDirectory!,
                        key: const ValueKey('recovery-outcome-location'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (finished) ...[
                      const SizedBox(height: 28),
                      FilledButton.icon(
                        key: ValueKey(
                          phase == RecoveryPhase.blocked
                              ? 'recovery-outcome-exit'
                              : 'recovery-outcome-continue',
                        ),
                        autofocus: true,
                        onPressed: phase == RecoveryPhase.blocked
                            ? onExit
                            : onContinue,
                        icon: Icon(
                          phase == RecoveryPhase.blocked
                              ? Icons.close
                              : Icons.arrow_forward,
                        ),
                        label: Text(
                          l10n.get(
                            phase == RecoveryPhase.blocked
                                ? 'backupRestoreExit'
                                : 'backupRestoreContinue',
                          ),
                        ),
                      ),
                    ],
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
