import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../data/database_helper.dart';
import '../models/media_record.dart';
import '../models/reminder.dart';
import '../models/agent_models.dart';
import '../services/llm_service.dart';
import '../services/local_media_store.dart';
import '../services/recording_duration_reader.dart';
import '../services/local_speech_service.dart';
import '../services/quick_reminder_parser.dart';
import '../services/recovery/runtime_gate.dart';
import 'providers.dart';

class HomeState {
  static const _unchanged = Object();
  final bool isLoading;
  final bool isRecording;
  final int pendingTasksCount;
  final String? error;

  HomeState({
    this.isLoading = false,
    this.isRecording = false,
    this.pendingTasksCount = 0,
    this.error,
  });

  bool get isProcessingInBackground => pendingTasksCount > 0;

  HomeState copyWith({
    bool? isLoading,
    bool? isRecording,
    int? pendingTasksCount,
    Object? error = _unchanged,
  }) {
    return HomeState(
      isLoading: isLoading ?? this.isLoading,
      isRecording: isRecording ?? this.isRecording,
      pendingTasksCount: pendingTasksCount ?? this.pendingTasksCount,
      error: identical(error, _unchanged) ? this.error : error as String?,
    );
  }
}

final homeControllerProvider = StateNotifierProvider<HomeController, HomeState>(
  (ref) {
    return HomeController(ref);
  },
);

class HomeController extends StateNotifier<HomeState> {
  final Ref _ref;
  final DatabaseHelper _database;
  final AudioRecorder _audioRecorder;
  final Future<Directory> Function() _temporaryDirectory;
  final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken? _birth;
  Future<void> _recorderOperations = Future<void>.value();
  bool _nativeRecording = false;
  final Future<XFile?> Function(ImageSource) _pickImage;
  final Future<XFile?> Function() _pickVideo;
  final Future<PlatformFile?> Function() _pickFile;
  final Future<String> Function(String) _importFile;
  final Map<Object, DataGeneration> _pending = {};
  DataGeneration? _recordingGeneration;

  HomeController(
    this._ref, {
    Future<XFile?> Function(ImageSource)? pickImage,
    Future<XFile?> Function()? pickVideo,
    Future<PlatformFile?> Function()? pickFile,
    Future<String> Function(String)? importFile,
    AudioRecorder? audioRecorder,
    Future<Directory> Function()? temporaryDirectory,
  }) : _runtime = _ref.read(runtimeRecoveryGateProvider),
       _audioRecorder = audioRecorder ?? AudioRecorder(),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _database = _ref.read(databaseHelperProvider),
       _pickImage =
           pickImage ?? ((source) => ImagePicker().pickImage(source: source)),
       _pickVideo =
           pickVideo ??
           (() => ImagePicker().pickVideo(source: ImageSource.gallery)),
       _pickFile = pickFile ?? (() => FilePicker.pickFile(type: FileType.any)),
       _importFile = importFile ?? LocalMediaStore().importFile,
       super(HomeState()) {
    _birth = _runtime.paused ? null : _runtime.capture();
    if (_birth != null) _runtime.register(this, _quiesce);
  }

  @override
  void dispose() {
    _runtime.unregister(this);
    unawaited(
      _serializeRecorder(() async {
        try {
          await _discardRecording();
        } finally {
          await _audioRecorder.dispose();
        }
      }).catchError((Object _) {}),
    );
    super.dispose();
  }

  Future<T> _serializeRecorder<T>(Future<T> Function() action) {
    final result = _recorderOperations.then((_) => action());
    _recorderOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _discardRecording() async {
    _recordingGeneration = null;
    if (_nativeRecording) {
      // cancel removes the unconfirmed temporary capture; it never imports it.
      await _audioRecorder.cancel();
      _nativeRecording = false;
    }
  }

  Future<void> _quiesce() async {
    _pending.clear();
    if (mounted) state = HomeState();
    await _ref.read(localSpeechServiceProvider).cancel();
    await _serializeRecorder(_discardRecording);
  }

  bool _isCurrent(DataGeneration generation) =>
      mounted && _runtime.isCurrent(_birth) && _database.isCurrent(generation);

  void _check(DataGeneration generation) {
    _runtime.check(_birth);
    _database.checkGeneration(generation);
    if (!mounted) {
      throw StateError('Input controller is no longer active.');
    }
  }

  DataGeneration? _beginInput() {
    if (!mounted || !_runtime.isCurrent(_birth)) {
      return null;
    }
    try {
      return _database.captureGeneration();
    } on DatabaseAccessException {
      state = state.copyWith(error: '数据暂时不可用，请稍后重试。');
      return null;
    }
  }

  void _publishPendingCount() {
    if (mounted && _runtime.isCurrent(_birth)) {
      // Operation bookkeeping can settle after maintenance; only current work
      // contributes to the new session, and no old result/error is published.
      state = state.copyWith(
        pendingTasksCount: _pending.values.where(_database.isCurrent).length,
      );
    }
  }

  Object _startPending(DataGeneration generation) {
    _check(generation);
    final operation = Object();
    _pending[operation] = generation;
    state = state.copyWith(error: null);
    _publishPendingCount();
    return operation;
  }

  void _finishPending(Object operation) {
    _pending.remove(operation);
    _publishPendingCount();
  }

  void _reportError(DataGeneration generation, String message) {
    if (_isCurrent(generation)) {
      state = state.copyWith(error: message);
    }
  }

  void _launch(
    DataGeneration generation,
    Future<void> Function() action, {
    required String failureMessage,
    bool explainModelError = false,
  }) {
    final operation = _startPending(generation);
    unawaited(
      Future<void>(() async {
        try {
          _check(generation);
          await action();
        } catch (error) {
          if (_isCurrent(generation)) {
            final message = explainModelError
                ? '$failureMessage: ${_ref.read(llmServiceProvider).formatErrorMessage(error)}'
                : failureMessage;
            _reportError(generation, message);
          }
        } finally {
          _finishPending(operation);
        }
      }),
    );
  }

  Future<String> _saveFileToLocal(String path, DataGeneration generation) =>
      _database.runOperation(generation, () async {
        _check(generation);
        return _importFile(path);
      });

  Future<void> _saveTasks(
    List<Reminder> tasks,
    DataGeneration generation, {
    String? recordId,
  }) async {
    for (final task in tasks) {
      _check(generation);
      final saved = recordId == null ? task : task.copyWith(recordId: recordId);
      final result = await _ref
          .read(remindersProvider.notifier)
          .addReminderForGeneration(saved, generation);
      _check(generation);
      if (result.nativeSyncFailed) {
        final language = _ref.read(settingsProvider).language;
        _reportError(
          generation,
          AppLocalizations(Locale(language)).get('reminderNativeSyncFailed'),
        );
      }
    }
  }

  Future<String> _saveMedia(
    String type,
    String path,
    DataGeneration generation,
  ) async {
    _check(generation);
    final id = const Uuid().v4();
    await _ref
        .read(mediaRecordsProvider.notifier)
        .addRecordForGeneration(
          MediaRecord(
            id: id,
            type: type,
            contentOrPath: path,
            createdAt: DateTime.now(),
          ),
          generation,
        );
    _check(generation);
    return id;
  }

  Future<MultiAgentExecutionResult> processWithMultiAgent(
    String complexGoal,
  ) async {
    _runtime.check(_birth);
    final generation = _database.captureGeneration();
    return _processWithMultiAgent(complexGoal, generation);
  }

  Future<MultiAgentExecutionResult> _processWithMultiAgent(
    String complexGoal,
    DataGeneration generation,
  ) async {
    final trimmed = complexGoal.trim();
    if (trimmed.isEmpty) {
      throw Exception('目标内容不能为空');
    }
    final operation = _startPending(generation);
    try {
      final service = _ref.read(multiAgentServiceProvider);
      final settings = _ref.read(settingsProvider);
      final existingTasks = _ref.read(remindersProvider);
      final result = await service.executePipeline(
        trimmed,
        settings: settings,
        existingTasks: existingTasks,
      );
      _check(generation);
      await _saveTasks(result.scheduledTasks, generation);
      return result;
    } catch (error) {
      _reportError(generation, '多智能体协同处理异常: $error');
      rethrow;
    } finally {
      _finishPending(operation);
    }
  }

  Future<bool> processText(
    String text, {
    DateTime? reminderTime,
    bool memoOnly = false,
    String? captureId,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final generation = _beginInput();
    if (generation == null) {
      return false;
    }
    if (trimmed.startsWith('/agent ') || trimmed.startsWith('/goal ')) {
      final goal = trimmed.replaceFirst(RegExp(r'^/(agent|goal)\s+'), '');
      if (goal.isNotEmpty) {
        try {
          await _processWithMultiAgent(goal, generation);
        } catch (_) {
          // The same generation owns both the command and its error state.
          return false;
        }
        return true;
      }
    }
    final settings = _ref.read(settingsProvider);
    final parsed = QuickReminderParser.parse(trimmed);
    final time = memoOnly ? null : reminderTime ?? parsed;
    if (time != null && !time.isAfter(DateTime.now())) {
      _reportError(
        generation,
        AppLocalizations(Locale(settings.language)).get('chooseFutureTime'),
      );
      return false;
    }
    final existing = _ref
        .read(remindersProvider)
        .where((r) => r.id == captureId)
        .firstOrNull;
    if (existing != null) return existing.sourceText == trimmed;
    final local = Reminder(
      id: captureId ?? const Uuid().v4(),
      taskTitle: String.fromCharCodes(trimmed.runes.take(80)),
      taskSummary: trimmed,
      sourceText: trimmed,
      quadrantLevel: 2,
      triggerTime: time,
      eventTime: parsed,
      capturePending: settings.hasConfiguredExtraction && !memoOnly,
    );
    final saving = _startPending(generation);
    var nativeFailed = false;
    try {
      final result = await _ref
          .read(remindersProvider.notifier)
          .addReminderForGeneration(local, generation);
      _check(generation);
      nativeFailed = result.nativeSyncFailed;
    } catch (_) {
      _reportError(generation, '事项未能完整保存，输入内容已保留，请检查本地存储后重试。');
      _finishPending(saving);
      return false;
    }
    if (local.capturePending) retryCapture(local);
    _finishPending(saving);
    if (nativeFailed) {
      _reportError(
        generation,
        AppLocalizations(
          Locale(settings.language),
        ).get('reminderNativeSyncFailed'),
      );
    }
    return true;
  }

  final Set<String> _activeCaptures = {};
  bool isCaptureRunning(String id) => _activeCaptures.contains(id);

  void retryCapture(Reminder task) {
    final generation = _beginInput();
    if (generation == null ||
        !task.capturePending ||
        task.sourceText == null ||
        !_activeCaptures.add(task.id)) {
      return;
    }
    _launch(
      generation,
      () async {
        try {
          final service = _ref.read(llmServiceProvider);
          final tasks = await service.extractTasks(
            task.sourceText!,
            _ref.read(settingsProvider),
          );
          _check(generation);
          final result = await _ref
              .read(remindersProvider.notifier)
              .enrichCapture(task, tasks, generation);
          if (result.nativeSyncFailures > 0) {
            _reportError(
              generation,
              AppLocalizations(
                Locale(_ref.read(settingsProvider).language),
              ).get('reminderNativeSyncFailed'),
            );
          }
        } finally {
          _activeCaptures.remove(task.id);
        }
      },
      failureMessage: '原文已保存在本地，可稍后继续 AI 整理。',
      explainModelError: true,
    );
  }

  Future<bool> startRecording() async {
    final generation = _beginInput();
    if (generation == null) return false;
    try {
      final permitted = await _audioRecorder.hasPermission();
      _check(generation);
      if (!permitted) {
        _reportError(
          generation,
          AppLocalizations(
            Locale(_ref.read(settingsProvider).language),
          ).get('microphonePermissionDenied'),
        );
        return false;
      }
      final tempDir = await _temporaryDirectory();
      _check(generation);
      return await _serializeRecorder(() async {
        _check(generation);
        if (_nativeRecording) return true;
        await tempDir.create(recursive: true);
        _check(generation);
        final path = '${tempDir.path}/audio_${const Uuid().v4()}.m4a';
        try {
          _nativeRecording = true;
          await _audioRecorder.start(const RecordConfig(), path: path);
          _check(generation);
          _recordingGeneration = generation;
          state = state.copyWith(isRecording: true, error: null);
          return true;
        } catch (_) {
          // Native start may have succeeded before the runtime was paused.
          // Cleanup is serialized ahead of the recovery quiesce completion.
          if (_nativeRecording) await _discardRecording();
          rethrow;
        }
      });
    } catch (error) {
      _reportError(generation, '启动录音失败: $error');
      return false;
    }
  }

  Future<({String path, DataGeneration generation})?> _stopCapture() async {
    final generation = _recordingGeneration;
    if (generation == null) return null;
    _recordingGeneration = null;
    try {
      final path = await _serializeRecorder(() async {
        if (!_isCurrent(generation)) {
          await _discardRecording();
          return null;
        }
        final path = await _audioRecorder.stop();
        _nativeRecording = false;
        if (!_isCurrent(generation)) {
          // Stop raced recovery. The result was never confirmed for import.
          if (path != null) {
            final temporary = File(path);
            if (await temporary.exists()) await temporary.delete();
          }
          return null;
        }
        return path;
      });
      if (_isCurrent(generation)) {
        state = state.copyWith(isRecording: false);
        if (path != null) return (path: path, generation: generation);
      }
    } catch (error) {
      if (_isCurrent(generation)) state = state.copyWith(isRecording: false);
      _reportError(generation, '录音停止异常: $error');
    }
    return null;
  }

  Future<void> stopRecordingAndProcess() async {
    final capture = await _stopCapture();
    if (capture != null) _processAudio(capture.path, capture.generation);
  }

  Future<bool> cancelRecording() async {
    final generation = _recordingGeneration;
    if (generation == null) return false;
    try {
      await _serializeRecorder(_discardRecording);
      if (_isCurrent(generation)) state = state.copyWith(isRecording: false);
      return true;
    } catch (_) {
      _reportError(
        generation,
        AppLocalizations(
          Locale(_ref.read(settingsProvider).language),
        ).get('voiceCancelFailed'),
      );
      return false;
    }
  }

  Future<String> _transcribeCapture(String path) {
    final settings = _ref.read(settingsProvider);
    final local = _ref.read(localSpeechServiceProvider);
    if (local.supported) return local.transcribe(path, settings.language);
    return _ref.read(llmServiceProvider).transcribeAudio(path, settings);
  }

  Future<void> _saveVoiceMemo(
    String path,
    DataGeneration generation, {
    String? recordId,
  }) async {
    final l10n = AppLocalizations(Locale(_ref.read(settingsProvider).language));
    final id = recordId ?? await _saveMedia('audio', path, generation);
    _check(generation);
    await _ref
        .read(remindersProvider.notifier)
        .addReminderForGeneration(
          Reminder(
            id: const Uuid().v4(),
            recordId: id,
            taskTitle: l10n.get('voiceMemoTitle'),
            taskSummary: l10n.get('voiceMemoSummary'),
            quadrantLevel: 2,
            urgencyLevel: 'General',
            importanceLevel: 'Important',
          ),
          generation,
        );
  }

  /// This path returns a draft only. It never extracts or submits tasks from
  /// recognized text. On a genuine recognition failure, preserve an audio memo.
  Future<String?> stopRecordingToText({bool Function()? canAcceptDraft}) async {
    final capture = await _stopCapture();
    if (capture == null) return null;
    final (path: path, generation: generation) = capture;
    if (!_isCurrent(generation)) {
      try {
        await File(path).delete();
      } catch (_) {}
      return null;
    }
    final operation = _startPending(generation);
    var removeTemporary = false;
    try {
      final duration = await const RecordingDurationReader().read(path);
      _check(generation);
      if (duration != null &&
          duration < RecordingDurationReader.minimumCapture) {
        removeTemporary = true;
        _reportError(
          generation,
          AppLocalizations(
            Locale(_ref.read(settingsProvider).language),
          ).get('recordingTooShort'),
        );
        return null;
      }
      final text = await _transcribeCapture(path);
      _check(generation);
      if (text.trim().isEmpty) {
        throw const FormatException('No recognized speech');
      }
      if (canAcceptDraft != null && !canAcceptDraft()) {
        // Preserve the capture if its destination closes during recognition.
        throw StateError('The voice draft input is no longer available.');
      }
      removeTemporary = true;
      return text.trim();
    } catch (error) {
      if (!_isCurrent(generation)) {
        removeTemporary = true;
        return null;
      }
      try {
        final saved = await _saveFileToLocal(path, generation);
        _check(generation);
        await _saveVoiceMemo(saved, generation);
        removeTemporary = true;
        _reportError(
          generation,
          AppLocalizations(Locale(_ref.read(settingsProvider).language)).get(
            error is PlatformException &&
                    error.code == 'speech_permission_denied'
                ? 'voiceSpeechPermissionSaved'
                : 'voiceTextUnavailableSaved',
          ),
        );
      } catch (_) {
        _reportError(
          generation,
          AppLocalizations(
            Locale(_ref.read(settingsProvider).language),
          ).get('voiceMemoSaveFailed'),
        );
      }
      return null;
    } finally {
      if (removeTemporary) {
        try {
          await File(path).delete();
        } catch (_) {
          /* Only our new capture; cache cleanup may retry. */
        }
      }
      _finishPending(operation);
    }
  }

  Future<void> toggleRecording() async {
    if (state.isRecording) {
      await stopRecordingAndProcess();
    } else {
      await startRecording();
    }
  }

  void _processAudio(String path, DataGeneration generation) {
    _launch(
      generation,
      () async {
        final duration = await const RecordingDurationReader().read(path);
        _check(generation);
        if (duration != null &&
            duration < RecordingDurationReader.minimumCapture) {
          // Only this just-finished, unimported capture is discarded. Existing
          // attachments and unrecognized formats are never deleted here.
          await File(path).delete();
          _check(generation);
          _reportError(
            generation,
            AppLocalizations(
              Locale(_ref.read(settingsProvider).language),
            ).get('recordingTooShort'),
          );
          return;
        }
        final savedPath = await _saveFileToLocal(path, generation);
        _check(generation);
        final settings = _ref.read(settingsProvider);
        final service = _ref.read(llmServiceProvider);
        final id = await _saveMedia('audio', savedPath, generation);
        _check(generation);
        try {
          final text = await _transcribeCapture(savedPath);
          _check(generation);
          final tasks = await service.extractTasks(text, settings);
          _check(generation);
          await _saveTasks(tasks, generation, recordId: id);
        } on AudioTranscriptionUnsupportedException catch (_) {
          _check(generation);
          await _saveVoiceMemo(savedPath, generation, recordId: id);
          if (settings.apiKey.trim().isNotEmpty) {
            _reportError(
              generation,
              AppLocalizations(
                Locale(settings.language),
              ).get('voiceTextUnavailableSaved'),
            );
          }
        } on PlatformException catch (error) {
          _check(generation);
          await _saveVoiceMemo(savedPath, generation, recordId: id);
          _reportError(
            generation,
            AppLocalizations(Locale(settings.language)).get(
              error.code == 'speech_permission_denied'
                  ? 'voiceSpeechPermissionSaved'
                  : 'voiceTextUnavailableSaved',
            ),
          );
        }
      },
      failureMessage: '语音解析提示',
      explainModelError: true,
    );
  }

  Future<void> processImageWithSource(ImageSource source) async {
    final generation = _beginInput();
    if (generation == null) {
      return;
    }
    try {
      final selected = await _pickImage(source);
      _check(generation);
      if (selected == null) {
        return;
      }
      _launch(
        generation,
        () async {
          final savedPath = await _saveFileToLocal(selected.path, generation);
          _check(generation);
          final bytes = await File(savedPath).readAsBytes();
          _check(generation);
          final id = await _saveMedia('image', savedPath, generation);
          _check(generation);
          final settings = _ref.read(settingsProvider);
          final service = _ref.read(llmServiceProvider);
          final tasks = await service.extractTasksFromImage(
            base64Encode(bytes),
            settings,
          );
          _check(generation);
          await _saveTasks(tasks, generation, recordId: id);
        },
        failureMessage: '图片识别提示',
        explainModelError: true,
      );
    } catch (error) {
      _reportError(generation, '图片选择失败: $error');
    }
  }

  Future<void> processImage() => processImageWithSource(ImageSource.gallery);

  Future<void> processFile() async {
    final generation = _beginInput();
    if (generation == null) {
      return;
    }
    try {
      final file = await _pickFile();
      _check(generation);
      if (file == null || file.path == null) {
        return;
      }
      _launch(
        generation,
        () async {
          final savedPath = await _saveFileToLocal(file.path!, generation);
          _check(generation);
          final id = await _saveMedia('file', savedPath, generation);
          String content;
          try {
            final saved = File(savedPath);
            final length = await saved.length();
            _check(generation);
            content = length < 500 * 1024
                ? await saved.readAsString()
                : '文档附件: ${file.name} (文件大小: ${(length / 1024).toStringAsFixed(1)} KB)';
          } catch (_) {
            _check(generation);
            content = '文档附件: ${file.name}';
          }
          _check(generation);
          final settings = _ref.read(settingsProvider);
          final tasks = await _ref
              .read(llmServiceProvider)
              .extractTasksFromFile(file.name, content, settings);
          _check(generation);
          await _saveTasks(tasks, generation, recordId: id);
        },
        failureMessage: '文档解析提示',
        explainModelError: true,
      );
    } catch (error) {
      _reportError(generation, '文件选择失败: $error');
    }
  }

  Future<void> processVideo() async {
    final generation = _beginInput();
    if (generation == null) {
      return;
    }
    try {
      final selected = await _pickVideo();
      _check(generation);
      if (selected == null) {
        return;
      }
      _launch(
        generation,
        () async {
          final savedPath = await _saveFileToLocal(selected.path, generation);
          _check(generation);
          final id = await _saveMedia('video', savedPath, generation);
          _check(generation);
          final settings = _ref.read(settingsProvider);
          final tasks = await _ref
              .read(llmServiceProvider)
              .extractTasksFromVideo(selected.name, settings);
          _check(generation);
          await _saveTasks(tasks, generation, recordId: id);
        },
        failureMessage: '视频处理提示',
        explainModelError: true,
      );
    } catch (error) {
      _reportError(generation, '视频选择失败: $error');
    }
  }

  void clearError() {
    if (mounted && _runtime.isCurrent(_birth)) {
      state = state.copyWith(error: null);
    }
  }
}
