import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  final _audioRecorder = AudioRecorder();
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
  }) : _database = _ref.read(databaseHelperProvider),
       _pickImage =
           pickImage ?? ((source) => ImagePicker().pickImage(source: source)),
       _pickVideo =
           pickVideo ??
           (() => ImagePicker().pickVideo(source: ImageSource.gallery)),
       _pickFile = pickFile ?? (() => FilePicker.pickFile(type: FileType.any)),
       _importFile = importFile ?? LocalMediaStore().importFile,
       super(HomeState());

  @override
  void dispose() {
    _audioRecorder.dispose();
    super.dispose();
  }

  bool _isCurrent(DataGeneration generation) =>
      mounted && _database.isCurrent(generation);

  void _check(DataGeneration generation) {
    _database.checkGeneration(generation);
    if (!mounted) {
      throw StateError('Input controller is no longer active.');
    }
  }

  DataGeneration? _beginInput() {
    if (!mounted) {
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
    if (mounted) {
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
      await _ref
          .read(remindersProvider.notifier)
          .addReminderForGeneration(saved, generation);
      _check(generation);
      final notifications = _ref.read(notificationServiceProvider);
      await _database.runOperation(generation, () async {
        _check(generation);
        await notifications.scheduleReminder(saved);
      });
      _check(generation);
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

  Future<void> processText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final generation = _beginInput();
    if (generation == null) {
      return;
    }
    if (trimmed.startsWith('/agent ') || trimmed.startsWith('/goal ')) {
      final goal = trimmed.replaceFirst(RegExp(r'^/(agent|goal)\s+'), '');
      if (goal.isNotEmpty) {
        try {
          await _processWithMultiAgent(goal, generation);
        } catch (_) {
          // The same generation owns both the command and its error state.
        }
        return;
      }
    }
    _launch(generation, () async {
      final settings = _ref.read(settingsProvider);
      if (settings.apiKey.trim().isEmpty) {
        await _saveLocalText(trimmed, generation);
        return;
      }
      final service = _ref.read(llmServiceProvider);
      List<Reminder> tasks;
      try {
        tasks = await service.extractTasks(trimmed, settings);
      } catch (error) {
        // A failed old request must not create a fallback in a restored DB.
        _check(generation);
        await _saveLocalText(trimmed, generation);
        _reportError(
          generation,
          '${service.formatErrorMessage(error)}\n已保存为本地事项，请在详情中设置提醒时间。',
        );
        return;
      }
      _check(generation);
      if (tasks.isEmpty) {
        await _saveLocalText(trimmed, generation);
      } else {
        await _saveTasks(tasks, generation);
      }
    }, failureMessage: '事项未能完整保存，请检查本地存储后重试。');
  }

  Future<void> _saveLocalText(String text, DataGeneration generation) async {
    _check(generation);
    await _ref
        .read(remindersProvider.notifier)
        .addReminderForGeneration(
          Reminder(
            id: const Uuid().v4(),
            taskTitle: text.length > 25 ? '${text.substring(0, 25)}...' : text,
            taskSummary: text,
            quadrantLevel: 2,
            urgencyLevel: 'General',
            importanceLevel: 'Important',
          ),
          generation,
        );
    _check(generation);
  }

  Future<bool> startRecording() async {
    final generation = _beginInput();
    if (generation == null) {
      return false;
    }
    var started = false;
    try {
      final permitted = await _audioRecorder.hasPermission();
      _check(generation);
      if (!permitted) {
        return false;
      }
      final tempDir = await getTemporaryDirectory();
      _check(generation);
      await _database.runOperation(generation, () async {
        await tempDir.create(recursive: true);
        _check(generation);
        final path =
            '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(const RecordConfig(), path: path);
        started = true;
      });
      _check(generation);
      _recordingGeneration = generation;
      state = state.copyWith(isRecording: true, error: null);
      return true;
    } catch (error) {
      if (started) {
        try {
          await _audioRecorder.stop();
        } catch (_) {}
      }
      _reportError(generation, '启动录音失败: $error');
      return false;
    }
  }

  Future<void> stopRecordingAndProcess() async {
    final generation = _recordingGeneration;
    if (!mounted || !state.isRecording || generation == null) {
      return;
    }
    _recordingGeneration = null;
    try {
      // Stopping an old native capture is cleanup; it never obtains a new data
      // ticket. Its payload can only be processed under the original ticket.
      final path = await _audioRecorder.stop();
      if (mounted) {
        state = state.copyWith(isRecording: false);
      }
      if (path != null && _isCurrent(generation)) {
        _processAudio(path, generation);
      }
    } catch (error) {
      if (mounted) {
        state = state.copyWith(isRecording: false);
      }
      _reportError(generation, '录音停止异常: $error');
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
        final savedPath = await _saveFileToLocal(path, generation);
        _check(generation);
        final settings = _ref.read(settingsProvider);
        final service = _ref.read(llmServiceProvider);
        final id = await _saveMedia('audio', savedPath, generation);
        try {
          final text = await service.transcribeAudio(savedPath, settings);
          _check(generation);
          final tasks = await service.extractTasks(text, settings);
          _check(generation);
          await _saveTasks(tasks, generation, recordId: id);
        } on AudioTranscriptionUnsupportedException catch (error) {
          _check(generation);
          final now = DateTime.now();
          final nowStr =
              '${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          await _ref
              .read(remindersProvider.notifier)
              .addReminderForGeneration(
                Reminder(
                  id: const Uuid().v4(),
                  recordId: id,
                  taskTitle: '语音待办 ($nowStr)',
                  taskSummary: '原声录音已保存，点击左侧麦克风图标可随时回放',
                  quadrantLevel: 2,
                  urgencyLevel: 'General',
                  importanceLevel: 'Important',
                ),
                generation,
              );
          _check(generation);
          if (settings.apiKey.trim().isNotEmpty) {
            _reportError(generation, '${error.message} (已创建原声任务，请手动设置提醒时间)');
          }
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
    if (mounted) {
      state = state.copyWith(error: null);
    }
  }
}
