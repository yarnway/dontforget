import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/shared_text_strings.dart';
import '../../providers/providers.dart';
import '../../providers/home_controller.dart';
import '../../providers/shared_text_provider.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/shared_text_inbox.dart';
import '../../services/recovery/runtime_gate.dart';

void openSharedTextInbox(BuildContext context, WidgetRef ref) {
  final command = ref.read(sharedTextInboxCommandProvider).open;
  if (command != null) {
    command();
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/shared-drafts'),
      builder: (_) => const SharedTextInboxScreen(),
    ),
  );
}

class SharedTextInboxScreen extends ConsumerWidget {
  const SharedTextInboxScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String t(String key) =>
        sharedTextLabel(AppLocalizations.of(context).locale.languageCode, key);
    final workspace = ref.watch(workspaceDraftsProvider);
    final drafts = ref.read(workspaceDraftsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: Text(t('title'))),
      body: FutureBuilder<void>(
        future: drafts.ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text(t('readFailed')));
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          late SharedTextInboxData data;
          try {
            data = SharedTextInboxData.parse(workspace[SharedTextInbox.key]);
          } catch (_) {
            return Center(child: Text(t('readFailed')));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(t('hint')),
              const SizedBox(height: 16),
              if (data.items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(t('empty')),
                ),
              for (final item in data.items)
                Card.outlined(
                  key: ValueKey('shared-item-${item.id}'),
                  child: ListTile(
                    title: Text(
                      item.text.trim().isEmpty ? t('emptyDraft') : item.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _SharedTextEditor(item: item),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SharedTextEditor extends ConsumerStatefulWidget {
  const _SharedTextEditor({required this.item});
  final SharedText item;
  @override
  ConsumerState<_SharedTextEditor> createState() => _SharedTextEditorState();
}

class _SharedTextEditorState extends ConsumerState<_SharedTextEditor>
    with WidgetsBindingObserver {
  late final TextEditingController _text;
  late final SharedTextInbox _inbox;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  late String _committed;
  Timer? _debounce;
  Future<void> _write = Future.value();
  bool _busy = false,
      _closing = false,
      _writing = false,
      _failed = false,
      _allowPop = false;
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      _inbox.drafts.database.isCurrent(_inbox.drafts.generation);
  bool get _dirty => _text.text != _committed;
  String t(String key) =>
      sharedTextLabel(AppLocalizations.of(context).locale.languageCode, key);
  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.item.text);
    _committed = widget.item.text;
    _inbox = ref.read(sharedTextInboxProvider);
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persist().catchError((Object _) {}));
    });
  }

  Future<void> _persist() {
    _debounce?.cancel();
    final text = _text.text;
    final previous = _write;
    late Future<void> operation;
    operation = previous.catchError((Object _) {}).then((_) async {
      if (!_current) throw StateError('Shared editor expired');
      if (text != _committed) {
        await _inbox.edit(widget.item.id, _committed, text);
        if (!_current) throw StateError('Shared editor expired');
        _committed = text;
      }
    });
    _write = operation;
    if (mounted) setState(() => _writing = true);
    operation.then(
      (_) {
        if (_current && identical(operation, _write)) {
          setState(() {
            _writing = false;
            _failed = false;
          });
        }
      },
      onError: (Object _) {
        if (_current && identical(operation, _write)) {
          setState(() {
            _writing = false;
            _failed = true;
          });
        }
      },
    );
    return operation;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _current && !_busy && !_closing) {
      unawaited(_persist().catchError((Object _) {}));
    }
  }

  Future<void> _pop() async {
    if (!_current) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && _current) Navigator.of(context).pop();
  }

  Future<void> _close() async {
    if (!_current || _busy || _closing) return;
    setState(() => _closing = true);
    try {
      await _persist();
      await _pop();
    } catch (_) {
      if (!mounted || !_current) return;
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('failed')),
          content: Text(t('discardHint')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t('continue')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(t('discard')),
            ),
          ],
        ),
      );
      if (_current && discard == true) await _pop();
    } finally {
      if (_current) setState(() => _closing = false);
    }
  }

  Future<void> _save({required bool alreadySaved}) async {
    if (!_current ||
        _busy ||
        _closing ||
        (!alreadySaved && _text.text.trim().isEmpty)) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _persist();
      if (!_current) return;
      final saved =
          alreadySaved ||
          await ref
              .read(homeControllerProvider.notifier)
              .processText(
                _text.text,
                memoOnly: true,
                captureId: widget.item.id,
              );
      if (!saved || !_current) throw StateError('Shared memo not committed');
      await _inbox.remove(widget.item.id, _committed);
      if (_current) await _pop();
    } catch (_) {
      if (_current) setState(() => _failed = true);
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (!_current || _busy || _closing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('deleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('delete')),
          ),
        ],
      ),
    );
    if (!_current || confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _persist();
      await _inbox.remove(widget.item.id, _committed);
      if (_current) await _pop();
    } catch (_) {
      if (_current) setState(() => _failed = true);
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final alreadySaved = ref
        .watch(remindersProvider)
        .any((row) => row.id == widget.item.id);
    return PopScope(
      canPop:
          _allowPop ||
          (!_dirty && !_writing && !_busy && !_closing && !_failed),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('title')),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _busy || _closing ? null : _close,
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(t(alreadySaved ? 'saved' : 'hint')),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('shared-text-editor'),
              controller: _text,
              enabled: !_busy && !_closing,
              readOnly: alreadySaved,
              minLines: 5,
              maxLines: 16,
              maxLength: SharedText.maxTextLength,
              onChanged: _changed,
            ),
            if (_failed) ...[
              Text(
                t('failed'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: _busy || _closing
                    ? null
                    : () {
                        unawaited(_persist().catchError((Object _) {}));
                      },
                child: Text(t('retry')),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const ValueKey('shared-save-memo'),
              onPressed:
                  _busy ||
                      _closing ||
                      (!alreadySaved && _text.text.trim().isEmpty)
                  ? null
                  : () => _save(alreadySaved: alreadySaved),
              icon: const Icon(Icons.note_add_outlined),
              label: Text(t(alreadySaved ? 'done' : 'save')),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy || _closing ? null : _delete,
              child: Text(t('delete')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    super.dispose();
  }
}
