import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
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
  final _audioRecorder = AudioRecorder();

  HomeController(this._ref) : super(HomeState());

  @override
  void dispose() {
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<String> _saveFileToLocal(String tempPath) =>
      LocalMediaStore().importFile(tempPath);

  Future<MultiAgentExecutionResult> processWithMultiAgent(
    String complexGoal,
  ) async {
    final trimmed = complexGoal.trim();
    if (trimmed.isEmpty) {
      throw Exception('目标内容不能为空');
    }

    state = state.copyWith(
      pendingTasksCount: state.pendingTasksCount + 1,
      error: null,
    );

    try {
      final multiAgentService = _ref.read(multiAgentServiceProvider);
      final settings = _ref.read(settingsProvider);
      final existingTasks = _ref.read(remindersProvider);
      final notificationService = _ref.read(notificationServiceProvider);

      final result = await multiAgentService.executePipeline(
        trimmed,
        settings: settings,
        existingTasks: existingTasks,
      );

      for (final task in result.scheduledTasks) {
        await _ref.read(remindersProvider.notifier).addReminder(task);
        await notificationService.scheduleReminder(task);
      }

      return result;
    } catch (e) {
      state = state.copyWith(error: '多智能体协同处理异常: $e');
      rethrow;
    } finally {
      final remaining = (state.pendingTasksCount - 1).clamp(0, 999);
      state = state.copyWith(pendingTasksCount: remaining);
    }
  }

  Future<void> processText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // 支持通过 /agent 或 /goal 指令触发三智能体微型协作流水线
    if (trimmed.startsWith('/agent ') || trimmed.startsWith('/goal ')) {
      final goalContent = trimmed.replaceFirst(
        RegExp(r'^/(agent|goal)\s+'),
        '',
      );
      if (goalContent.isNotEmpty) {
        try {
          await processWithMultiAgent(goalContent);
          return;
        } catch (_) {
          // Error already set in state
          return;
        }
      }
    }

    // Immediately update background count so UI stays completely non-blocking
    state = state.copyWith(
      pendingTasksCount: state.pendingTasksCount + 1,
      error: null,
    );

    // Saving locally without an AI account is a supported mode, not an error.
    Future(() async {
      try {
        final settings = _ref.read(settingsProvider);
        if (settings.apiKey.trim().isEmpty) {
          await _saveLocalText(trimmed);
          return;
        }
        final llmService = _ref.read(llmServiceProvider);
        List<Reminder> tasks;
        try {
          tasks = await llmService.extractTasks(trimmed, settings);
        } catch (e) {
          await _saveLocalText(trimmed);
          state = state.copyWith(
            error: '${llmService.formatErrorMessage(e)}\n已保存为本地事项，请在详情中设置提醒时间。',
          );
          return;
        }
        if (tasks.isEmpty) {
          await _saveLocalText(trimmed);
        } else {
          for (final task in tasks) {
            await _ref.read(remindersProvider.notifier).addReminder(task);
            await _ref.read(notificationServiceProvider).scheduleReminder(task);
          }
        }
      } catch (_) {
        // A storage failure must not be reported as a successful local fallback.
        state = state.copyWith(error: '事项未能完整保存，请检查本地存储后重试。');
      } finally {
        final remaining = (state.pendingTasksCount - 1).clamp(0, 999);
        state = state.copyWith(pendingTasksCount: remaining);
      }
    });
  }

  Future<void> _saveLocalText(String text) async {
    await _ref
        .read(remindersProvider.notifier)
        .addReminder(
          Reminder(
            id: const Uuid().v4(),
            taskTitle: text.length > 25 ? '${text.substring(0, 25)}...' : text,
            taskSummary: text,
            quadrantLevel: 2,
            urgencyLevel: 'General',
            importanceLevel: 'Important',
            // Parsing did not supply a time. Never invent a two-hour reminder.
          ),
        );
  }

  Future<bool> startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        // On macOS this may be a bundle-specific cache directory that has not
        // been created yet. AVFoundation can accept start and then fail to
        // create the audio file asynchronously, leaving stop without a result.
        await tempDir.create(recursive: true);
        final path =
            '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(const RecordConfig(), path: path);
        state = state.copyWith(isRecording: true, error: null);
        return true;
      }
    } catch (e) {
      state = state.copyWith(error: '启动录音失败: $e');
    }
    return false;
  }

  Future<void> stopRecordingAndProcess() async {
    try {
      if (state.isRecording) {
        final path = await _audioRecorder.stop();
        state = state.copyWith(isRecording: false);
        if (path != null) {
          _processAudio(path);
        }
      }
    } catch (e) {
      state = state.copyWith(isRecording: false, error: '录音停止异常: $e');
    }
  }

  Future<void> toggleRecording() async {
    if (state.isRecording) {
      await stopRecordingAndProcess();
    } else {
      await startRecording();
    }
  }

  Future<void> _processAudio(String path) async {
    state = state.copyWith(
      pendingTasksCount: state.pendingTasksCount + 1,
      error: null,
    );
    Future(() async {
      try {
        final savedPath = await _saveFileToLocal(path);
        final settings = _ref.read(settingsProvider);
        final llmService = _ref.read(llmServiceProvider);
        final notificationService = _ref.read(notificationServiceProvider);

        final uuid = const Uuid().v4();
        final mediaRecord = MediaRecord(
          id: uuid,
          type: 'audio',
          contentOrPath: savedPath,
          createdAt: DateTime.now(),
        );
        await _ref.read(mediaRecordsProvider.notifier).addRecord(mediaRecord);

        try {
          final text = await llmService.transcribeAudio(savedPath, settings);
          final tasks = await llmService.extractTasks(text, settings);

          for (var task in tasks) {
            final t = task.copyWith(recordId: uuid);
            await _ref.read(remindersProvider.notifier).addReminder(t);
            await notificationService.scheduleReminder(t);
          }
        } on AudioTranscriptionUnsupportedException catch (ex) {
          // Graceful fallback for models without whisper (like DeepSeek)
          final now = DateTime.now();
          final nowStr =
              '${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          final voiceReminder = Reminder(
            id: const Uuid().v4(),
            recordId: uuid,
            taskTitle: '语音待办 ($nowStr)',
            taskSummary: '原声录音已保存，点击左侧麦克风图标可随时回放',
            quadrantLevel: 2,
            urgencyLevel: 'General',
            importanceLevel: 'Important',
          );
          await _ref
              .read(remindersProvider.notifier)
              .addReminder(voiceReminder);
          if (settings.apiKey.trim().isNotEmpty) {
            state = state.copyWith(error: '${ex.message} (已创建原声任务，请手动设置提醒时间)');
          }
        }
      } catch (e) {
        final friendlyMsg = _ref.read(llmServiceProvider).formatErrorMessage(e);
        state = state.copyWith(error: '语音解析提示: $friendlyMsg');
      } finally {
        final remaining = (state.pendingTasksCount - 1).clamp(0, 999);
        state = state.copyWith(pendingTasksCount: remaining);
      }
    });
  }

  Future<void> processImageWithSource(ImageSource source) async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(source: source);
    if (xFile == null) return;

    state = state.copyWith(
      pendingTasksCount: state.pendingTasksCount + 1,
      error: null,
    );
    Future(() async {
      try {
        final savedPath = await _saveFileToLocal(xFile.path);
        final bytes = await File(savedPath).readAsBytes();
        final base64Image = base64Encode(bytes);

        final uuid = const Uuid().v4();
        final mediaRecord = MediaRecord(
          id: uuid,
          type: 'image',
          contentOrPath: savedPath,
          createdAt: DateTime.now(),
        );
        await _ref.read(mediaRecordsProvider.notifier).addRecord(mediaRecord);

        final settings = _ref.read(settingsProvider);
        final llmService = _ref.read(llmServiceProvider);
        final notificationService = _ref.read(notificationServiceProvider);

        final tasks = await llmService.extractTasksFromImage(
          base64Image,
          settings,
        );

        for (var task in tasks) {
          final t = task.copyWith(recordId: uuid);
          await _ref.read(remindersProvider.notifier).addReminder(t);
          await notificationService.scheduleReminder(t);
        }
      } catch (e) {
        final friendlyMsg = _ref.read(llmServiceProvider).formatErrorMessage(e);
        state = state.copyWith(error: '图片识别提示: $friendlyMsg');
      } finally {
        final remaining = (state.pendingTasksCount - 1).clamp(0, 999);
        state = state.copyWith(pendingTasksCount: remaining);
      }
    });
  }

  Future<void> processImage() async {
    await processImageWithSource(ImageSource.gallery);
  }

  Future<void> processFile() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.any);
      if (file == null || file.path == null) return;

      final originalPath = file.path!;
      final fileName = file.name;

      state = state.copyWith(
        pendingTasksCount: state.pendingTasksCount + 1,
        error: null,
      );

      Future(() async {
        try {
          final savedPath = await _saveFileToLocal(originalPath);
          final uuid = const Uuid().v4();
          final mediaRecord = MediaRecord(
            id: uuid,
            type: 'file',
            contentOrPath: savedPath,
            createdAt: DateTime.now(),
          );
          await _ref.read(mediaRecordsProvider.notifier).addRecord(mediaRecord);

          String fileContent = '';
          try {
            final f = File(savedPath);
            final len = await f.length();
            if (len < 500 * 1024) {
              fileContent = await f.readAsString();
            } else {
              fileContent =
                  '文档附件: $fileName (文件大小: ${(len / 1024).toStringAsFixed(1)} KB)';
            }
          } catch (_) {
            fileContent = '文档附件: $fileName';
          }

          final settings = _ref.read(settingsProvider);
          final llmService = _ref.read(llmServiceProvider);
          final notificationService = _ref.read(notificationServiceProvider);

          final tasks = await llmService.extractTasksFromFile(
            fileName,
            fileContent,
            settings,
          );

          for (var task in tasks) {
            final t = task.copyWith(recordId: uuid);
            await _ref.read(remindersProvider.notifier).addReminder(t);
            await notificationService.scheduleReminder(t);
          }
        } catch (e) {
          final friendlyMsg = _ref
              .read(llmServiceProvider)
              .formatErrorMessage(e);
          state = state.copyWith(error: '文档解析提示: $friendlyMsg');
        } finally {
          final remaining = (state.pendingTasksCount - 1).clamp(0, 999);
          state = state.copyWith(pendingTasksCount: remaining);
        }
      });
    } catch (e) {
      state = state.copyWith(error: '文件选择失败: $e');
    }
  }

  Future<void> processVideo() async {
    try {
      final picker = ImagePicker();
      final xFile = await picker.pickVideo(source: ImageSource.gallery);
      if (xFile == null) return;

      state = state.copyWith(
        pendingTasksCount: state.pendingTasksCount + 1,
        error: null,
      );

      Future(() async {
        try {
          final savedPath = await _saveFileToLocal(xFile.path);
          final uuid = const Uuid().v4();
          final mediaRecord = MediaRecord(
            id: uuid,
            type: 'video',
            contentOrPath: savedPath,
            createdAt: DateTime.now(),
          );
          await _ref.read(mediaRecordsProvider.notifier).addRecord(mediaRecord);

          final settings = _ref.read(settingsProvider);
          final llmService = _ref.read(llmServiceProvider);
          final notificationService = _ref.read(notificationServiceProvider);

          final tasks = await llmService.extractTasksFromVideo(
            xFile.name,
            settings,
          );

          for (var task in tasks) {
            final t = task.copyWith(recordId: uuid);
            await _ref.read(remindersProvider.notifier).addReminder(t);
            await notificationService.scheduleReminder(t);
          }
        } catch (e) {
          final friendlyMsg = _ref
              .read(llmServiceProvider)
              .formatErrorMessage(e);
          state = state.copyWith(error: '视频处理提示: $friendlyMsg');
        } finally {
          final remaining = (state.pendingTasksCount - 1).clamp(0, 999);
          state = state.copyWith(pendingTasksCount: remaining);
        }
      });
    } catch (e) {
      state = state.copyWith(error: '视频选择失败: $e');
    }
  }

  void clearError() {
    state = state.copyWith(error: null);
  }
}
