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
import 'providers.dart';

class HomeState {
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
    String? error,
  }) {
    return HomeState(
      isLoading: isLoading ?? this.isLoading,
      isRecording: isRecording ?? this.isRecording,
      pendingTasksCount: pendingTasksCount ?? this.pendingTasksCount,
      error: error,
    );
  }
}

final homeControllerProvider = StateNotifierProvider<HomeController, HomeState>((ref) {
  return HomeController(ref);
});

class HomeController extends StateNotifier<HomeState> {
  final Ref _ref;
  final _audioRecorder = Record();

  HomeController(this._ref) : super(HomeState());

  @override
  void dispose() {
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<String> _saveFileToLocal(String tempPath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final fileName = tempPath.split(Platform.pathSeparator).last;
    final savedPath = '${appDir.path}/$fileName';
    await File(tempPath).copy(savedPath);
    return savedPath;
  }

  Future<MultiAgentExecutionResult> processWithMultiAgent(String complexGoal) async {
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
      final goalContent = trimmed.replaceFirst(RegExp(r'^/(agent|goal)\s+'), '');
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

    // Asynchronously execute in background
    Future(() async {
      final llmService = _ref.read(llmServiceProvider);
      try {
        final settings = _ref.read(settingsProvider);
        final notificationService = _ref.read(notificationServiceProvider);
        
        final tasks = await llmService.extractTasks(trimmed, settings);
        
        if (tasks.isEmpty) {
          // Fallback if model returns empty tasks
          final fallbackReminder = Reminder(
            id: const Uuid().v4(),
            taskTitle: trimmed.length > 25 ? '${trimmed.substring(0, 25)}...' : trimmed,
            taskSummary: trimmed,
            quadrantLevel: 2,
            urgencyLevel: 'General',
            importanceLevel: 'Important',
            triggerTime: DateTime.now().add(const Duration(hours: 2)),
          );
          await _ref.read(remindersProvider.notifier).addReminder(fallbackReminder);
          await notificationService.scheduleReminder(fallbackReminder);
        } else {
          for (var task in tasks) {
            await _ref.read(remindersProvider.notifier).addReminder(task);
            await notificationService.scheduleReminder(task);
          }
        }
      } catch (e) {
        final friendlyMsg = llmService.formatErrorMessage(e);
        // Zero data loss: Auto-save task as fallback with auto-generated reminder time
        final fallbackReminder = Reminder(
          id: const Uuid().v4(),
          taskTitle: trimmed.length > 25 ? '${trimmed.substring(0, 25)}...' : trimmed,
          taskSummary: trimmed,
          quadrantLevel: 2,
          urgencyLevel: 'General',
          importanceLevel: 'Important',
          triggerTime: DateTime.now().add(const Duration(hours: 2)),
        );
        await _ref.read(remindersProvider.notifier).addReminder(fallbackReminder);
        await _ref.read(notificationServiceProvider).scheduleReminder(fallbackReminder);
        
        state = state.copyWith(
          error: '$friendlyMsg\n(已为您直接创建任务，您可随时在卡片中编辑详情)',
        );
      } finally {
        final remaining = (state.pendingTasksCount - 1).clamp(0, 999);
        state = state.copyWith(pendingTasksCount: remaining);
      }
    });
  }

  Future<bool> startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(path: path);
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
          final nowStr = '${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          final voiceReminder = Reminder(
            id: const Uuid().v4(),
            recordId: uuid,
            taskTitle: '语音待办 ($nowStr)',
            taskSummary: '原声录音已保存，点击左侧麦克风图标可随时回放',
            quadrantLevel: 2,
            urgencyLevel: 'General',
            importanceLevel: 'Important',
            triggerTime: now.add(const Duration(hours: 2)),
          );
          await _ref.read(remindersProvider.notifier).addReminder(voiceReminder);
          await notificationService.scheduleReminder(voiceReminder);
          state = state.copyWith(error: '${ex.message} (已创建原声任务)');
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
        
        final tasks = await llmService.extractTasksFromImage(base64Image, settings);

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
      final file = await FilePicker.pickFile(
        type: FileType.any,
      );
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
              fileContent = '文档附件: $fileName (文件大小: ${(len / 1024).toStringAsFixed(1)} KB)';
            }
          } catch (_) {
            fileContent = '文档附件: $fileName';
          }

          final settings = _ref.read(settingsProvider);
          final llmService = _ref.read(llmServiceProvider);
          final notificationService = _ref.read(notificationServiceProvider);

          final tasks = await llmService.extractTasksFromFile(fileName, fileContent, settings);

          for (var task in tasks) {
            final t = task.copyWith(recordId: uuid);
            await _ref.read(remindersProvider.notifier).addReminder(t);
            await notificationService.scheduleReminder(t);
          }
        } catch (e) {
          final friendlyMsg = _ref.read(llmServiceProvider).formatErrorMessage(e);
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

          final tasks = await llmService.extractTasksFromVideo(xFile.name, settings);

          for (var task in tasks) {
            final t = task.copyWith(recordId: uuid);
            await _ref.read(remindersProvider.notifier).addReminder(t);
            await notificationService.scheduleReminder(t);
          }
        } catch (e) {
          final friendlyMsg = _ref.read(llmServiceProvider).formatErrorMessage(e);
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
