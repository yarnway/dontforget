import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/content_management_strings.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/content/external_backup_references.dart';
import '../../services/recovery/backup_inspector.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';

final externalBackupPickerProvider =
    Provider<Future<({File file, String name})?> Function()>(
      (_) => () async {
        final selected = await FilePicker.pickFile();
        return selected?.path == null
            ? null
            : (file: File(selected!.path!), name: selected.name);
      },
    );
final externalBackupInspectorProvider = Provider<BackupInspector>(
  (_) => BackupInspector.platform(),
);

class ExternalBackupReferencesDialog extends ConsumerStatefulWidget {
  const ExternalBackupReferencesDialog({super.key});

  @override
  ConsumerState<ExternalBackupReferencesDialog> createState() =>
      _ExternalBackupReferencesDialogState();
}

class _ExternalBackupReferencesDialogState
    extends ConsumerState<ExternalBackupReferencesDialog> {
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  BackupInspectionCancellation? _cancellation;
  bool _busy = false;
  String? _message;
  bool get _current =>
      mounted && _database.isCurrent(_generation) && _runtime.isCurrent(_birth);
  String t(String key) => contentText(context, key);

  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _generation = _database.captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(text)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              key: const ValueKey('external-backup-confirm'),
              onPressed: () => Navigator.pop(c, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _register() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    _cancellation = BackupInspectionCancellation();
    try {
      final store = ref.read(workspaceDraftsProvider.notifier);
      final previous = await store.readPersistedKey(
        ExternalBackupReferences.storageKey,
      );
      ExternalBackupReferences.read(previous);
      if (!_current) return;
      final selected = await ref.read(externalBackupPickerProvider)();
      if (!_current || selected == null) return;
      final preview = await ref
          .read(externalBackupInspectorProvider)
          .inspect(selected.file, cancellation: _cancellation);
      if (!_current) return;
      final next = ExternalBackupReferences.add(
        previous,
        preview,
        selected.name,
        at: DateTime.now(),
      );
      final entry = ExternalBackupReferences.read(
        next,
      ).firstWhere((e) => e['digest'] == preview.digest);
      final confirmed = await _confirm(
        t('externalRegister'),
        '${entry['name']}\n${t('externalPathCount').replaceAll('{count}', '${preview.referencedMediaPaths.length}')}\n\n${t('externalRegisterHint')}',
        t('externalRegister'),
      );
      if (!_current || !confirmed) return;
      await store.compareAndPut(
        ExternalBackupReferences.storageKey,
        previous,
        next,
      );
      if (_current) setState(() => _message = t('done'));
    } catch (_) {
      if (_current) setState(() => _message = t('externalFailed'));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _detail(Map<String, dynamic> entry) async {
    if (!_current || _busy) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(entry['name'] as String),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              '${t('externalPathCount').replaceAll('{count}', '${(entry['paths'] as List).length}')}\n${formatLocalDateTime(DateTime.parse(entry['at'] as String))}\n\n${(entry['paths'] as List).join('\n')}',
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('external-backup-remove'),
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('externalRemove')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(t('close')),
          ),
        ],
      ),
    );
    if (!_current || remove != true) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final store = ref.read(workspaceDraftsProvider.notifier);
      final previous = await store.readPersistedKey(
        ExternalBackupReferences.storageKey,
      );
      final current = ExternalBackupReferences.read(
        previous,
      ).where((e) => e['digest'] == entry['digest']);
      if (current.isEmpty ||
          jsonEncode(current.single) != jsonEncode(entry) ||
          !_current) {
        throw StateError('Reference changed');
      }
      final confirmed = await _confirm(
        t('externalRemove'),
        '${entry['name']}\n\n${t('externalRemoveHint')}',
        t('externalRemove'),
      );
      if (!_current || !confirmed) return;
      await store.compareAndPut(
        ExternalBackupReferences.storageKey,
        previous,
        ExternalBackupReferences.remove(previous, entry['digest'] as String),
      );
      if (_current) setState(() => _message = t('done'));
    } catch (_) {
      if (_current) setState(() => _message = t('externalFailed'));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final raw = ref.watch(
      workspaceDraftsProvider,
    )[ExternalBackupReferences.storageKey];
    List<Map<String, dynamic>> entries = const [];
    var valid = true;
    try {
      entries = ExternalBackupReferences.read(raw);
    } catch (_) {
      valid = false;
    }
    return AlertDialog(
      key: const ValueKey('external-backup-dialog'),
      title: Text(t('externalBackups')),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .6,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(t('externalHint')),
              if (_busy) const LinearProgressIndicator(),
              if (!valid || _message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(valid ? _message! : t('externalFailed')),
                ),
              for (final entry in entries)
                ListTile(
                  key: ValueKey('external-backup-${entry['digest']}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    entry['name'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    t('externalPathCount').replaceAll(
                      '{count}',
                      '${(entry['paths'] as List).length}',
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _busy ? null : () => _detail(entry),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          key: const ValueKey('external-backup-register'),
          onPressed: _busy || !valid ? null : _register,
          icon: const Icon(Icons.add_rounded),
          label: Text(t('externalRegister')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('close')),
        ),
      ],
    );
  }
}
