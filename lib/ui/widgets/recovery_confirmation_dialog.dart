import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/recovery/backup_inspector.dart';

/// Only confirms the reviewed plan. It never starts recovery itself.
class RecoveryConfirmationDialog extends StatefulWidget {
  const RecoveryConfirmationDialog({
    super.key,
    required this.preview,
    required this.currentCounts,
    required this.rollbackDirectory,
  });

  final BackupPreview preview;
  final Map<String, int> currentCounts;
  final String rollbackDirectory;

  @override
  State<RecoveryConfirmationDialog> createState() =>
      _RecoveryConfirmationDialogState();
}

class _RecoveryConfirmationDialogState
    extends State<RecoveryConfirmationDialog> {
  bool _acknowledged = false;
  bool _submitted = false;

  void _confirm() {
    if (!_acknowledged || _submitted || !mounted) return;
    _submitted = true;
    Navigator.of(context).pop(true);
  }

  void _cancel() {
    if (_submitted || !mounted) return;
    _submitted = true;
    Navigator.of(context).pop(false);
  }

  Widget _notice(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final preview = widget.preview;
    return AlertDialog(
      key: const ValueKey('recovery-confirmation-dialog'),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      constraints: const BoxConstraints(maxWidth: 640),
      title: Text(l10n.get('backupRestoreTitle')),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.get('backupRestoreReplacement'),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2.2),
                1: FlexColumnWidth(),
                2: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  children: [
                    const SizedBox(),
                    _cell(l10n.get('backupRestoreCurrent'), heading: true),
                    _cell(l10n.get('backupRestoreCandidate'), heading: true),
                  ],
                ),
                for (final entry in const {
                  'reminders': 'backupPreviewTasks',
                  'media_records': 'backupPreviewMedia',
                  'settings': 'backupPreviewSettings',
                }.entries)
                  TableRow(
                    children: [
                      _cell(l10n.get(entry.value)),
                      _cell(
                        '${widget.currentCounts[entry.key] ?? 0}',
                        key: ValueKey('recovery-current-${entry.key}'),
                      ),
                      _cell(
                        '${preview.counts[entry.key] ?? 0}',
                        key: ValueKey('recovery-candidate-${entry.key}'),
                      ),
                    ],
                  ),
              ],
            ),
            const Divider(height: 28),
            _notice(Icons.edit_note_outlined, l10n.get('backupRestoreDrafts')),
            _notice(Icons.wifi_off_outlined, l10n.get('backupRestoreLan')),
            _notice(Icons.attach_file_outlined, l10n.get('backupRestoreFiles')),
            if (preview.missingMedia > 0)
              _notice(
                Icons.warning_amber_rounded,
                '${l10n.get('backupPreviewMissingMedia')}: ${preview.missingMedia}',
              ),
            if (preview.unresolvedReferences > 0)
              _notice(
                Icons.link_off_outlined,
                '${l10n.get('backupPreviewUnresolved')}: ${preview.unresolvedReferences}',
              ),
            _notice(
              Icons.key_outlined,
              l10n.get(
                preview.containsCredentials
                    ? 'backupPreviewCredentials'
                    : 'backupPreviewNoCredentials',
              ),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.get('backupRestoreRollback'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(l10n.get('backupRestoreRollbackNotice')),
            const SizedBox(height: 8),
            SelectableText(
              widget.rollbackDirectory,
              key: const ValueKey('recovery-rollback-location'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              key: const ValueKey('recovery-acknowledge'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _acknowledged,
              onChanged: _submitted
                  ? null
                  : (value) => setState(() => _acknowledged = value ?? false),
              title: Text(l10n.get('backupRestoreAcknowledge')),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('recovery-confirmation-cancel'),
          autofocus: true,
          onPressed: _cancel,
          child: Text(l10n.get('backupRestoreCancel')),
        ),
        FilledButton(
          key: const ValueKey('recovery-confirmation-confirm'),
          onPressed: _acknowledged && !_submitted ? _confirm : null,
          child: Text(l10n.get('backupRestoreConfirm')),
        ),
      ],
    );
  }

  Widget _cell(String text, {bool heading = false, Key? key}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
    child: Text(
      text,
      key: key,
      style: heading ? const TextStyle(fontWeight: FontWeight.w600) : null,
    ),
  );
}
