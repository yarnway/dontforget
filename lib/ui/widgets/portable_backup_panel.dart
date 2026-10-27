import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../data/database_helper.dart';
import '../../l10n/planning_strings.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/portable_backup_service.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/backup_preview_screen.dart';

class PortableBackupPanel extends ConsumerStatefulWidget {
  const PortableBackupPanel({super.key});
  @override
  ConsumerState<PortableBackupPanel> createState() =>
      _PortableBackupPanelState();
}

class _PortableBackupPanelState extends ConsumerState<PortableBackupPanel> {
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  bool _busy = false;
  String? _result;
  static const _service = PortableBackupService();
  bool get _current =>
      mounted && _runtime.isCurrent(_birth) && _database.isCurrent(_generation);
  String t(String key) => planningText(context, key);
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _generation = _database.captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
  }

  Future<void> _export() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      final backup = await _service.create(_database, _generation);
      if (!mounted || !_current) return;
      final uri = await FilePicker.saveFile(
        fileName:
            'dontforget-${DateTime.now().millisecondsSinceEpoch}.dfbackup.json',
        bytes: backup.bytes,
        mimeType: 'application/json',
        dialogTitle: t('exportBackup'),
      );
      if (!mounted || !_current) return;
      if (uri == null) {
        setState(() => _result = t('exportCancelled'));
        return;
      }
      final details = {
        'at': backup.createdAt.toIso8601String(),
        'location': uri.toString(),
        'media': backup.mediaCount,
        'missing': backup.missingMedia.length,
      };
      await ref
          .read(workspaceDraftsProvider.notifier)
          .put('lastPortableBackup', details);
      if (mounted && _current) {
        setState(
          () => _result =
              '${t('saved')} · ${backup.mediaCount}\n${t('missingMedia')}: ${backup.missingMedia.length}\n$uri',
        );
      }
    } catch (_) {
      if (mounted && _current) setState(() => _result = t('failed'));
    } finally {
      if (mounted && _current) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      final chosen = await FilePicker.pickFile(dialogTitle: t('importBackup'));
      if (!mounted || !_current || chosen?.path == null) return;
      final source = File(chosen!.path!);
      final preview = await _service.inspect(source);
      if (!mounted || !_current) return;
      final documents = await getApplicationDocumentsDirectory();
      if (!mounted || !_current) return;
      final snapshot = await _service.prepareRestore(
        source,
        Directory(p.join(documents.path, 'media')),
        expectedDigest: preview.digest,
        isCurrent: () => _current,
      );
      if (!mounted || !_current) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              BackupPreviewScreen(pickPath: () async => snapshot.path),
        ),
      );
    } catch (_) {
      if (mounted && _current) setState(() => _result = t('failed'));
    } finally {
      if (mounted && _current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawLast = ref.watch(workspaceDraftsProvider)['lastPortableBackup'];
    final last =
        rawLast is Map &&
            rawLast['at'] is String &&
            DateTime.tryParse(rawLast['at']) != null &&
            rawLast['location'] is String
        ? rawLast
        : null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(t('backupHint')),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _export,
          icon: const Icon(Icons.save_alt),
          label: Text(t('exportBackup')),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _restore,
          icon: const Icon(Icons.restore),
          label: Text(t('importBackup')),
        ),
        if (last is Map) ...[
          const Divider(),
          Text(
            '${t('lastBackup')} · ${formatLocalDateTime(DateTime.parse(last['at'] as String))}',
          ),
          Text(last['location'] as String),
          Text('${t('missingMedia')}: ${last['missing']}'),
        ],
        if (_result != null) SelectableText(_result!),
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}
