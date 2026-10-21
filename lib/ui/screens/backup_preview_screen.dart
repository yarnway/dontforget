import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;

import '../../l10n/app_localizations.dart';
import '../../services/recovery/backup_inspector.dart';

/// Inspects a selected backup without opening or replacing the live database.
class BackupPreviewScreen extends StatefulWidget {
  const BackupPreviewScreen({super.key, this.inspector, this.pickPath});

  final BackupInspector? inspector;
  final Future<String?> Function()? pickPath;

  @override
  State<BackupPreviewScreen> createState() => _BackupPreviewScreenState();
}

class _BackupPreviewScreenState extends State<BackupPreviewScreen> {
  BackupInspectionCancellation? _cancellation;
  BackupPreview? _preview;
  String? _fileName;
  String? _messageKey;
  bool _failed = false;
  bool _busy = false;
  bool _cancelling = false;
  int _request = 0;

  @override
  void dispose() {
    _request++;
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy) return;
    final request = ++_request;
    final cancellation = BackupInspectionCancellation();
    _cancellation = cancellation;
    final dialogTitle = AppLocalizations.of(context).get('backupPreviewSelect');
    setState(() {
      _busy = true;
      _cancelling = false;
      _preview = null;
      _fileName = null;
      _messageKey = null;
      _failed = false;
    });
    try {
      final selected = widget.pickPath != null
          ? await widget.pickPath!()
          : (await FilePicker.pickFile(dialogTitle: dialogTitle))?.path;
      if (!mounted || request != _request) return;
      if (selected == null || cancellation.isCancelled) {
        setState(() => _messageKey = 'backupPreviewCancelled');
        return;
      }
      setState(() => _fileName = paths.basename(selected));
      final result = await (widget.inspector ?? BackupInspector.platform())
          .inspect(File(selected), cancellation: cancellation);
      if (!mounted || request != _request) return;
      setState(() {
        if (cancellation.isCancelled) {
          _messageKey = 'backupPreviewCancelled';
        } else {
          _preview = result;
        }
      });
    } on BackupInspectionException catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        final cancelled =
            cancellation.isCancelled ||
            error.code == BackupInspectionError.cancelled;
        _failed = !cancelled;
        _messageKey = cancelled
            ? 'backupPreviewCancelled'
            : switch (error.code) {
                BackupInspectionError.unsupportedVersion =>
                  'backupPreviewUnsupported',
                BackupInspectionError.unsafeSource =>
                  'backupPreviewNotStandalone',
                BackupInspectionError.sourceChanged =>
                  'backupPreviewSourceChanged',
                BackupInspectionError.tooLarge ||
                BackupInspectionError.tooManyRows => 'backupPreviewTooLarge',
                BackupInspectionError.invalidFormat ||
                BackupInspectionError.invalidSchema ||
                BackupInspectionError.invalidData => 'backupPreviewInvalid',
                _ => 'backupPreviewFailed',
              };
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      // Never display exception text: it may contain paths or backup contents.
      setState(() {
        _failed = !cancellation.isCancelled;
        _messageKey = cancellation.isCancelled
            ? 'backupPreviewCancelled'
            : 'backupPreviewFailed';
      });
    } finally {
      if (mounted && request == _request) {
        setState(() {
          _busy = false;
          _cancelling = false;
          _cancellation = null;
        });
      }
    }
  }

  void _cancel() {
    if (!_busy || _cancelling) return;
    _cancellation?.cancel();
    setState(() => _cancelling = true);
  }

  Widget _row(String label, String value, {bool attention = false}) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 16),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: attention ? colors.error : colors.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _result(BackupPreview result, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final needsAttention =
        result.missingMedia > 0 || result.unresolvedReferences > 0;
    return Card.outlined(
      key: const ValueKey('backup-preview-result'),
      semanticContainer: false,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.get(
                  needsAttention
                      ? 'backupPreviewAttention'
                      : 'backupPreviewPassed',
                ),
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 12),
            Text('${l10n.get('backupPreviewVersion')} v${result.version}'),
            const SizedBox(height: 4),
            Text(
              result.timestamp == null
                  ? l10n.get('backupPreviewNoTime')
                  : '${l10n.get('backupPreviewTime')}: ${MaterialLocalizations.of(context).formatMediumDate(result.timestamp!.toLocal())} ${TimeOfDay.fromDateTime(result.timestamp!.toLocal()).format(context)}',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 28),
            _row(
              l10n.get('backupPreviewTasks'),
              '${result.counts['reminders'] ?? 0}',
            ),
            _row(
              l10n.get('backupPreviewMedia'),
              '${result.counts['media_records'] ?? 0}',
            ),
            _row(
              l10n.get('backupPreviewSettings'),
              '${result.counts['settings'] ?? 0}',
            ),
            const Divider(height: 28),
            _row(
              l10n.get('backupPreviewMissingMedia'),
              '${result.missingMedia}',
              attention: result.missingMedia > 0,
            ),
            _row(
              l10n.get('backupPreviewUnresolved'),
              '${result.unresolvedReferences}',
              attention: result.unresolvedReferences > 0,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.key_outlined,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.get(
                      result.containsCredentials
                          ? 'backupPreviewCredentials'
                          : 'backupPreviewNoCredentials',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l10n.get('backupPreviewFilesNotice'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              key: ValueKey('backup-preview-digest-${result.digest}'),
              internalAddSemanticForOnTap: true,
              tilePadding: EdgeInsets.zero,
              title: Text(l10n.get('backupPreviewDigest')),
              childrenPadding: const EdgeInsets.only(bottom: 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SHA-256'),
                const SizedBox(height: 6),
                SelectableText(result.digest, style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.get('backupPreviewTitle'))),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  l10n.get('backupPreviewReadOnly'),
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(l10n.get('backupPreviewIntro')),
                const SizedBox(height: 8),
                Text(
                  l10n.get('backupPreviewSupport'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('backup-preview-select'),
                      onPressed: _busy ? null : _check,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(
                        l10n.get(
                          _busy
                              ? 'backupPreviewChecking'
                              : 'backupPreviewSelect',
                        ),
                      ),
                    ),
                    if (_busy)
                      TextButton(
                        key: const ValueKey('backup-preview-cancel'),
                        onPressed: _cancelling ? null : _cancel,
                        child: Text(
                          l10n.get(
                            _cancelling
                                ? 'backupPreviewCancelling'
                                : 'backupPreviewCancel',
                          ),
                        ),
                      ),
                  ],
                ),
                if (_busy)
                  Semantics(
                    liveRegion: true,
                    label: l10n.get(
                      _cancelling
                          ? 'backupPreviewCancelling'
                          : 'backupPreviewChecking',
                    ),
                    child: const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(),
                    ),
                  ),
                if (_fileName != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_fileName!, style: theme.textTheme.bodySmall),
                  ),
                if (_messageKey != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.get(_messageKey!),
                        style: TextStyle(
                          color: _failed
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                if (_preview case final result?) ...[
                  const SizedBox(height: 20),
                  _result(result, l10n),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
