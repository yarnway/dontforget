import 'dart:async';
import '../../services/recovery/runtime_gate.dart';
import 'package:uuid/uuid.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/quick_reminder_parser.dart';
import '../formatters/local_date_time.dart';
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
  Offset _voiceOrigin = Offset.zero;
  final _voiceGesture = VoiceCaptureGesture();
  VoiceReleaseAction _voiceAction = VoiceReleaseAction.save;
  bool _isTranscribing = false;
  bool _voiceMode = false;
  bool _voiceTextDraft = false;
  final _capturePortal = OverlayPortalController();
  bool _captureOverlayWanted = false;
  HomeController? _heldRecorder;
  DateTime? _quickTime;
  bool _memoOnly = false, _submitting = false, _restoring = false;
  bool _draftTouched = false, _draftSaveFailed = false;
  bool _resolvingPending = false;
  int _draftRevision = 0;
  String _captureId = const Uuid().v4();
  String _lastText = '';
  late final WorkspaceDrafts _draftStore;
  late final RuntimeRecoveryGate _inputRuntime;
  late final RuntimeRecoveryToken? _inputBirth;
  bool get _current => mounted && _inputRuntime.isCurrent(_inputBirth);
  bool _lastFocused = false;

  @override
  void initState() {
    super.initState();
    _inputRuntime = ref.read(runtimeRecoveryGateProvider);
    _inputBirth = _inputRuntime.paused ? null : _inputRuntime.capture();
    _draftStore = ref.read(workspaceDraftsProvider.notifier);
    _focusNode.addListener(_inputChanged);
    _textController.addListener(_inputChanged);
    unawaited(_restoreDraft());
  }

  Future<void> _restoreDraft() async {
    try {
      final store = _draftStore;
      if (!store.loaded) await store.ready;
      if (!_current || _draftTouched) return;
      final draft = ref.read(workspaceDraftsProvider)['capture'];
      if (draft is! Map || draft['text'] is! String) return;
      _restoring = true;
      _quickTime = DateTime.tryParse(draft['time']?.toString() ?? '');
      _memoOnly = draft['memo'] == true;
      _voiceTextDraft = draft['voiceText'] == true;
      _captureId = draft['id'] is String ? draft['id'] as String : _captureId;
      _textController.text = draft['text'] as String;
      _restoring = false;
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _draftSaveFailed = true);
    }
  }

  void _persistDraft() {
    if (_restoring || !_current) return;
    _draftTouched = true;
    final text = _textController.text;
    final value = text.isEmpty && _quickTime == null && !_memoOnly
        ? null
        : {
            'text': text,
            'time': _quickTime?.toIso8601String(),
            'memo': _memoOnly,
            if (_voiceTextDraft) 'voiceText': true,
            'id': _captureId,
          };
    unawaited(
      _draftStore
          .put('capture', value)
          .then(
            (_) {
              if (mounted && _draftSaveFailed) {
                setState(() => _draftSaveFailed = false);
              }
            },
            onError: (Object _) {
              if (mounted) setState(() => _draftSaveFailed = true);
            },
          ),
    );
  }

  void _inputChanged() {
    final text = _textController.text;
    final focused = _focusNode.hasFocus;
    if (text == _lastText && focused == _lastFocused) return;
    if (text.isEmpty) _voiceTextDraft = false;
    if (!_restoring && text != _lastText) {
      _draftRevision++;
      // An edited draft must not reuse an ID that may already have committed.
      _captureId = const Uuid().v4();
      _persistDraft();
    }

    _lastText = text;
    _lastFocused = focused;
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

  Future<void> _submitText() async {
    if (_submitting || _resolvingPending || !_current) return;
    final composing = _textController.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    final text = _textController.text;
    if (text.trim().isEmpty) return;
    final id = _captureId;
    final revision = _draftRevision;
    final time = _quickTime;
    final memo = _memoOnly;
    final voiceText = _voiceTextDraft;
    setState(() {
      _submitting = true;
    });
    bool saved = false;
    try {
      await _updatePending(id, {
        'text': text,
        'id': id,
        'time': time?.toIso8601String(),
        'memo': memo,
        if (voiceText) 'voiceText': true,
      });
      if (!_current) return;
      saved = await ref
          .read(homeControllerProvider.notifier)
          .processText(text, reminderTime: time, memoOnly: memo, captureId: id);
    } catch (_) {
      if (mounted) setState(() => _draftSaveFailed = true);
    }
    if (!_current) return;
    if (saved && _draftRevision == revision && _captureId == id) {
      _restoring = true;
      _textController.clear();
      _quickTime = null;
      _memoOnly = false;
      _captureId = const Uuid().v4();
      _restoring = false;
      _persistDraft();
    }
    if (saved) {
      try {
        final store = _draftStore;
        await store.flushed;
        if (!_current || store.failed) throw StateError('Draft save failed');
        await _updatePending(id, null);
      } catch (_) {
        if (mounted) setState(() => _draftSaveFailed = true);
      }
    }
    if (mounted) {
      setState(() {
        _submitting = false;
      });
    }
  }

  Future<void> _updatePending(String id, Map<String, Object?>? value) async {
    if (!_current) throw StateError('Capture is no longer current');
    final store = _draftStore;
    await store.ready;
    await store.flushed;
    if (!_current || store.failed) throw StateError('Draft save failed');
    final raw = ref.read(workspaceDraftsProvider)['pendingCaptures'];
    if (raw != null && raw is! Map) {
      throw const FormatException('Invalid drafts');
    }
    final pending = raw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(raw as Map);
    if (value == null) {
      pending.remove(id);
    } else {
      pending[id] = value;
    }
    await store.put('pendingCaptures', pending.isEmpty ? null : pending);
  }

  Future<void> _resolvePending(
    String id,
    Map draft, {
    required bool restore,
  }) async {
    if (_resolvingPending || _submitting || !_current) return;
    final composing = _textController.value.composing;
    if (restore && composing.isValid && !composing.isCollapsed) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).get('failedInputComposing'),
          ),
        ),
      );
      return;
    }
    setState(() => _resolvingPending = true);
    try {
      if (restore) {
        final text = draft['text'] as String;
        final current = _textController.text;
        final combined = current.isEmpty ? text : '$current\n$text';
        if (current.isEmpty) {
          _quickTime = DateTime.tryParse(draft['time']?.toString() ?? '');
          _memoOnly = draft['memo'] == true;
          _voiceTextDraft = draft['voiceText'] == true;
          _captureId = id;
        } else {
          _voiceTextDraft = _voiceTextDraft || draft['voiceText'] == true;
          _captureId = const Uuid().v4();
        }
        _restoring = true;
        _textController.value = TextEditingValue(
          text: combined,
          selection: TextSelection.collapsed(offset: combined.length),
        );
        _restoring = false;
        _draftRevision++;
        _persistDraft();
        final store = _draftStore;
        await store.flushed;
        if (!_current || store.failed) throw StateError('Draft save failed');
      }
      await _updatePending(id, null);
      if (_current && restore) _focusNode.requestFocus();
    } catch (_) {
      if (mounted) setState(() => _draftSaveFailed = true);
    } finally {
      if (mounted) setState(() => _resolvingPending = false);
    }
  }

  Future<void> _showPending(String id, Map draft) async {
    if (!_current) return;
    final l10n = AppLocalizations.of(context);
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.get('failedInputTitle')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.get('failedInputHint')),
              const SizedBox(height: 12),
              SelectableText(draft['text'] as String),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'discard'),
            child: Text(l10n.get('failedInputDiscard')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'copy'),
            child: Text(l10n.get('failedInputCopy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'restore'),
            child: Text(l10n.get('failedInputRestore')),
          ),
        ],
      ),
    );
    if (!_current || action == null) return;
    if (action == 'copy') {
      try {
        await Clipboard.setData(ClipboardData(text: draft['text'] as String));
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(l10n.get('failedInputCopied'))),
          );
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(l10n.get('failedInputCopyFailed'))),
          );
        }
      }
    } else {
      await _resolvePending(id, draft, restore: action == 'restore');
    }
  }

  Future<void> _pickQuickTime() async {
    if (!_current) return;
    final now = DateTime.now();
    final initial = _quickTime?.isAfter(now) == true ? _quickTime! : now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 10),
    );
    if (!mounted || !_current || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!_current || time == null) return;
    final selected = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!selected.isAfter(DateTime.now())) return;
    _selectTime(selected);
  }

  void _selectTime(DateTime? time, {bool memo = false}) {
    if (!_current) return;
    setState(() {
      _draftRevision++;
      _captureId = const Uuid().v4();
      _quickTime = time;
      _memoOnly = memo;
    });
    _persistDraft();
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

  Future<void> _startLongPressRecording(LongPressStartDetails details) =>
      _beginHeldRecording(details.globalPosition);

  Future<void> _beginHeldRecording(Offset origin) async {
    if (!_current) return;
    if ((!_voiceMode && _textController.text.isNotEmpty) ||
        _isTranscribing ||
        _pendingRecordingStart != null ||
        ref.read(homeControllerProvider).isRecording ||
        ref.read(homeControllerProvider).isPreparingRecording) {
      return;
    }
    _focusNode.unfocus();
    setState(() {
      _voiceOrigin = origin;
      _voiceGesture.reset();
      _voiceAction = VoiceReleaseAction.save;
      _isLongPressRecording = true;
    });
    final controller = ref.read(homeControllerProvider.notifier);
    _heldRecorder = controller;
    final operation = controller.startRecording();
    _pendingRecordingStart = operation;
    final started = await operation;
    if (!mounted || !identical(_pendingRecordingStart, operation)) return;
    if (!started) {
      setState(() => _isLongPressRecording = false);
    } else if (_isLongPressRecording && !_isFinishingLongPress) {
      // The ready feedback must follow native start, never precede the mic.
      unawaited(HapticFeedback.heavyImpact());
    }
  }

  Future<void> _finishLongPressRecording() async {
    if (!_current) return;
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
              setState(() {
                _voiceMode = false;
                _voiceTextDraft = true;
              });
              final current = _textController.text;
              final draft = current.isEmpty ? text : '$current\n$text';
              _textController.value = TextEditingValue(
                text: draft,
                selection: TextSelection.collapsed(offset: draft.length),
              );
              _focusTextAfterBuild();
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
    final action = _voiceGesture.update(details.globalPosition - _voiceOrigin);
    if (action == _voiceAction) return;
    HapticFeedback.selectionClick();
    setState(() => _voiceAction = action);
  }

  void _cancelLongPress() {
    _voiceAction = VoiceReleaseAction.cancel;
    _finishLongPressRecording();
  }

  void _focusTextAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_voiceMode) _focusNode.requestFocus();
    });
  }

  void _toggleInputMode() {
    _focusNode.unfocus();
    setState(() => _voiceMode = !_voiceMode);
    if (!_voiceMode) _focusTextAfterBuild();
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
    final rawPending = ref.watch(workspaceDraftsProvider)['pendingCaptures'];
    final pending = rawPending is Map
        ? rawPending.entries
              .where(
                (entry) =>
                    entry.key is String &&
                    entry.value is Map &&
                    (entry.value as Map)['text'] is String &&
                    !(entry.key == _captureId &&
                        (entry.value as Map)['text'] == _textController.text),
              )
              .toList()
        : <MapEntry<dynamic, dynamic>>[];
    final enterPreference = ref.watch(
      settingsProvider.select((s) => s.inputSendMode == InputSendMode.enter),
    );
    final enterSends = enterPreference && !_voiceTextDraft;
    final isLocalMode = ref.watch(
      settingsProvider.select((s) => !s.hasConfiguredExtraction),
    );
    final isRecording = homeState.isRecording || _isLongPressRecording;
    final colors = Theme.of(context).colorScheme;
    final platform = Theme.of(context).platform;
    final isMobile =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    final voiceMode = isMobile && _voiceMode;
    final displayedTime =
        _quickTime ?? QuickReminderParser.parse(_textController.text);
    final idleVoiceTarget =
        (voiceMode || (_textController.text.isEmpty && !_focusNode.hasFocus)) &&
        !_isTranscribing;
    final captureBusy =
        isRecording ||
        homeState.isPreparingRecording ||
        _isTranscribing ||
        _pendingRecordingStart != null ||
        _submitting ||
        _resolvingPending;
    // Scaffold removes the consumed inset from its body MediaQuery while the
    // keyboard animates away, so also read the containing view's physical inset.
    final keyboardVisible =
        MediaQuery.viewInsetsOf(context).bottom > 0 ||
        View.of(context).viewInsets.bottom > 0;
    final compact =
        !isMobile &&
        (keyboardVisible || MediaQuery.sizeOf(context).height < 600);

    _captureOverlayWanted =
        isMobile && _isLongPressRecording && !keyboardVisible;
    if (_captureOverlayWanted != _capturePortal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_captureOverlayWanted && _isLongPressRecording) {
          _capturePortal.show();
        } else {
          _capturePortal.hide();
        }
      });
    }
    final inputStyle = TextStyle(
      fontSize: isMobile ? 16 : 14,
      height: 1.45,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final inputHint = l10n.get(
      _focusNode.hasFocus
          ? 'inputTypingHint'
          : isLocalMode
          ? 'localInputHint'
          : 'inputHint',
    );
    final composer = SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('composer-frame'),
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: compact ? 2 : 6),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isRecording
                ? Colors.red.withValues(alpha: 0.6)
                : _focusNode.hasFocus
                ? colors.primary.withValues(alpha: 0.6)
                : colors.outlineVariant.withValues(alpha: 0.7),
            width: 1.0,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pending.isNotEmpty && !_submitting)
              TextButton.icon(
                key: const ValueKey('pending-captures'),
                onPressed: _resolvingPending
                    ? null
                    : () => _showPending(
                        pending.first.key as String,
                        pending.first.value as Map,
                      ),
                icon: const Icon(Icons.restore, size: 16),
                label: Text(
                  '${l10n.get('failedInputTitle')} (${pending.length})',
                ),
              ),
            if (!isRecording &&
                !voiceMode &&
                !keyboardVisible &&
                MediaQuery.sizeOf(context).height >= 600 &&
                _textController.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                child: Center(
                  child: Container(
                    key: const ValueKey('composer-save-hint'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _memoOnly
                          ? l10n.get('memoNoAlarm')
                          : displayedTime != null
                          ? '${l10n.get('reminderTimeShort')}: ${formatLocalDateTime(displayedTime)}'
                          : l10n.get('noTimeMemo'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            if (_draftSaveFailed)
              Text(
                l10n.get('draftSaveFailed'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_isLongPressRecording && !keyboardVisible && !isMobile)
              VoiceCaptureFeedback(action: _voiceAction),
            if (isMobile &&
                homeState.isProcessingInBackground &&
                !_isTranscribing)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  semanticsLabel: l10n.get('aiProcessing'),
                ),
              ),
            Row(
              children: [
                if (!isRecording &&
                    !voiceMode &&
                    (_textController.text.isNotEmpty ||
                        _quickTime != null ||
                        _memoOnly))
                  PopupMenuButton<String>(
                    key: const ValueKey('capture-time-options'),
                    tooltip: l10n.get('quickChoose'),
                    enabled: !captureBusy,
                    icon: Icon(
                      _memoOnly
                          ? Icons.notes_outlined
                          : Icons.schedule_outlined,
                      color: displayedTime != null || _memoOnly
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    onSelected: (value) {
                      switch (value) {
                        case 'evening':
                          _selectTime(
                            QuickReminderParser.tonight(DateTime.now()),
                          );
                        case 'morning':
                          _selectTime(
                            QuickReminderParser.tomorrowMorning(DateTime.now()),
                          );
                        case 'custom':
                          _pickQuickTime();
                        case 'memo':
                          _selectTime(null, memo: true);
                        case 'reset':
                          _selectTime(null);
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem<String>(
                        enabled: false,
                        child: Text(
                          _memoOnly
                              ? l10n.get('memoNoAlarm')
                              : displayedTime == null
                              ? l10n.get('noTimeMemo')
                              : formatLocalDateTime(displayedTime),
                        ),
                      ),
                      for (final entry in const {
                        'evening': 'quickEvening',
                        'morning': 'quickMorning',
                        'custom': 'quickChoose',
                        'memo': 'memoOnly',
                        'reset': 'quickReset',
                      }.entries)
                        PopupMenuItem(
                          value: entry.key,
                          child: Text(l10n.get(entry.value)),
                        ),
                    ],
                  ),
                if (isMobile)
                  IconButton(
                    key: const ValueKey('composer-mode-toggle'),
                    icon: Icon(
                      homeState.isRecording && _pendingRecordingStart == null
                          ? Icons.stop_circle_rounded
                          : voiceMode
                          ? Icons.keyboard_outlined
                          : Icons.mic_none_rounded,
                    ),
                    tooltip:
                        homeState.isRecording && _pendingRecordingStart == null
                        ? l10n.get('recordingClickStop')
                        : l10n.get(
                            voiceMode ? 'switchToText' : 'switchToVoice',
                          ),
                    onPressed:
                        homeState.isRecording && _pendingRecordingStart == null
                        ? () => ref
                              .read(homeControllerProvider.notifier)
                              .toggleRecording()
                        : captureBusy
                        ? null
                        : _toggleInputMode,
                  ),
                if (!isMobile) ...[
                  IconButton(
                    key: const ValueKey('composer-attachment'),
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 22,
                    ),
                    color: Theme.of(context).colorScheme.primary,
                    tooltip: l10n.get('uploadMaterial'),
                    splashRadius: 18,
                    onPressed: captureBusy
                        ? null
                        : () => _showMediaOptionsSheet(context),
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
                      tooltip: l10n.get(
                        homeState.isPreparingRecording
                            ? 'voicePreparing'
                            : isRecording
                            ? 'recordingClickStop'
                            : 'recordingStart',
                      ),
                      onPressed:
                          _pendingRecordingStart != null ||
                              homeState.isPreparingRecording
                          ? null
                          : () => ref
                                .read(homeControllerProvider.notifier)
                                .toggleRecording(),
                    ),
                  ),
                ],

                const SizedBox(width: 4),

                // Center Input Area: Single tap to type, Long press to speak
                Expanded(
                  child: GestureDetector(
                    key: const ValueKey('composer-input-surface'),
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      if (!voiceMode &&
                          !isRecording &&
                          !_isTranscribing &&
                          !_focusNode.hasFocus) {
                        _focusNode.requestFocus();
                      }
                    },
                    onLongPressStart: idleVoiceTarget
                        ? _startLongPressRecording
                        : null,
                    // In explicit voice mode begin mic startup while the hold
                    // recognizer waits. A tap, drag cancellation or
                    // permission-delayed release always discards this capture.
                    // Ordinary text taps never open the microphone.
                    onLongPressDown: idleVoiceTarget && voiceMode
                        ? (details) =>
                              _beginHeldRecording(details.globalPosition)
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
                    onSecondaryTapDown: idleVoiceTarget && !voiceMode
                        ? (_) => _openEmptyEditMenu()
                        : null,
                    child:
                        isRecording ||
                            homeState.isPreparingRecording ||
                            _isTranscribing
                        ? ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: isMobile ? 48 : 0,
                            ),
                            child: Row(
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
                                          : homeState.isPreparingRecording
                                          ? 'voicePreparing'
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
                            ),
                          )
                        // iOS TextField's selection recognizer otherwise wins the
                        // gesture arena before our hold-to-record recognizer. Only
                        // the empty, unfocused surface delegates pointer gestures;
                        // typing, selection and IME retain normal TextField behavior.
                        : voiceMode
                        ? Semantics(
                            button: true,
                            label: l10n.get('holdToTalk'),
                            child: Container(
                              key: const ValueKey('composer-voice-pad'),
                              alignment: Alignment.center,
                              constraints: const BoxConstraints(minHeight: 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              ),
                              child: Text(
                                l10n.get('holdToTalk'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          )
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
                              child: Container(
                                key: const ValueKey('composer-text-frame'),
                                alignment: Alignment.center,
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                padding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: compact ? 8 : 10,
                                ),
                                decoration: BoxDecoration(
                                  color: colors.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: _focusNode.hasFocus
                                        ? colors.primary
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Semantics(
                                  label: _textController.text.isEmpty
                                      ? inputHint
                                      : null,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      if (_textController.text.isEmpty)
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: ExcludeSemantics(
                                              child: Center(
                                                child: Text(
                                                  inputHint,
                                                  key: const ValueKey(
                                                    'composer-placeholder',
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: inputStyle.copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      TextField(
                                        controller: _textController,
                                        focusNode: _focusNode,
                                        contextMenuBuilder:
                                            buildEditableTextMenu,
                                        minLines: 1,
                                        maxLines: 4,
                                        textAlign: TextAlign.center,
                                        textAlignVertical:
                                            TextAlignVertical.center,
                                        keyboardType: TextInputType.multiline,
                                        textInputAction: enterSends
                                            ? TextInputAction.send
                                            : TextInputAction.newline,
                                        style: inputStyle,
                                        strutStyle: StrutStyle(
                                          fontSize: inputStyle.fontSize,
                                          height: inputStyle.height,
                                          leadingDistribution:
                                              TextLeadingDistribution.even,
                                          forceStrutHeight: true,
                                        ),
                                        // Keep the editor free of InputDecorator baseline
                                        // and helper spacing; the visible frame owns centering.
                                        decoration: null,
                                        onSubmitted: enterSends
                                            ? (_) => _submitText()
                                            : null,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),

                // Background Processing capsule (Wireframe)
                if (!isMobile &&
                    homeState.isProcessingInBackground &&
                    !_isTranscribing)
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

                if (isMobile)
                  IconButton(
                    key: const ValueKey('composer-attachment'),
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    tooltip: l10n.get('uploadMaterial'),
                    onPressed: captureBusy
                        ? null
                        : () => _showMediaOptionsSheet(context),
                  ),
                if (!isMobile || !enterSends)
                  Container(
                    key: const ValueKey('composer-send'),
                    margin: const EdgeInsets.only(left: 4),
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _textController,
                      builder: (context, value, _) => IconButton(
                        icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                        style: IconButton.styleFrom(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary,
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
                                homeState.isPreparingRecording ||
                                _isTranscribing ||
                                voiceMode
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
    return OverlayPortal(
      controller: _capturePortal,
      overlayChildBuilder: (_) => Positioned.fill(
        child: BlockSemantics(
          child: AbsorbPointer(
            child: VoiceCaptureFeedback(
              action: _voiceAction,
              fullScreen: true,
              preparing: !homeState.isRecording,
            ),
          ),
        ),
      ),
      child: Align(
        heightFactor: 1,
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: composer,
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
