import 'dart:async';
import 'dart:math' as math;
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
    this.onSendOriginal,
  });
  final Future<String?> result;
  final String prefix, initial;
  final ValueChanged<String> onChanged;
  final Future<bool> Function()? onSendOriginal;
  @override
  ConsumerState<LiveVoiceTextDialog> createState() =>
      _LiveVoiceTextDialogState();
}

class _LiveVoiceTextDialogState extends ConsumerState<LiveVoiceTextDialog> {
  late final TextEditingController _editor;
  final _editorHost = GlobalKey();
  bool _edited = false, _complete = false, _failed = false, _closing = false;
  bool _sendingOriginal = false;
  String combine(String text) => widget.prefix.isEmpty
      ? text
      : text.isEmpty
      ? widget.prefix
      : '${widget.prefix}\n$text';
  void _refreshEditorState() {
    if (mounted && !_closing) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _editor = TextEditingController(text: combine(widget.initial));
    _editor.addListener(_refreshEditorState);
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
    if (_sendingOriginal || _editor.text == value) return;
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

  Future<void> _sendOriginal() async {
    if (_sendingOriginal || _closing || widget.onSendOriginal == null) return;
    setState(() => _sendingOriginal = true);
    var sent = false;
    try {
      sent = await widget.onSendOriginal!();
    } catch (_) {
      // Keep this recording and editor available for another attempt.
    }
    if (!mounted) return;
    if (sent) {
      _closing = true;
      Navigator.pop(context, false);
    } else {
      setState(() => _sendingOriginal = false);
    }
  }

  void _send() {
    if (_sendingOriginal || _closing) return;
    final composing = _editor.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    _closing = true;
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _editor.removeListener(_refreshEditorState);
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
    final composing = _editor.value.composing;
    final canSend =
        !_sendingOriginal &&
        _editor.text.trim().isNotEmpty &&
        (!composing.isValid || composing.isCollapsed);
    final colors = Theme.of(context).colorScheme;
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final actionHeight = math.max(
      48.0,
      MediaQuery.textScalerOf(context).scale(14) * 2.4 + 16,
    );
    const actionText = TextStyle(fontSize: 14, height: 1.2);
    Widget field(bool compact) => Focus(
      key: _editorHost,
      onKeyEvent: _key,
      child: TextField(
        key: const ValueKey('voice-text-editor'),
        controller: _editor,
        autofocus: true,
        minLines: compact ? 1 : 2,
        maxLines: null,
        readOnly: _sendingOriginal,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        style: TextStyle(
          fontSize: compact ? 14 : 18,
          height: compact ? 1.2 : 1.45,
          color: colors.onPrimaryContainer,
        ),
        decoration: InputDecoration(
          hintText: l10n.get('voiceEditorPlaceholder'),
          filled: true,
          fillColor: colors.primaryContainer,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: colors.primary, width: 2),
          ),
          contentPadding: EdgeInsets.all(compact ? 4 : 12),
        ),
        onChanged: (text) {
          setState(() => _edited = true);
          widget.onChanged(text);
        },
      ),
    );
    return PopScope(
      canPop: !_sendingOriginal,
      child: Dialog(
        key: const ValueKey('voice-text-sheet'),
        alignment: mobile ? Alignment.bottomCenter : Alignment.center,
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: LayoutBuilder(
            builder: (context, bounds) {
              final height = math.min(520.0, bounds.maxHeight);
              final compact =
                  height <
                  math.max(
                    180.0,
                    MediaQuery.textScalerOf(context).scale(18) * 2.85 +
                        actionHeight +
                        72,
                  );
              Widget keep() => IconButton(
                key: const ValueKey('voice-editor-keep'),
                tooltip: l10n.get('voiceKeepDraft'),
                icon: const Icon(Icons.close),
                visualDensity: VisualDensity.compact,
                onPressed: _sendingOriginal
                    ? null
                    : () {
                        _closing = true;
                        Navigator.pop(context, false);
                      },
              );
              Widget original(bool iconOnly) => iconOnly
                  ? IconButton(
                      key: const ValueKey('voice-editor-original'),
                      tooltip: l10n.get('voiceSendOriginal'),
                      icon: const Icon(Icons.mic_rounded),
                      visualDensity: VisualDensity.compact,
                      onPressed:
                          !_sendingOriginal && widget.onSendOriginal != null
                          ? _sendOriginal
                          : null,
                    )
                  : FilledButton.tonal(
                      key: const ValueKey('voice-editor-original'),
                      onPressed:
                          !_sendingOriginal && widget.onSendOriginal != null
                          ? _sendOriginal
                          : null,
                      child: Text(
                        l10n.get('voiceSendOriginal'),
                        style: actionText,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                      ),
                    );
              Widget send(bool iconOnly) => iconOnly
                  ? IconButton(
                      key: const ValueKey('voice-editor-send'),
                      tooltip: l10n.get('send'),
                      icon: const Icon(Icons.send_rounded),
                      visualDensity: VisualDensity.compact,
                      onPressed: canSend ? _send : null,
                    )
                  : FilledButton(
                      key: const ValueKey('voice-editor-send'),
                      onPressed: canSend ? _send : null,
                      child: Text(
                        l10n.get('send'),
                        style: actionText,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                      ),
                    );
              return ConstrainedBox(
                constraints: BoxConstraints(maxHeight: height),
                child: SizedBox(
                  width: 560,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!compact)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                          child: Row(
                            children: [
                              Icon(
                                failed
                                    ? Icons.warning_amber_rounded
                                    : Icons.edit_note_rounded,
                                color: failed ? colors.error : colors.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  l10n.get(
                                    failed
                                        ? 'voiceReviewTitle'
                                        : 'voiceEditTitle',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              if (!_complete || _sendingOriginal) ...[
                                const SizedBox(width: 12),
                                Semantics(
                                  label: l10n.get('voiceListeningText'),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      key: const ValueKey(
                                        'voice-editor-progress',
                                      ),
                                      strokeWidth: 2,
                                      value:
                                          MediaQuery.disableAnimationsOf(
                                            context,
                                          )
                                          ? .5
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(width: 4),
                              keep(),
                            ],
                          ),
                        ),
                      if (!compact &&
                          failed &&
                          height >= 360 &&
                          MediaQuery.textScalerOf(context).scale(14) <= 22)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Text(
                            l10n.get('voicePartialReview'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.error),
                          ),
                        ),
                      // This keyed slot and its editor never change parents when the
                      // keyboard opens or the device rotates: keep the IME client.
                      Flexible(
                        key: const ValueKey('voice-sheet-field-slot'),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: compact ? 44 : 16,
                              child: compact ? Center(child: keep()) : null,
                            ),
                            Expanded(child: field(compact)),
                            SizedBox(
                              width: compact ? 44 : 0,
                              child: compact
                                  ? Center(child: original(true))
                                  : null,
                            ),
                            SizedBox(
                              width: compact ? 44 : 16,
                              child: compact ? Center(child: send(true)) : null,
                            ),
                          ],
                        ),
                      ),
                      if (!compact)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SizedBox(
                            height: actionHeight,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: original(false)),
                                const SizedBox(width: 12),
                                Expanded(child: send(false)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
