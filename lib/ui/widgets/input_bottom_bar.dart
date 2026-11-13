import 'dart:async';
import 'dart:math' as math;
import 'dart:io' show Platform;
import '../../services/recovery/runtime_gate.dart';
import 'package:uuid/uuid.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../providers/global_capture_provider.dart';
import '../../services/quick_reminder_parser.dart';
import '../formatters/local_date_time.dart';
import '../../providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../providers/home_controller.dart';
import '../../models/settings.dart';
import '../../models/tencent_speech_credentials.dart';
import '../../l10n/app_localizations.dart';
import 'editable_text_menu.dart';
import 'voice_capture_feedback.dart';
import 'live_voice_text_dialog.dart';
import '../../services/voice_text_draft.dart';
import 'windows_composer_layout.dart';

// A separate type lets RawGestureDetector replace the recognizer when changing
// input mode; a recognizer's deadline cannot be changed after construction.
class _QuickVoiceHoldRecognizer extends LongPressGestureRecognizer {
  _QuickVoiceHoldRecognizer()
    : super(duration: const Duration(milliseconds: 200));
}

class InputBottomBar extends ConsumerStatefulWidget {
  const InputBottomBar({super.key});

  @override
  ConsumerState<InputBottomBar> createState() => _InputBottomBarState();
}

class _InputBottomBarState extends ConsumerState<InputBottomBar> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  late final CaptureInputCommand _captureCommand;
  late final bool Function() _focusCapture;
  bool _isLongPressRecording = false;
  bool _desktopVoiceDraft = false;
  Future<bool>? _pendingRecordingStart;
  bool _isFinishingLongPress = false;
  Offset _voiceOrigin = Offset.zero;
  final _voiceGesture = VoiceCaptureGesture();
  VoiceReleaseAction _voiceAction = VoiceReleaseAction.save;
  bool _isTranscribing = false;
  bool _voiceEditorOpen = false;
  bool _voiceEditorClosing = false;
  bool _voiceMode = false;
  bool _voiceTextDraft = false;
  // Keep the modal semantics in the overlay, independent of the input anchor.
  OverlayEntry? _captureOverlay;
  MediaQueryData? _captureMedia;
  ThemeData? _captureTheme;
  Locale? _captureLocale;
  bool _captureOverlaySyncScheduled = false;
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
  bool get _voiceBusy {
    final state = ref.read(homeControllerProvider);
    return _isLongPressRecording ||
        _pendingRecordingStart != null ||
        _isTranscribing ||
        state.isRecording ||
        state.isPreparingRecording;
  }

  bool _lastFocused = false;

  void _removeCaptureOverlay() {
    final entry = _captureOverlay;
    _captureOverlay = null;
    entry?.remove();
    entry?.dispose();
  }

  void _scheduleCaptureOverlay() {
    if (_captureOverlaySyncScheduled) return;
    _captureOverlaySyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureOverlaySyncScheduled = false;
      if (!mounted) return;
      if (!_captureOverlayWanted || !_isLongPressRecording || !_current) {
        _removeCaptureOverlay();
        return;
      }
      if (_captureOverlay != null) {
        _captureOverlay!.markNeedsBuild();
        return;
      }
      final overlay = Overlay.of(context);
      final container = ProviderScope.containerOf(context, listen: false);
      final entry = OverlayEntry(
        builder: (overlayContext) {
          if (!mounted) {
            return const SizedBox.shrink();
          }
          final rootMedia = MediaQuery.of(overlayContext);
          return Positioned.fill(
            child: BlockSemantics(
              child: MediaQuery(
                data: _captureMedia!.copyWith(
                  padding: rootMedia.padding,
                  viewPadding: rootMedia.viewPadding,
                  viewInsets: rootMedia.viewInsets,
                ),
                child: InheritedTheme.captureAll(
                  context,
                  UncontrolledProviderScope(
                    container: container,
                    child: Semantics(
                      container: true,
                      explicitChildNodes: true,
                      child: AbsorbPointer(
                        child: Consumer(
                          builder: (_, ref, _) {
                            final state = ref.watch(homeControllerProvider);
                            final live = ref.watch(
                              settingsProvider.select(
                                (s) =>
                                    s.speech.isConfigured &&
                                    s.speech.endpoint ==
                                        TencentSpeechCredentials
                                            .realtimeEndpoint,
                              ),
                            );
                            return VoiceCaptureFeedback(
                              action: _voiceAction,
                              fullScreen: true,
                              preparing: !state.isRecording,
                              selectionOpen: _voiceGesture.selectionOpen,
                              transcript: state.voicePreview,
                              liveTranscription: live,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
      _captureOverlay = entry;
      overlay.insert(entry);
    });
  }

  @override
  void initState() {
    super.initState();
    _inputRuntime = ref.read(runtimeRecoveryGateProvider);
    _inputBirth = _inputRuntime.paused ? null : _inputRuntime.capture();
    _draftStore = ref.read(workspaceDraftsProvider.notifier);
    _captureCommand = ref.read(captureInputCommandProvider);
    _focusCapture = () {
      if (!_current || _voiceBusy || _submitting || _resolvingPending) {
        return false;
      }
      if (_voiceMode) setState(() => _voiceMode = false);
      _focusTextAfterBuild();
      WidgetsBinding.instance.scheduleFrame();
      return true;
    };
    _captureCommand.focus = _focusCapture;
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
    _removeCaptureOverlay();
    if (identical(_captureCommand.focus, _focusCapture)) {
      _captureCommand.focus = null;
    }
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
    if (_submitting || _resolvingPending || !_current || _voiceBusy) return;
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
    if (!_current || _voiceBusy) return;
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
      _beginHeldRecording(
        details.globalPosition,
        editable: ![
          TargetPlatform.iOS,
          TargetPlatform.android,
        ].contains(Theme.of(context).platform),
      );

  Future<void> _beginHeldRecording(
    Offset origin, {
    bool editable = false,
  }) async {
    if (!_current) return;
    final composing = _textController.value.composing;
    if (editable && composing.isValid && !composing.isCollapsed) return;
    if ((!editable && !_voiceMode && _textController.text.isNotEmpty) ||
        _isTranscribing ||
        _pendingRecordingStart != null ||
        ref.read(homeControllerProvider).isRecording ||
        ref.read(homeControllerProvider).isPreparingRecording) {
      return;
    }
    if (editable) {
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
    }
    setState(() {
      _voiceOrigin = origin;
      _voiceGesture.reset();
      _desktopVoiceDraft = editable;
      _voiceAction = editable
          ? VoiceReleaseAction.text
          : VoiceReleaseAction.save;
      _isLongPressRecording = true;
    });
    final controller = ref.read(homeControllerProvider.notifier);
    _heldRecorder = controller;
    final operation = controller.startRecording();
    _pendingRecordingStart = operation;
    final started = await operation;
    if (!mounted || !identical(_pendingRecordingStart, operation)) return;
    if (!started) {
      _removeCaptureOverlay();
      setState(() {
        _isLongPressRecording = false;
        if (!_isFinishingLongPress) {
          _pendingRecordingStart = null;
          _heldRecorder = null;
          _desktopVoiceDraft = false;
        }
      });
    } else if (_isLongPressRecording && !_isFinishingLongPress) {
      controller.prepareRecordingTranscription();
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
    var sendText = false;
    VoiceTextDraft? voiceDraft;
    final mobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    HapticFeedback.mediumImpact();
    _removeCaptureOverlay();
    setState(() {
      _isLongPressRecording = false;
      _isTranscribing =
          action == VoiceReleaseAction.text ||
          action == VoiceReleaseAction.send;
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
          case VoiceReleaseAction.send:
            voiceDraft = mobile ? controller.createVoiceTextDraft() : null;
            final result =
                voiceDraft?.result ??
                controller.stopRecordingToText(canAcceptDraft: () => _current);
            if (mobile && action == VoiceReleaseAction.text) {
              setState(() {
                _voiceMode = false;
                _voiceTextDraft = true;
              });
              sendText =
                  await _editVoiceDraft(result, draft: voiceDraft) && _current;
              break;
            }
            final text = await result;
            if (_current &&
                mobile &&
                ref.read(homeControllerProvider).error != null &&
                ref.read(homeControllerProvider).voicePreview.isNotEmpty) {
              setState(() {
                _voiceMode = false;
                _voiceTextDraft = true;
              });
              sendText = await _editVoiceDraft(
                Future.value(text),
                draft: voiceDraft,
              );
              break;
            }
            if (_current && text != null) {
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
              sendText =
                  action == VoiceReleaseAction.send &&
                  ref.read(homeControllerProvider).error == null;
              if (!sendText) _focusTextAfterBuild();
            }
        }
      }
    } finally {
      await voiceDraft?.release(sentText: sendText);
      if (mounted && identical(_pendingRecordingStart, operation)) {
        setState(() {
          _pendingRecordingStart = null;
          _isFinishingLongPress = false;
          _isTranscribing = false;
          _heldRecorder = null;
          _desktopVoiceDraft = false;
        });
      }
    }
    if (sendText && _current) await _submitText();
  }

  Future<bool> _editVoiceDraft(
    Future<String?> result, {
    VoiceTextDraft? draft,
  }) async {
    final prefix = _textController.text;
    final initial = ref.read(homeControllerProvider).voicePreview;
    setState(() => _voiceEditorOpen = true);
    try {
      final send = await showDialog<bool>(
        context: context,
        builder: (_) => LiveVoiceTextDialog(
          result: result,
          prefix: prefix,
          initial: initial,
          onSendOriginal: draft == null
              ? null
              : () async {
                  final sent = await draft.sendOriginal();
                  if (sent && mounted) {
                    _voiceTextDraft = prefix.isNotEmpty;
                    _textController.value = TextEditingValue(
                      text: prefix,
                      selection: TextSelection.collapsed(offset: prefix.length),
                    );
                  }
                  return sent;
                },
          onChanged: (text) {
            if (_current) {
              if (text.isNotEmpty) _voiceTextDraft = true;
              _textController.value = TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length),
              );
            }
          },
        ),
      );
      return send == true;
    } finally {
      if (mounted) {
        if (ModalRoute.of(context)?.isCurrent != false) {
          FocusScope.of(context).unfocus();
        }
        setState(() {
          _voiceEditorOpen = false;
          _voiceEditorClosing = true;
        });
      }
    }
  }

  void _moveLongPress(LongPressMoveUpdateDetails details) {
    if (!_isLongPressRecording || _isFinishingLongPress) return;
    final selectionWasOpen = _voiceGesture.selectionOpen;
    final selected = _voiceGesture.update(
      details.globalPosition - _voiceOrigin,
    );
    if (_voiceGesture.selectionOpen) {
      ref.read(homeControllerProvider.notifier).prepareRecordingTranscription();
    }
    final action =
        _desktopVoiceDraft &&
            (selected == VoiceReleaseAction.save ||
                selected == VoiceReleaseAction.send)
        ? VoiceReleaseAction.text
        : selected;
    if (action == _voiceAction &&
        selectionWasOpen == _voiceGesture.selectionOpen) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _voiceAction = action);
    _captureOverlay?.markNeedsBuild();
  }

  void _cancelLongPress() {
    _voiceAction = VoiceReleaseAction.cancel;
    _finishLongPressRecording();
  }

  Future<void> _toggleDesktopVoiceDraft() async {
    if (!_current || _isTranscribing) return;
    if (_pendingRecordingStart != null) {
      await _finishLongPressRecording();
    } else if (ref.read(homeControllerProvider).isRecording) {
      // A recording may also have been started by the application shortcut.
      _heldRecorder = ref.read(homeControllerProvider.notifier);
      _pendingRecordingStart = Future.value(true);
      _voiceAction = VoiceReleaseAction.text;
      await _finishLongPressRecording();
    } else {
      await _beginHeldRecording(Offset.zero, editable: true);
    }
  }

  void _focusTextAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current && !_voiceMode && !_voiceBusy) _requestTextKeyboard();
    });
  }

  void _requestTextKeyboard() {
    if (!_current || _voiceMode || _voiceBusy) return;
    // Focus may already belong to this editor after Android hides the IME or
    // switches keyboards. requestFocus alone does not reopen that connection.
    final editor = _focusNode.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (editor != null) {
      editor.requestKeyboard();
    } else {
      _focusNode.requestFocus();
    }
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
                    // Desktop builds have no camera capture path, so the entry
                    // would always fail; mobile keeps it.
                    if (Platform.isAndroid || Platform.isIOS)
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _buildComposer(context, constraints),
  );

  Widget _buildComposer(BuildContext context, BoxConstraints constraints) {
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
    final isWindows = platform == TargetPlatform.windows;
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
        isMobile &&
        _isLongPressRecording &&
        !keyboardVisible &&
        _current &&
        ModalRoute.of(context)?.isCurrent != false;
    var overlayStyleChanged = false;
    if (_captureOverlayWanted) {
      final media = MediaQuery.of(context), theme = Theme.of(context);
      final locale = Localizations.localeOf(context);
      overlayStyleChanged =
          _captureMedia != media ||
          _captureTheme != theme ||
          _captureLocale != locale;
      _captureMedia = media;
      _captureTheme = theme;
      _captureLocale = locale;
    }
    if (_captureOverlayWanted != (_captureOverlay != null) ||
        (_captureOverlayWanted && overlayStyleChanged)) {
      _scheduleCaptureOverlay();
    }
    // Keep the composer state and draft alive behind its modal editor. Showing
    // a second editor/preview in a keyboard-height background can overflow.
    if (!keyboardVisible) _voiceEditorClosing = false;
    final hideComposer = isMobile && (_voiceEditorOpen || _voiceEditorClosing);
    final inputStyle =
        (isWindows ? Theme.of(context).textTheme.bodyLarge! : const TextStyle())
            .copyWith(
              fontSize: isMobile ? 16 : 15,
              height: 1.45,
              leadingDistribution: TextLeadingDistribution.even,
            );
    final windowsLayout = isWindows
        ? WindowsComposerLayout.measure(
            text: _textController.text,
            width: math.max(
              1,
              math.min(
                    1040,
                    constraints.hasBoundedWidth
                        ? constraints.maxWidth
                        : MediaQuery.sizeOf(context).width,
                  ) -
                  40,
            ),
            availableHeight: math.max(
              0,
              MediaQuery.sizeOf(context).height -
                  math.max(
                    MediaQuery.viewInsetsOf(context).bottom,
                    View.of(context).viewInsets.bottom /
                        View.of(context).devicePixelRatio,
                  ),
            ),
            style: inputStyle,
            textScaler: MediaQuery.textScalerOf(context),
            direction: Directionality.of(context),
            locale: Localizations.maybeLocaleOf(context),
            showSummary: displayedTime != null || _memoOnly,
          )
        : null;
    final inputHint = l10n.get(
      isWindows
          ? 'desktopCompactInputHint'
          : !isMobile
          ? 'desktopInputHint'
          : _focusNode.hasFocus
          ? 'inputTypingHint'
          : isLocalMode
          ? 'localInputHint'
          : 'inputHint',
    );
    final showTimeOptions =
        !isRecording &&
        !voiceMode &&
        (_textController.text.isNotEmpty || _quickTime != null || _memoOnly);
    final canHold = isMobile
        ? idleVoiceTarget
        : !_isTranscribing && !_submitting && !_resolvingPending;
    final timeOptions = PopupMenuButton<String>(
      key: const ValueKey('capture-time-options'),
      tooltip: l10n.get('quickChoose'),
      enabled: !captureBusy,
      icon: Icon(
        _memoOnly ? Icons.notes_outlined : Icons.schedule_outlined,
        color: displayedTime != null || _memoOnly
            ? Theme.of(context).colorScheme.primary
            : null,
      ),
      onSelected: (value) {
        switch (value) {
          case 'evening':
            _selectTime(QuickReminderParser.tonight(DateTime.now()));
          case 'morning':
            _selectTime(QuickReminderParser.tomorrowMorning(DateTime.now()));
          case 'custom':
            _pickQuickTime();
          case 'memo':
            _selectTime(null, memo: true);
          case 'reset':
            _selectTime(null);
        }
      },
      itemBuilder: (_) => [
        for (final entry in const {
          'evening': 'quickEvening',
          'morning': 'quickMorning',
          'custom': 'quickChoose',
          'memo': 'memoOnly',
          'reset': 'quickReset',
        }.entries)
          PopupMenuItem(value: entry.key, child: Text(l10n.get(entry.value))),
      ],
    );
    final mobileModeToggle = IconButton(
      key: const ValueKey('composer-mode-toggle'),
      icon: Icon(
        homeState.isRecording && _pendingRecordingStart == null
            ? Icons.stop_circle_rounded
            : voiceMode
            ? Icons.keyboard_outlined
            : Icons.mic_none_rounded,
      ),
      tooltip: homeState.isRecording && _pendingRecordingStart == null
          ? l10n.get('recordingClickStop')
          : l10n.get(voiceMode ? 'switchToText' : 'switchToVoice'),
      onPressed: homeState.isRecording && _pendingRecordingStart == null
          ? () => ref.read(homeControllerProvider.notifier).toggleRecording()
          : captureBusy
          ? null
          : _toggleInputMode,
    );
    final inputSurface = RawGestureDetector(
      key: const ValueKey('composer-input-surface'),
      behavior: HitTestBehavior.translucent,
      gestures: {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (instance) => instance
                ..onTap = () {
                  if (!voiceMode && !isRecording && !_isTranscribing) {
                    _requestTextKeyboard();
                  }
                }
                ..onSecondaryTapDown = isMobile && idleVoiceTarget && !voiceMode
                    ? (_) => _openEmptyEditMenu()
                    : null,
            ),
        if (canHold && voiceMode)
          _QuickVoiceHoldRecognizer:
              GestureRecognizerFactoryWithHandlers<_QuickVoiceHoldRecognizer>(
                () => _QuickVoiceHoldRecognizer(),
                (instance) => instance
                  ..onLongPressStart = _startLongPressRecording
                  ..onLongPressMoveUpdate = _moveLongPress
                  ..onLongPressEnd = (_) {
                    unawaited(_finishLongPressRecording());
                  }
                  ..onLongPressCancel = _cancelLongPress,
              ),
        if (canHold && !voiceMode)
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                // The explicit voice target responds quickly, while the text
                // field keeps the standard selection/hold timing. A short tap
                // never starts recording or sends audio to the provider.
                () => LongPressGestureRecognizer(),
                (instance) => instance
                  ..onLongPressStart = _startLongPressRecording
                  ..onLongPressMoveUpdate = _moveLongPress
                  ..onLongPressEnd = (_) {
                    unawaited(_finishLongPressRecording());
                  }
                  ..onLongPressCancel = _cancelLongPress,
              ),
      },
      child:
          isMobile &&
              (isRecording || homeState.isPreparingRecording || _isTranscribing)
          ? ConstrainedBox(
              constraints: BoxConstraints(minHeight: isMobile ? 48 : 0),
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
                                      VoiceReleaseAction.send =>
                                        'voiceReleaseSend',
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
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Text(
                  l10n.get('holdToTalk'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            )
          : IgnorePointer(
              ignoring: isMobile && idleVoiceTarget,
              child: CallbackShortcuts(
                bindings: {
                  if (!isMobile &&
                      _isLongPressRecording &&
                      !_isFinishingLongPress)
                    const SingleActivator(LogicalKeyboardKey.escape):
                        _cancelLongPress,
                  const SingleActivator(LogicalKeyboardKey.enter): enterSends
                      ? _submitText
                      : _insertLineBreak,
                  const SingleActivator(LogicalKeyboardKey.numpadEnter):
                      enterSends ? _submitText : _insertLineBreak,
                  const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                      _insertLineBreak,
                  const SingleActivator(
                    LogicalKeyboardKey.numpadEnter,
                    shift: true,
                  ): _insertLineBreak,
                },
                child: Container(
                  key: const ValueKey('composer-text-frame'),
                  alignment: isMobile
                      ? Alignment.center
                      : isWindows && !windowsLayout!.expanded
                      ? AlignmentDirectional.centerStart
                      : AlignmentDirectional.topStart,
                  constraints: BoxConstraints(
                    minHeight: isMobile
                        ? 48
                        : isWindows
                        ? 44
                        : compact
                        ? 84
                        : 132,
                  ),
                  padding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: isWindows
                        ? 10
                        : compact
                        ? 8
                        : 10,
                  ),
                  decoration: BoxDecoration(
                    color: isMobile
                        ? colors.surfaceContainerLow
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: isMobile
                        ? Border.all(
                            color: _focusNode.hasFocus
                                ? colors.primary
                                : Colors.transparent,
                          )
                        : null,
                  ),
                  child: Semantics(
                    label: _textController.text.isEmpty ? inputHint : null,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: isMobile || isWindows
                            ? 0
                            : compact
                            ? 68
                            : 112,
                      ),
                      child: Stack(
                        alignment: isMobile
                            ? Alignment.center
                            : isWindows && !windowsLayout!.expanded
                            ? AlignmentDirectional.centerStart
                            : AlignmentDirectional.topStart,
                        children: [
                          if (_textController.text.isEmpty &&
                              (isMobile || isWindows || !_focusNode.hasFocus))
                            Positioned.fill(
                              child: IgnorePointer(
                                child: ExcludeSemantics(
                                  child: Align(
                                    alignment: isWindows
                                        ? AlignmentDirectional.centerStart
                                        : Alignment.center,
                                    child: Text(
                                      inputHint,
                                      key: const ValueKey(
                                        'composer-placeholder',
                                      ),
                                      textAlign: isWindows
                                          ? TextAlign.start
                                          : TextAlign.center,
                                      maxLines: isMobile || isWindows ? 1 : 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: inputStyle.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          TextField(
                            controller: _textController,
                            focusNode: _focusNode,
                            contextMenuBuilder: buildEditableTextMenu,
                            readOnly:
                                !isMobile &&
                                (isRecording ||
                                    homeState.isPreparingRecording ||
                                    _isTranscribing),
                            minLines: isMobile
                                ? 1
                                : isWindows
                                ? windowsLayout!.minLines
                                : compact
                                ? 2
                                : 4,
                            maxLines: isMobile
                                ? 4
                                : isWindows
                                ? windowsLayout!.maxLines
                                : compact
                                ? 4
                                : 8,
                            textAlign: isMobile
                                ? TextAlign.center
                                : TextAlign.start,
                            textAlignVertical:
                                isMobile ||
                                    (isWindows && !windowsLayout!.expanded)
                                ? TextAlignVertical.center
                                : TextAlignVertical.top,
                            keyboardType: TextInputType.multiline,
                            textInputAction: enterSends
                                ? TextInputAction.send
                                : TextInputAction.newline,
                            style: inputStyle,
                            strutStyle: StrutStyle(
                              fontSize: inputStyle.fontSize,
                              height: inputStyle.height,
                              leadingDistribution: TextLeadingDistribution.even,
                              forceStrutHeight: true,
                            ),
                            // Keep the editor free of InputDecorator baseline
                            // and helper spacing; the visible frame owns centering.
                            decoration: null,
                            onSubmitted: enterSends
                                ? (_) => _submitText()
                                : null,
                          ),
                          if (!isMobile &&
                              (isRecording ||
                                  homeState.isPreparingRecording ||
                                  _isTranscribing))
                            Positioned.fill(
                              child: ColoredBox(
                                color: colors.surfaceContainerLowest,
                                child: Center(
                                  child: Text(
                                    l10n.get(
                                      _isTranscribing
                                          ? 'voiceTranscribing'
                                          : homeState.isPreparingRecording
                                          ? 'voicePreparing'
                                          : _voiceAction ==
                                                VoiceReleaseAction.cancel
                                          ? 'voiceReleaseCancel'
                                          : 'desktopReleaseHint',
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: isWindows ? 1 : null,
                                    overflow: isWindows
                                        ? TextOverflow.ellipsis
                                        : null,
                                    style: inputStyle.copyWith(
                                      color: colors.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
    final attachment = IconButton(
      key: const ValueKey('composer-attachment'),
      constraints: isMobile
          ? null
          : const BoxConstraints.tightFor(width: 44, height: 44),
      icon: Icon(
        isMobile ? Icons.add_circle_outline_rounded : Icons.attach_file_rounded,
      ),
      tooltip: l10n.get('uploadMaterial'),
      onPressed: captureBusy ? null : () => _showMediaOptionsSheet(context),
    );
    final send = Container(
      key: const ValueKey('composer-send'),
      margin: const EdgeInsets.only(left: 4),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _textController,
        builder: (context, value, _) {
          final onSend = value.text.trim().isEmpty || captureBusy || voiceMode
              ? null
              : _submitText;
          if (!isMobile) {
            if (isWindows && windowsLayout!.iconSend) {
              return SizedBox.square(
                dimension: 44,
                child: IconButton.filled(
                  onPressed: onSend,
                  tooltip: l10n.get('send'),
                  icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                ),
              );
            }
            final button = FilledButton(
              onPressed: onSend,
              style: FilledButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.onPrimary,
                minimumSize: const Size(88, 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                l10n.get('send'),
                maxLines: isWindows ? 1 : null,
                overflow: isWindows ? TextOverflow.ellipsis : null,
              ),
            );
            return isWindows
                ? SizedBox(width: 88, height: 44, child: button)
                : button;
          }
          return IconButton(
            icon: const Icon(Icons.arrow_upward_rounded, size: 18),
            style: IconButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: colors.onPrimary,
              padding: const EdgeInsets.all(5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            tooltip: l10n.get('send'),
            onPressed: onSend,
          );
        },
      ),
    );
    final desktopVoice = _RecordingPulse(
      active: isRecording,
      child: IconButton(
        key: const ValueKey('composer-desktop-voice'),
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        icon: Icon(
          isRecording ? Icons.stop_circle_rounded : Icons.mic_none_rounded,
        ),
        tooltip: l10n.get(isRecording ? 'desktopVoiceStop' : 'recordingStart'),
        onPressed:
            homeState.isPreparingRecording ||
                _isTranscribing ||
                _submitting ||
                _resolvingPending
            ? null
            : _toggleDesktopVoiceDraft,
      ),
    );
    Widget desktopToolbar({bool below = true}) => Padding(
      key: const ValueKey('composer-desktop-toolbar'),
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        children: [
          if (!below)
            SizedBox(width: 44, height: 44, child: timeOptions)
          else
            Expanded(
              child: Row(
                children: [
                  if (showTimeOptions || isWindows)
                    SizedBox(width: 44, height: 44, child: timeOptions),
                  if (displayedTime != null || _memoOnly)
                    Expanded(
                      child: Text(
                        _memoOnly
                            ? l10n.get('memoOnly')
                            : formatLocalDateTime(displayedTime!),
                        key: const ValueKey('composer-time-summary'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          if (isWindows)
            SizedBox.square(dimension: 44, child: desktopVoice)
          else
            desktopVoice,
          if (isWindows)
            SizedBox.square(dimension: 44, child: attachment)
          else
            attachment,
          send,
        ],
      ),
    );
    final composer = SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('composer-frame'),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: EdgeInsets.symmetric(
          horizontal: 8,
          vertical: isWindows
              ? 6
              : compact
              ? 2
              : 6,
        ),
        decoration: BoxDecoration(
          color: isWindows
              ? colors.surfaceContainerLow
              : colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(isWindows ? 16 : 20),
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
            if (isMobile &&
                !isRecording &&
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
                          ? l10n.get('memoOnly')
                          : displayedTime != null
                          ? '${l10n.get('reminderTimeShort')}: ${formatLocalDateTime(displayedTime)}'
                          : l10n.get('captureNoTime'),
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
            if (homeState.isProcessingInBackground && !_isTranscribing)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  semanticsLabel: l10n.get('aiProcessing'),
                ),
              ),
            if (isMobile)
              Row(
                children: [
                  if (showTimeOptions) timeOptions,
                  mobileModeToggle,
                  const SizedBox(width: 4),
                  Expanded(child: inputSurface),
                  attachment,
                  if (!enterSends) send,
                ],
              )
            else if (windowsLayout case final layout?)
              Stack(
                key: const ValueKey('composer-windows-layout'),
                children: [
                  // Stable child ancestry preserves EditableText, its native
                  // IME connection and selection when the footer moves.
                  Padding(
                    padding: EdgeInsets.only(
                      right: layout.footerBelow ? 0 : layout.actionsWidth,
                      bottom: layout.footerBelow ? 48 : 4,
                    ),
                    child: inputSurface,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    left: layout.footerBelow ? 0 : null,
                    width: layout.footerBelow ? null : layout.actionsWidth,
                    child: desktopToolbar(below: layout.footerBelow),
                  ),
                ],
              )
            else ...[
              inputSurface,
              desktopToolbar(),
            ],
          ],
        ),
      ),
    );
    return hideComposer
        ? const SizedBox.shrink()
        : Align(
            heightFactor: 1,
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (((!isMobile && isRecording) ||
                          (_isTranscribing && !_voiceEditorOpen)) &&
                      homeState.voicePreview.isNotEmpty)
                    Container(
                      key: const ValueKey('desktop-voice-transcript-preview'),
                      width: double.infinity,
                      constraints: BoxConstraints(
                        maxHeight: math.min(
                          160,
                          MediaQuery.sizeOf(context).height * .25,
                        ),
                      ),
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colors.secondaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              reverse: true,
                              child: Text(
                                homeState.voicePreview,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: colors.onSecondaryContainer,
                                    ),
                              ),
                            ),
                          ),
                          if (_isTranscribing)
                            IconButton(
                              key: const ValueKey(
                                'cancel-pending-transcription',
                              ),
                              tooltip: l10n.get('cancel'),
                              onPressed: () => ref
                                  .read(homeControllerProvider.notifier)
                                  .cancelLiveTranscription(),
                              icon: const Icon(Icons.close),
                            ),
                        ],
                      ),
                    ),
                  composer,
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
