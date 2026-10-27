import 'dart:async';
import '../../providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../providers/home_controller.dart';
import '../../models/settings.dart';
import '../../l10n/app_localizations.dart';
import 'editable_text_menu.dart';
import 'voice_capture_feedback.dart';

class InputBottomBar extends ConsumerStatefulWidget {
  const InputBottomBar({super.key});

  @override
  ConsumerState<InputBottomBar> createState() => _InputBottomBarState();
}

class _InputBottomBarState extends ConsumerState<InputBottomBar> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  bool _isLongPressRecording = false;
  Future<bool>? _pendingRecordingStart;
  bool _isFinishingLongPress = false;
  bool _wasEmpty = true;
  bool _wasFocused = false;
  Offset _voiceOrigin = Offset.zero;
  VoiceReleaseAction _voiceAction = VoiceReleaseAction.save;
  bool _isTranscribing = false;
  HomeController? _heldRecorder;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_inputChanged);
    _textController.addListener(_inputChanged);
  }

  void _inputChanged() {
    final empty = _textController.text.isEmpty;
    final focused = _focusNode.hasFocus;
    if (empty == _wasEmpty && focused == _wasFocused) return;
    _wasEmpty = empty;
    _wasFocused = focused;
    setState(() {});
  }

  @override
  void dispose() {
    final pending = _pendingRecordingStart;
    final controller = _heldRecorder;
    if (pending != null && controller != null && !_isFinishingLongPress) {
      // Discard this capture if permission finishes after the input is removed.
      unawaited(
        pending
            .then((started) async {
              if (started) await controller.cancelRecording();
            })
            .catchError((Object _) {}),
      );
    }
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submitText() {
    final composing = _textController.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    final text = _textController.text;
    if (text.trim().isEmpty) return;
    _textController.clear();
    ref.read(homeControllerProvider.notifier).processText(text);
  }

  void _restoreFailedText(FailedTextDraft draft) {
    final composing = _textController.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).get('failedInputComposing'),
          ),
        ),
      );
      return;
    }
    final current = _textController.text;
    final text = current.isEmpty ? draft.text : '$current\n${draft.text}';
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    ref.read(homeControllerProvider.notifier).dismissFailedText(draft.id);
    _focusNode.requestFocus();
  }

  void _insertLineBreak() {
    final value = _textController.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _textController.value = TextEditingValue(
      text: value.text.replaceRange(start, end, '\n'),
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  void _openEmptyEditMenu() {
    _focusNode.requestFocus();
    // The empty, unfocused surface owns the hold-to-record gesture. A secondary
    // click instead enters text editing before asking the editor for its menu.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_focusNode.hasFocus) return;
      final editor = _focusNode.context
          ?.findAncestorStateOfType<EditableTextState>();
      if (editor == null) return;
      await editor.clipboardStatus.update();
      if (mounted && editor.mounted && _focusNode.hasFocus) {
        editor.showToolbar();
      }
    });
  }

  Future<void> _startLongPressRecording(LongPressStartDetails details) async {
    if (_textController.text.isNotEmpty ||
        _isTranscribing ||
        _pendingRecordingStart != null ||
        ref.read(homeControllerProvider).isRecording) {
      return;
    }
    _focusNode.unfocus();
    HapticFeedback.heavyImpact();
    setState(() {
      _voiceOrigin = details.globalPosition;
      _voiceAction = VoiceReleaseAction.save;
      _isLongPressRecording = true;
    });
    final controller = ref.read(homeControllerProvider.notifier);
    _heldRecorder = controller;
    final operation = controller.startRecording();
    _pendingRecordingStart = operation;
    final started = await operation;
    if (mounted && !started) setState(() => _isLongPressRecording = false);
  }

  Future<void> _finishLongPressRecording() async {
    final operation = _pendingRecordingStart;
    if (!mounted || operation == null || _isFinishingLongPress) return;
    _isFinishingLongPress = true;
    final controller = ref.read(homeControllerProvider.notifier);
    final action = _voiceAction;
    HapticFeedback.mediumImpact();
    setState(() {
      _isLongPressRecording = false;
      _isTranscribing = action == VoiceReleaseAction.text;
    });
    // Permission or native startup may finish after the user releases their press.
    // Wait for that same start before stopping, so a late start cannot keep recording.
    try {
      if (await operation) {
        switch (action) {
          case VoiceReleaseAction.cancel:
            await controller.cancelRecording();
          case VoiceReleaseAction.save:
            await controller.stopRecordingAndProcess();
          case VoiceReleaseAction.text:
            final text = await controller.stopRecordingToText(
              canAcceptDraft: () => mounted,
            );
            if (mounted && text != null) {
              final current = _textController.text;
              final draft = current.isEmpty ? text : '$current\n$text';
              _textController.value = TextEditingValue(
                text: draft,
                selection: TextSelection.collapsed(offset: draft.length),
              );
              _focusNode.requestFocus();
            }
        }
      }
    } finally {
      if (mounted && identical(_pendingRecordingStart, operation)) {
        setState(() {
          _pendingRecordingStart = null;
          _isFinishingLongPress = false;
          _isTranscribing = false;
          _heldRecorder = null;
        });
      }
    }
  }

  void _moveLongPress(LongPressMoveUpdateDetails details) {
    if (!_isLongPressRecording || _isFinishingLongPress) return;
    final action = voiceReleaseAction(details.globalPosition - _voiceOrigin);
    if (action == _voiceAction) return;
    HapticFeedback.selectionClick();
    setState(() => _voiceAction = action);
  }

  void _cancelLongPress() {
    _voiceAction = VoiceReleaseAction.cancel;
    _finishLongPressRecording();
  }

  void _showMediaOptionsSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (sheetCtx) {
        final controller = ref.read(homeControllerProvider.notifier);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 3,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  l10n.get('uploadMaterial'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.get('uploadMaterialDesc'),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _buildMediaOption(
                      icon: Icons.camera_alt_outlined,
                      color: Colors.blue.shade600,
                      label: l10n.get('takePhoto'),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processImageWithSource(ImageSource.camera);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.photo_library_outlined,
                      color: Colors.purple.shade500,
                      label: l10n.get('galleryPhoto'),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processImageWithSource(ImageSource.gallery);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.snippet_folder_outlined,
                      color: Colors.amber.shade700,
                      label: l10n.get('importFile'),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processFile();
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.video_collection_outlined,
                      color: Colors.redAccent,
                      label: l10n.get('uploadVideo'),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        controller.processVideo();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMediaOption({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final homeState = ref.watch(homeControllerProvider);
    final enterSends = ref.watch(
      settingsProvider.select((s) => s.inputSendMode == InputSendMode.enter),
    );
    final isLocalMode = ref.watch(
      settingsProvider.select((s) => !s.hasConfiguredExtraction),
    );
    final isRecording = homeState.isRecording || _isLongPressRecording;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final idleVoiceTarget =
        _textController.text.isEmpty &&
        !_focusNode.hasFocus &&
        !_isTranscribing;
    // Scaffold removes the consumed inset from its body MediaQuery while the
    // keyboard animates away, so also read the containing view's physical inset.
    final keyboardVisible =
        MediaQuery.viewInsetsOf(context).bottom > 0 ||
        View.of(context).viewInsets.bottom > 0;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isRecording
                ? Colors.red.withValues(alpha: 0.6)
                : Theme.of(context).colorScheme.outlineVariant,
            width: 1.0,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (homeState.failedTextDrafts.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: Column(
                      key: const ValueKey('failed-text-drafts'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${l10n.get('failedInputTitle')} (${homeState.failedTextDrafts.length})',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        Text(l10n.get('failedInputHint')),
                        Text(
                          homeState.failedTextDrafts.first.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Wrap(
                          spacing: 4,
                          children: [
                            TextButton(
                              key: const ValueKey('restore-failed-input'),
                              onPressed: isRecording || _isTranscribing
                                  ? null
                                  : () => _restoreFailedText(
                                      homeState.failedTextDrafts.first,
                                    ),
                              child: Text(l10n.get('failedInputRestore')),
                            ),
                            TextButton(
                              key: const ValueKey('copy-failed-input'),
                              onPressed: () async {
                                final draft = homeState.failedTextDrafts.first;
                                try {
                                  await Clipboard.setData(
                                    ClipboardData(text: draft.text),
                                  );
                                  if (context.mounted) {
                                    ScaffoldMessenger.maybeOf(
                                      context,
                                    )?.showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          l10n.get('failedInputCopied'),
                                        ),
                                      ),
                                    );
                                  }
                                } catch (_) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.maybeOf(
                                      context,
                                    )?.showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          l10n.get('failedInputCopyFailed'),
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                              child: Text(l10n.get('failedInputCopy')),
                            ),
                            TextButton(
                              key: const ValueKey('discard-failed-input'),
                              onPressed: () => ref
                                  .read(homeControllerProvider.notifier)
                                  .dismissFailedText(
                                    homeState.failedTextDrafts.first.id,
                                  ),
                              child: Text(l10n.get('failedInputDiscard')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_isLongPressRecording && !keyboardVisible)
              VoiceCaptureFeedback(action: _voiceAction),
            Row(
              children: [
                // Left '+' Add button
                IconButton(
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
                  color: Theme.of(context).colorScheme.primary,
                  tooltip: l10n.get('uploadMaterial'),
                  splashRadius: 18,
                  onPressed: () => _showMediaOptionsSheet(context),
                ),

                // Mic toggle button (for desktop click or single tap)
                _RecordingPulse(
                  active: isRecording,
                  child: IconButton(
                    icon: Icon(
                      isRecording
                          ? Icons.stop_circle_rounded
                          : Icons.mic_none_rounded,
                      color: isRecording
                          ? Colors.red
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                    tooltip: isRecording
                        ? l10n.get('recordingClickStop')
                        : l10n.get('recordingStart'),
                    onPressed: _pendingRecordingStart != null
                        ? null
                        : () => ref
                              .read(homeControllerProvider.notifier)
                              .toggleRecording(),
                  ),
                ),

                const SizedBox(width: 4),

                // Center Input Area: Single tap to type, Long press to speak
                Expanded(
                  child: GestureDetector(
                    key: const ValueKey('composer-input-surface'),
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      if (!isRecording &&
                          !_isTranscribing &&
                          !_focusNode.hasFocus) {
                        _focusNode.requestFocus();
                      }
                    },
                    onLongPressStart: idleVoiceTarget
                        ? _startLongPressRecording
                        : null,
                    onLongPressMoveUpdate: idleVoiceTarget
                        ? _moveLongPress
                        : null,
                    onLongPressEnd: idleVoiceTarget
                        ? (_) => _finishLongPressRecording()
                        : null,
                    onLongPressCancel: idleVoiceTarget
                        ? _cancelLongPress
                        : null,
                    onSecondaryTapDown: idleVoiceTarget
                        ? (_) => _openEmptyEditMenu()
                        : null,
                    child: isRecording || _isTranscribing
                        ? Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  l10n.get(
                                    _isTranscribing
                                        ? 'voiceTranscribing'
                                        : _isLongPressRecording
                                        ? !homeState.isRecording
                                              ? 'voicePreparing'
                                              : switch (_voiceAction) {
                                                  VoiceReleaseAction.save =>
                                                    'voiceReleaseSave',
                                                  VoiceReleaseAction.cancel =>
                                                    'voiceReleaseCancel',
                                                  VoiceReleaseAction.text =>
                                                    'voiceReleaseText',
                                                }
                                        : 'recordingClickStop',
                                  ),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.red.shade700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          )
                        // iOS TextField's selection recognizer otherwise wins the
                        // gesture arena before our hold-to-record recognizer. Only
                        // the empty, unfocused surface delegates pointer gestures;
                        // typing, selection and IME retain normal TextField behavior.
                        : IgnorePointer(
                            ignoring: idleVoiceTarget,
                            child: CallbackShortcuts(
                              bindings: {
                                const SingleActivator(LogicalKeyboardKey.enter):
                                    enterSends ? _submitText : _insertLineBreak,
                                const SingleActivator(
                                  LogicalKeyboardKey.numpadEnter,
                                ): enterSends
                                    ? _submitText
                                    : _insertLineBreak,
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                  shift: true,
                                ): _insertLineBreak,
                                const SingleActivator(
                                  LogicalKeyboardKey.numpadEnter,
                                  shift: true,
                                ): _insertLineBreak,
                              },
                              child: TextField(
                                controller: _textController,
                                focusNode: _focusNode,
                                contextMenuBuilder: buildEditableTextMenu,
                                minLines: 1,
                                maxLines: 4,
                                keyboardType: TextInputType.multiline,
                                textInputAction: enterSends
                                    ? TextInputAction.send
                                    : TextInputAction.newline,
                                style: const TextStyle(fontSize: 13),
                                decoration: InputDecoration(
                                  hintText: l10n.get(
                                    _focusNode.hasFocus
                                        ? 'inputTypingHint'
                                        : isLocalMode
                                        ? 'localInputHint'
                                        : 'inputHint',
                                  ),
                                  hintMaxLines: 2,
                                  hintStyle: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade500,
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 8,
                                  ),
                                ),
                                onSubmitted: enterSends
                                    ? (_) => _submitText()
                                    : null,
                              ),
                            ),
                          ),
                  ),
                ),

                // Background Processing capsule (Wireframe)
                if (homeState.isProcessingInBackground && !_isTranscribing)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.4),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 9,
                          height: 9,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          homeState.pendingTasksCount > 1
                              ? 'AI (${homeState.pendingTasksCount})'
                              : 'AI...',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Right Send button (Wireframe)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _textController,
                    builder: (context, value, _) => IconButton(
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onPrimary,
                        padding: const EdgeInsets.all(5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      tooltip: l10n.get('send'),
                      onPressed:
                          value.text.trim().isEmpty ||
                              isRecording ||
                              _isTranscribing
                          ? null
                          : _submitText,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Keep the microphone still when idle, hidden, or reduced motion is requested.
/// Passing the button as [child] also keeps animation ticks out of its subtree.
class _RecordingPulse extends StatefulWidget {
  const _RecordingPulse({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_RecordingPulse> createState() => _RecordingPulseState();
}

class _RecordingPulseState extends State<_RecordingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _RecordingPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    final shouldAnimate =
        widget.active &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) => DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: widget.active && _controller.isAnimating
            ? [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.4 * _controller.value),
                  blurRadius: 8 * _controller.value,
                  spreadRadius: 2 * _controller.value,
                ),
              ]
            : const [],
      ),
      child: child,
    ),
  );
}
