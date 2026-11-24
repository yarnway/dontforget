import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/home_controller.dart';
import 'voice_capture_feedback.dart';

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
      MediaQuery.textScalerOf(context).scale(mobile ? 16 : 14) * 2.4 + 16,
    );
    final actionText = TextStyle(fontSize: mobile ? 16 : 14, height: 1.2);
    Widget field(bool compact) {
      final editor = TextField(
        key: const ValueKey('voice-text-editor'),
        controller: _editor,
        autofocus: true,
        minLines: compact || mobile ? 1 : 2,
        maxLines: null,
        readOnly: _sendingOriginal,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        cursorColor: mobile ? VoiceCaptureColors.ink : null,
        style: TextStyle(
          fontSize: compact
              ? 14
              : mobile
              ? 20
              : 18,
          height: compact ? 1.2 : 1.45,
          color: mobile ? VoiceCaptureColors.ink : colors.onPrimaryContainer,
        ),
        decoration: InputDecoration(
          hintText: l10n.get('voiceEditorPlaceholder'),
          hintStyle: mobile
              ? const TextStyle(color: VoiceCaptureColors.secondaryInk)
              : null,
          isDense: mobile,
          filled: !mobile,
          fillColor: colors.primaryContainer,
          border: mobile
              ? InputBorder.none
              : OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
          enabledBorder: mobile
              ? InputBorder.none
              : OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
          focusedBorder: mobile
              ? InputBorder.none
              : OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(color: colors.primary, width: 2),
                ),
          contentPadding: EdgeInsets.all(
            compact
                ? 4
                : mobile
                ? 20
                : 12,
          ),
        ),
        onChanged: (text) {
          setState(() => _edited = true);
          widget.onChanged(text);
        },
      );
      final accessibleEditor = Semantics(
        label: l10n.get('voiceEditTitle'),
        child: editor,
      );
      return Focus(
        key: _editorHost,
        onKeyEvent: _key,
        child: mobile
            ? VoiceTextBubble(
                child: TextSelectionTheme(
                  data: const TextSelectionThemeData(
                    cursorColor: VoiceCaptureColors.ink,
                    selectionHandleColor: VoiceCaptureColors.ink,
                    selectionColor: Color(0x55305638),
                  ),
                  child: accessibleEditor,
                ),
              )
            : accessibleEditor,
      );
    }

    return PopScope(
      canPop: !_sendingOriginal,
      child: Dialog(
        key: const ValueKey('voice-text-sheet'),
        alignment: mobile ? Alignment.bottomCenter : Alignment.center,
        backgroundColor: mobile ? Colors.transparent : null,
        surfaceTintColor: mobile ? Colors.transparent : null,
        elevation: mobile ? 0 : null,
        insetPadding: EdgeInsets.symmetric(
          horizontal: mobile && MediaQuery.sizeOf(context).width >= 360
              ? 24
              : 12,
          vertical: 12,
        ),
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
                icon: Icon(
                  Icons.close,
                  color: mobile
                      ? (_sendingOriginal ? Colors.white38 : Colors.white)
                      : null,
                ),
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
                      icon: Icon(
                        Icons.mic_rounded,
                        color: mobile
                            ? (!_sendingOriginal &&
                                      widget.onSendOriginal != null
                                  ? Colors.white
                                  : Colors.white38)
                            : null,
                      ),
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
                      style: mobile
                          ? FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF252525),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFF202020),
                              disabledForegroundColor: Colors.white38,
                            )
                          : null,
                      child: Text(
                        l10n.get('voiceSendOriginal'),
                        style: actionText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    );
              Widget send(bool iconOnly) => iconOnly
                  ? IconButton(
                      key: const ValueKey('voice-editor-send'),
                      tooltip: l10n.get('send'),
                      icon: Icon(
                        Icons.send_rounded,
                        color: mobile
                            ? (canSend ? Colors.white : Colors.white38)
                            : null,
                      ),
                      onPressed: canSend ? _send : null,
                    )
                  : FilledButton(
                      key: const ValueKey('voice-editor-send'),
                      onPressed: canSend ? _send : null,
                      style: mobile
                          ? FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFE0E0E0),
                              foregroundColor: const Color(0xFF171717),
                              disabledBackgroundColor: const Color(0xFF252525),
                              disabledForegroundColor: Colors.white38,
                            )
                          : null,
                      child: Text(
                        l10n.get('send'),
                        style: actionText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
                          padding: EdgeInsets.fromLTRB(
                            mobile ? 0 : 12,
                            4,
                            mobile ? 0 : 12,
                            4,
                          ),
                          child: Row(
                            children: [
                              if (mobile) keep(),
                              Expanded(
                                child: failed && height >= 280
                                    ? Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        child: Semantics(
                                          container: true,
                                          liveRegion: true,
                                          child: Text(
                                            l10n.get('voicePartialReview'),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: mobile
                                                  ? const Color(0xFFF2B8B5)
                                                  : colors.error,
                                            ),
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                              if (!_complete || _sendingOriginal) ...[
                                const SizedBox(width: 12),
                                Semantics(
                                  label: l10n.get(
                                    _sendingOriginal
                                        ? 'voiceSendingOriginal'
                                        : 'voiceListeningText',
                                  ),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      key: const ValueKey(
                                        'voice-editor-progress',
                                      ),
                                      strokeWidth: 2,
                                      color: mobile ? Colors.white70 : null,
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
                              if (!mobile) keep(),
                            ],
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
                              width: compact
                                  ? 48
                                  : mobile
                                  ? 0
                                  : 16,
                              child: compact ? Center(child: keep()) : null,
                            ),
                            Expanded(child: field(compact)),
                            SizedBox(
                              width: compact ? 48 : 0,
                              child: compact
                                  ? Center(child: original(true))
                                  : null,
                            ),
                            SizedBox(
                              width: compact
                                  ? 48
                                  : mobile
                                  ? 0
                                  : 16,
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
