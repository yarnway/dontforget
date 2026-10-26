import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';

class DataExportSheet extends ConsumerStatefulWidget {
  const DataExportSheet({super.key});
  @override
  ConsumerState<DataExportSheet> createState() => _DataExportSheetState();
}

class _DataExportSheetState extends ConsumerState<DataExportSheet> {
  late final RuntimeRecoveryGate _gate;
  late final RuntimeRecoveryToken? _birth;
  bool _busy = false;
  int _operation = 0, _exportCount = 0;
  String? _status, _path;
  @override
  void initState() {
    super.initState();
    _gate = ref.read(runtimeRecoveryGateProvider);
    _birth = _gate.paused ? null : _gate.capture();
  }

  bool get _current => mounted && _gate.isCurrent(_birth);
  Future<void> _save() async {
    if (_busy || !_current) return;
    final loc = AppLocalizations.of(context);
    final tasks = ref.read(remindersProvider);
    if (tasks.isEmpty) return;
    setState(() {
      _busy = true;
      _operation++;
      _exportCount = tasks.length;
      _status = null;
      _path = null;
    });
    try {
      final uri = await ref
          .read(dataExportServiceProvider)
          .saveWithDialog(
            tasks,
            locale: loc.locale.languageCode,
            title: loc.get('exportExcel'),
            isCurrent: () => _current,
          );
      if (!_current) return;
      setState(() {
        _status = uri == null ? 'exportCancelled' : 'exportSaved';
        _path = uri == null
            ? null
            : uri.scheme == 'file'
            ? uri.toFilePath()
            : uri.toString();
      });
    } catch (_) {
      if (_current) setState(() => _status = 'exportFailed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final path = _path;
    if (path == null || _busy || !_current) return;
    final operation = _operation;
    try {
      await Clipboard.setData(ClipboardData(text: path));
      if (_current && operation == _operation) {
        setState(() => _status = 'exportPathCopied');
      }
    } catch (_) {
      if (_current && operation == _operation) {
        setState(() => _status = 'exportCopyFailed');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context),
        tasks = ref.watch(remindersProvider);
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.file_download_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        loc.get('exportExcel'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: loc.get('close'),
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  loc
                      .get('exportScope')
                      .replaceAll(
                        '{count}',
                        '${_busy ? _exportCount : tasks.length}',
                      ),
                ),
                if (tasks.isEmpty) ...[
                  const SizedBox(height: 16),
                  Text(loc.get('exportEmpty')),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy || tasks.isEmpty || !_current ? null : _save,
                  icon: const Icon(Icons.save_alt),
                  label: Text(
                    loc.get(_busy ? 'exportSaving' : 'exportChooseLocation'),
                  ),
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (_status != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      loc.get(_status!).replaceAll('{count}', '$_exportCount'),
                    ),
                  ),
                ],
                if (_path != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(_path!),
                  TextButton.icon(
                    onPressed: _copy,
                    icon: const Icon(Icons.copy),
                    label: Text(loc.get('exportCopyPath')),
                  ),
                ],
                const SizedBox(height: 12),
                ExpansionTile(
                  title: Text(loc.get('exportDetails')),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    Text(loc.get('exportPrivacy')),
                    const SizedBox(height: 12),
                    Text(loc.get('exportSafety')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
