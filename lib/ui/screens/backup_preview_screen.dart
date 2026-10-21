import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as paths;

import '../../l10n/app_localizations.dart';
import '../../providers/recovery_coordinator.dart';
import '../../services/recovery/backup_inspector.dart';
import '../../services/recovery/database_recovery.dart';
import '../widgets/recovery_confirmation_dialog.dart';

/// Inspects read-only, then offers a separately acknowledged recovery plan.
class BackupPreviewScreen extends StatefulWidget {
  const BackupPreviewScreen({
    super.key,
    this.inspector,
    this.pickPath,
    this.prepareRestore,
    this.executeRestore,
  });

  final BackupInspector? inspector;
  final Future<String?> Function()? pickPath;
  final Future<RecoveryPlan> Function(File source, BackupPreview preview)?
  prepareRestore;
  final Future<void> Function(RecoveryPlan plan)? executeRestore;

  @override
  State<BackupPreviewScreen> createState() => _BackupPreviewScreenState();
}

class _BackupPreviewScreenState extends State<BackupPreviewScreen> {
  BackupInspectionCancellation? _cancellation;
  BackupPreview? _preview;
  File? _source;
  String? _fileName;
  String? _messageKey;
  String? _restoreMessageKey;
  bool _failed = false;
  bool _busy = false;
  bool _cancelling = false;
  bool _reviewingRestore = false;
  int _request = 0;

  @override
  void dispose() {
    _request++;
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy || _reviewingRestore) return;
    final request = ++_request;
    final cancellation = BackupInspectionCancellation();
    _cancellation = cancellation;
    final dialogTitle = AppLocalizations.of(context).get('backupPreviewSelect');
    setState(() {
      _busy = true;
      _cancelling = false;
      _preview = null;
      _source = null;
      _fileName = null;
      _messageKey = null;
      _restoreMessageKey = null;
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
          _source = File(selected);
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

  Future<void> _reviewRestore() async {
    final preview = _preview;
    final source = _source;
    if (_busy || _reviewingRestore || preview == null || source == null) return;
    final request = ++_request;
    var executing = false;
    setState(() {
      _reviewingRestore = true;
      _messageKey = null;
      _restoreMessageKey = null;
      _failed = false;
    });
    try {
      // Read the provider only when recovery is requested. Inspection remains
      // independently usable and never creates a coordinator or changes data.
      final plan = widget.prepareRestore != null
          ? await widget.prepareRestore!(source, preview)
          : await ProviderScope.containerOf(
              context,
              listen: false,
            ).read(recoveryCoordinatorProvider).prepare(source, preview);
      if (!mounted || request != _request) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => RecoveryConfirmationDialog(
          preview: plan.preview,
          currentCounts: plan.currentCounts,
          rollbackDirectory: plan.rollbackDirectory,
        ),
      );
      if (!mounted || request != _request || confirmed != true) return;
      executing = true;
      if (widget.executeRestore != null) {
        await widget.executeRestore!(plan);
      } else {
        await ProviderScope.containerOf(
          context,
          listen: false,
        ).read(recoveryCoordinatorProvider).restore(plan);
      }
    } on BackupInspectionException catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _restoreMessageKey = executing
            ? 'backupRestoreExecutionFailed'
            : error.code == BackupInspectionError.sourceChanged
            ? 'backupRestoreChanged'
            : 'backupRestorePrepareFailed';
        if (error.code == BackupInspectionError.sourceChanged) {
          _failed = true;
          _messageKey = _restoreMessageKey;
          _restoreMessageKey = null;
          _preview = null;
          _source = null;
        }
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _restoreMessageKey = executing
            ? 'backupRestoreExecutionFailed'
            : 'backupRestorePrepareFailed';
      });
    } finally {
      if (mounted && request == _request) {
        setState(() => _reviewingRestore = false);
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
            const SizedBox(height: 12),
            if (_restoreMessageKey != null) ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  l10n.get(_restoreMessageKey!),
                  style: TextStyle(color: colors.error),
                ),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              key: const ValueKey('backup-restore-review'),
              onPressed: _reviewingRestore ? null : _reviewRestore,
              icon: const Icon(Icons.restore),
              label: Text(
                l10n.get(
                  _reviewingRestore
                      ? 'backupRestorePreparing'
                      : 'backupRestoreReview',
                ),
              ),
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
                      onPressed: _busy || _reviewingRestore ? null : _check,
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
