import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import 'editor_keyboard_actions.dart';

/// A route owns its draft until a successful write or an explicit discard.
class UnsavedEditorScope extends StatefulWidget {
  const UnsavedEditorScope({
    super.key,
    required this.dirty,
    required this.busy,
    required this.onSave,
    required this.builder,
    this.savedResult,
  });
  final bool dirty, busy;
  final Future<bool> Function() onSave;
  final Object? savedResult;
  final Widget Function(BuildContext, VoidCallback save, VoidCallback exit)
  builder;

  @override
  State<UnsavedEditorScope> createState() => _UnsavedEditorScopeState();
}

class _UnsavedEditorScopeState extends State<UnsavedEditorScope> {
  bool _allowPop = false, _saving = false, _confirming = false;

  void _finish([Object? result]) {
    if (!mounted || _allowPop) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(result);
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _confirming || widget.busy || _allowPop) return;
    setState(() => _saving = true);
    try {
      if (await widget.onSave() && mounted) _finish(widget.savedResult);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _exit() async {
    if (_saving || _confirming || widget.busy || _allowPop) return;
    if (!widget.dirty) {
      _finish();
      return;
    }
    _confirming = true;
    final t = AppLocalizations.of(context).get;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('unsavedChangesTitle')),
        content: Text(t('unsavedChangesMessage')),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, 'keep'),
            child: Text(t('keepEditing')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: Text(t('discardChanges')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(t('saveAndLeave')),
          ),
        ],
      ),
    );
    _confirming = false;
    if (!mounted) return;
    if (choice == 'discard') _finish();
    if (choice == 'save') await _save();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: _allowPop || (!widget.dirty && !widget.busy && !_saving),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _exit();
    },
    child: EditorKeyboardActions(
      onSave: _save,
      onExit: _exit,
      child: AbsorbPointer(
        absorbing: widget.busy || _saving,
        child: ExcludeFocus(
          excluding: widget.busy || _saving,
          child: widget.builder(context, _save, _exit),
        ),
      ),
    ),
  );
}
