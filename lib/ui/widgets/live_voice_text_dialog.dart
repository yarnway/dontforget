import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/home_controller.dart';

/// The user can edit immediately while recognition finishes. Once edited,
/// remote partial/final updates cannot replace their text.
class LiveVoiceTextDialog extends ConsumerStatefulWidget {
  const LiveVoiceTextDialog({
    super.key,
    required this.result,
    required this.prefix,
    required this.initial,
    required this.onChanged,
  });
  final Future<String?> result;
  final String prefix, initial;
  final ValueChanged<String> onChanged;
  @override
  ConsumerState<LiveVoiceTextDialog> createState() =>
      _LiveVoiceTextDialogState();
}

class _LiveVoiceTextDialogState extends ConsumerState<LiveVoiceTextDialog> {
  late final TextEditingController _editor;
  bool _edited = false, _complete = false, _failed = false, _closing = false;
  String combine(String text) => widget.prefix.isEmpty
      ? text
      : text.isEmpty
      ? widget.prefix
      : '${widget.prefix}\n$text';
  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(text: combine(widget.initial));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(_editor.text);
    });
    unawaited(
      widget.result.then(
        (text) {
          if (!mounted ||
              _closing ||
              ModalRoute.of(context)?.isCurrent == false) {
            return;
          }
          if (text != null && !_edited) _apply(text);
          setState(() {
            _complete = true;
            _failed = text == null;
          });
        },
        onError: (Object _, StackTrace __) {
          if (mounted) {
            setState(() {
              _complete = true;
              _failed = true;
            });
          }
        },
      ),
    );
  }

  void _apply(String text) {
    final value = combine(text);
    if (_editor.text == value) return;
    final composing = _editor.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _edited = true;
      return;
    }
    _editor.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged(value);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final value = _editor.value;
    if (value.composing.isValid && !value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final selection = value.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, value.text.length)
        : value.text.length;
    final end = selection.isValid
        ? selection.end.clamp(0, value.text.length)
        : value.text.length;
    final text = value.text.replaceRange(start, end, '\n');
    _editor.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + 1),
    );
    setState(() => _edited = true);
    widget.onChanged(text);
    return KeyEventResult.handled;
  }

  void _send() {
    final composing = _editor.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    _closing = true;
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(
      homeControllerProvider.select((state) => state.voicePreview),
      (_, text) {
        if (!_closing &&
            !_edited &&
            !_complete &&
            ModalRoute.of(context)?.isCurrent != false) {
          _apply(text);
        }
      },
    );
    final l10n = AppLocalizations.of(context);
    final failed =
        _failed ||
        ref.watch(homeControllerProvider.select((state) => state.error)) !=
            null;
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.get('voiceEditTitle')),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_complete)
              LinearProgressIndicator(
                key: const ValueKey('voice-editor-progress'),
                value: MediaQuery.disableAnimationsOf(context) ? 0.5 : null,
              ),
            if (failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  l10n.get('voicePartialReview'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            SizedBox(
              height: (MediaQuery.sizeOf(context).height * .25).clamp(100, 240),
              child: Focus(
                onKeyEvent: _key,
                child: TextField(
                  key: const ValueKey('voice-text-editor'),
                  controller: _editor,
                  autofocus: true,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  onChanged: (text) {
                    setState(() => _edited = true);
                    widget.onChanged(text);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('voice-editor-keep'),
          onPressed: () {
            _closing = true;
            Navigator.pop(context, false);
          },
          child: Text(l10n.get('voiceKeepDraft')),
        ),
        FilledButton(
          key: const ValueKey('voice-editor-send'),
          onPressed: _editor.text.trim().isNotEmpty && (_complete || _edited)
              ? _send
              : null,
          child: Text(l10n.get('send')),
        ),
      ],
    );
  }
}
