import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../data/database_helper.dart';
import '../../l10n/data_protection_strings.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/streaming_backup_service.dart';
import '../../services/backup_file_exporter.dart';
import '../../services/backup_cache_service.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../screens/backup_preview_screen.dart';
import 'credential_status_panel.dart';

final streamingBackupServiceProvider = Provider<StreamingBackupService>(
  (_) => const StreamingBackupService(),
);
final backupFileExporterProvider = Provider<BackupFileExporter>(
  (_) => const BackupFileExporter(),
);
final backupCacheRootProvider = Provider<Future<Directory> Function()>(
  (ref) => () async {
    final owned = await ref
        .read(databaseHelperProvider)
        .notificationActionQueueDirectory;
    final namespace = sha256
        .convert(utf8.encode(owned.absolute.path))
        .toString()
        .substring(0, 24);
    return Directory(
      p.join(
        (await getTemporaryDirectory()).path,
        'dontforget-backup-cache',
        namespace,
      ),
    );
  },
);
final backupMediaRootProvider = Provider<Future<Directory> Function()>(
  (_) =>
      () async => Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'media'),
      ),
);

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
  bool _busy = false, _encrypt = true;
  String? _result;
  BackupProgress? _progress;
  BackupControl? _control;
  List<BackupCacheEntry>? _cache;
  final _password = TextEditingController(), _repeat = TextEditingController();
  bool get _current =>
      mounted && _runtime.isCurrent(_birth) && _database.isCurrent(_generation);
  String t(String key) => protectionText(context, key);
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
    _control?.cancel();
    _password.clear();
    _repeat.clear();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _updateProgress(BackupProgress value) {
    if (_current) setState(() => _progress = value);
  }

  void _start() {
    _control = BackupControl();
    setState(() {
      _busy = true;
      _progress = null;
      _result = null;
    });
  }

  void _message(Object error) {
    if (!_current) return;
    setState(
      () => _result = t(
        error is BackupCancelled
            ? 'cancelled'
            : error is BackupPasswordException
            ? 'passwordError'
            : 'backupFailed',
      ),
    );
  }

  Future<void> _export() async {
    if (!_current || _busy) return;
    String? password;
    if (_encrypt) {
      try {
        StreamingBackupService.validatePassword(_password.text);
        if (_password.text != _repeat.text) {
          throw const BackupPasswordException();
        }
        password = _password.text;
      } catch (_) {
        setState(() => _result = t('passwordMismatch'));
        return;
      }
    }
    _start();
    BackupFile? backup;
    try {
      final root = await ref.read(backupCacheRootProvider)();
      if (!_current) return;
      backup = await ref
          .read(streamingBackupServiceProvider)
          .createFile(
            _database,
            _generation,
            root,
            password: password,
            control: _control,
            isCurrent: () => _current,
            onProgress: _updateProgress,
          );
      if (!_current) return;
      _control!.check();
      final location = await ref
          .read(backupFileExporterProvider)
          .save(
            backup.file,
            'dontforget-${backup.createdAt.millisecondsSinceEpoch}.dfbackup',
          );
      if (!_current) return;
      if (location == null) {
        setState(() => _result = t('cancelled'));
        return;
      }
      final details = {
        'at': backup.createdAt.toIso8601String(),
        'location': location,
        'media': backup.mediaCount,
        'missing': backup.missingMedia.length,
        'encrypted': backup.encrypted,
        'format': 2,
      };
      await ref
          .read(workspaceDraftsProvider.notifier)
          .put('lastPortableBackup', details);
      if (_current) {
        setState(
          () => _result =
              '${t('saved')} · ${backup!.mediaCount}\n${t('missingMedia')}: ${backup.missingMedia.length}\n$location',
        );
      }
    } catch (error) {
      _message(error);
    } finally {
      if (backup != null) {
        try {
          await const BackupCacheService().release(backup.file);
        } catch (_) {}
      }
      password = null;
      if (mounted) {
        _password.clear();
        _repeat.clear();
      }
      if (_current) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<String?> _askPassword() => showDialog<String>(
    context: context,
    builder: (_) => const _RestoreBackupPasswordDialog(),
  );
  Future<void> _restore() async {
    if (!_current || _busy) return;
    _start();
    String? password;
    try {
      final chosen = await FilePicker.pickFile(dialogTitle: t('import'));
      if (!_current || chosen?.path == null) return;
      final source = File(chosen!.path!),
          service = ref.read(streamingBackupServiceProvider);
      if (await service.needsPassword(source)) {
        if (!_current) return;
        password = await _askPassword();
        if (!_current || password == null) return;
      }
      _control!.check();
      final preview = await service.inspect(
        source,
        password: password,
        control: _control,
        isCurrent: () => _current,
        onProgress: _updateProgress,
      );
      if (!_current) return;
      final root = await ref.read(backupMediaRootProvider)();
      if (!_current) return;
      final snapshot = await service.prepareRestore(
        source,
        root,
        expectedDigest: preview.digest,
        password: password,
        control: _control,
        isCurrent: () => _current,
        onProgress: _updateProgress,
      );
      if (!mounted || !_current) return;
      // Password is no longer needed once the private, verified restore copy exists.
      password = null;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              BackupPreviewScreen(pickPath: () => Future.value(snapshot.path)),
        ),
      );
    } catch (error) {
      _message(error);
    } finally {
      password = null;
      if (_current) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _inspectCache() async {
    if (!_current || _busy) return;
    _start();
    try {
      final root = await ref.read(backupCacheRootProvider)();
      final entries = await const BackupCacheService().inspect(root);
      if (_current) setState(() => _cache = entries);
    } catch (error) {
      _message(error);
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _clearCache() async {
    if (!_current || _busy || _cache == null || _cache!.isEmpty) return;
    final entries = List<BackupCacheEntry>.from(_cache!);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('cacheConfirm')),
        content: Text(
          '${entries.length} · ${_size(entries.fold<int>(0, (n, e) => n + e.bytes))}\n${t('cacheHint')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('cacheClear')),
          ),
        ],
      ),
    );
    if (!_current || confirm != true) return;
    _start();
    try {
      final root = await ref.read(backupCacheRootProvider)();
      await const BackupCacheService().clearSelected(
        root,
        entries,
        isCurrent: () => _current,
      );
      if (_current) setState(() => _cache = []);
    } catch (_) {
      if (_current) setState(() => _result = t('cacheChanged'));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  static String _size(int value) => value >= 1024 * 1024
      ? '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB'
      : '${(value / 1024).toStringAsFixed(1)} KiB';
  @override
  Widget build(BuildContext context) {
    final raw = ref.watch(workspaceDraftsProvider)['lastPortableBackup'];
    final last =
        raw is Map &&
            raw['at'] is String &&
            DateTime.tryParse(raw['at']) != null &&
            raw['location'] is String
        ? raw
        : null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const CredentialStatusPanel(),
        const SizedBox(height: 12),
        Text(t('backupHint')),
        const SizedBox(height: 12),
        SwitchListTile(
          key: const ValueKey('backup-encryption'),
          contentPadding: EdgeInsets.zero,
          title: Text(t('encrypt')),
          value: _encrypt,
          onChanged: _busy
              ? null
              : (v) => setState(() {
                  _encrypt = v;
                  _password.clear();
                  _repeat.clear();
                }),
        ),
        if (_encrypt) ...[
          Text(t('passwordHint')),
          TextField(
            key: const ValueKey('backup-password'),
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !_busy,
            maxLength: 1024,
            decoration: InputDecoration(labelText: t('password')),
          ),
          TextField(
            key: const ValueKey('backup-password-repeat'),
            controller: _repeat,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !_busy,
            maxLength: 1024,
            decoration: InputDecoration(labelText: t('passwordAgain')),
          ),
        ],
        FilledButton.icon(
          key: const ValueKey('backup-export'),
          onPressed: _busy ? null : _export,
          icon: const Icon(Icons.save_alt),
          label: Text(t('export')),
        ),
        OutlinedButton.icon(
          key: const ValueKey('backup-import'),
          onPressed: _busy ? null : _restore,
          icon: const Icon(Icons.restore),
          label: Text(t('import')),
        ),
        if (_busy) ...[
          LinearProgressIndicator(value: _progress?.fraction),
          if (_progress != null) Text(t(_progress!.stage)),
          TextButton(
            key: const ValueKey('backup-cancel'),
            onPressed: () => _control?.cancel(),
            child: Text(t('cancel')),
          ),
        ],
        if (last != null) ...[
          const Divider(),
          Text(
            '${t('lastBackup')} · ${formatLocalDateTime(DateTime.parse(last['at']))}',
          ),
          Text(last['location']),
          Text('${t('missingMedia')}: ${last['missing']}'),
        ],
        if (_result != null)
          SelectableText(_result!, key: const ValueKey('backup-result')),
        const Divider(),
        Text(t('cache')),
        Text(t('cacheHint')),
        TextButton(
          key: const ValueKey('backup-cache-inspect'),
          onPressed: _busy ? null : _inspectCache,
          child: Text(t('cacheCheck')),
        ),
        if (_cache != null) ...[
          Text(
            _cache!.isEmpty
                ? t('cacheEmpty')
                : '${_cache!.length} · ${_size(_cache!.fold<int>(0, (n, e) => n + e.bytes))}',
          ),
          if (_cache!.isNotEmpty)
            TextButton(
              key: const ValueKey('backup-cache-clear'),
              onPressed: _busy ? null : _clearCache,
              child: Text(t('cacheClear')),
            ),
        ],
      ],
    );
  }
}

class _RestoreBackupPasswordDialog extends StatefulWidget {
  const _RestoreBackupPasswordDialog();
  @override
  State<_RestoreBackupPasswordDialog> createState() =>
      _RestoreBackupPasswordDialogState();
}

class _RestoreBackupPasswordDialogState
    extends State<_RestoreBackupPasswordDialog> {
  final _controller = TextEditingController();
  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String t(String k) => protectionText(context, k);
    return AlertDialog(
      title: Text(t('unlock')),
      content: TextField(
        key: const ValueKey('restore-password'),
        controller: _controller,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        maxLength: 1024,
        decoration: InputDecoration(labelText: t('password')),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(t('continue')),
        ),
      ],
    );
  }
}
