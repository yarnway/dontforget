import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/local_speech_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/m4a_metadata_fixture.dart';

class _TestNotifications implements NotificationService {
  final List<Reminder> scheduled = [];

  @override
  Future<void> scheduleReminder(Reminder reminder) async {
    scheduled.add(reminder);
  }

  @override
  Future<void> scheduleReminderStrict(Reminder reminder) =>
      scheduleReminder(reminder);
  @override
  Future<void> cancelReminderStrict(String id) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PreviewModel extends LLMService {
  @override
  Future<List<Reminder>> extractTasks(
    String text,
    AppSettings settings,
  ) async => [
    Reminder(id: 'model-audio', taskTitle: 'Audio proposal', quadrantLevel: 2),
  ];
}

class _Speech extends LocalSpeechService {
  _Speech() : super(isIOS: false);
  bool enabled = false;
  int calls = 0, cancels = 0;
  Object? error;
  Completer<String>? pending;
  @override
  bool get supported => enabled;
  @override
  Future<String> transcribe(String path, String language) async {
    calls++;
    if (error != null) throw error!;
    return pending == null ? '明日9時に予定を確認' : await pending!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recorder = MethodChannel('com.llfbandit.record/messages');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late ProviderContainer container;
  late List<MethodCall> calls;
  late Completer<void> disposed;
  bool permitted = true;
  bool failStart = false;
  late String temporaryPath;
  late DatabaseHelper database;
  late _TestNotifications notifications;
  String? recordingPath;
  bool produceAudio = false;
  int captureMillis = 2000;
  late _Speech speech;
  Completer<bool>? permissionReply;
  Completer<void>? nativeStartReply;

  test(
    'background completion keeps feedback until it is explicitly cleared',
    () {
      final state = HomeState(pendingTasksCount: 1, error: 'local audio saved');
      expect(state.copyWith(pendingTasksCount: 0).error, 'local audio saved');
      expect(state.copyWith(error: null).error, isNull);
    },
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dontforget-recording-');
    calls = [];
    disposed = Completer<void>();
    permitted = true;
    failStart = false;
    produceAudio = false;
    captureMillis = 2000;
    recordingPath = null;
    speech = _Speech();
    permissionReply = null;
    nativeStartReply = null;
    // path_provider may return a bundle-specific macOS cache path that does
    // not exist yet. The native recorder does not create parent directories.
    temporaryPath = '${directory.path}/missing/cache';
    messenger.setMockMethodCallHandler(paths, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return '${directory.path}/missing/documents';
      }
      return temporaryPath;
    });
    messenger.setMockMethodCallHandler(recorder, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'create':
          return null;
        case 'hasPermission':
          return permissionReply == null
              ? permitted
              : await permissionReply!.future;
        case 'start':
          final path = (call.arguments as Map)['path'] as String;
          if (!await File(path).parent.exists()) {
            throw PlatformException(code: 'missing_recording_directory');
          }
          if (failStart) throw PlatformException(code: 'device_unavailable');
          if (nativeStartReply != null) await nativeStartReply!.future;
          recordingPath = path;
          return null;
        case 'stop':
          if (produceAudio) {
            await File(
              recordingPath!,
            ).writeAsBytes(m4aMetadata(ticks: captureMillis));
            return recordingPath;
          }
          return null; // No audio file or external AI request in this test.
        case 'cancel':
          return null; // Discard an unconfirmed native start.
        case 'dispose':
          disposed.complete();
          return null;
        default:
          throw UnsupportedError(call.method);
      }
    });
    sqfliteFfiInit();
    database = DatabaseHelper.forTesting(
      '${directory.path}/database',
      databaseFactoryFfi,
    );
    notifications = _TestNotifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        localSpeechServiceProvider.overrideWithValue(speech),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    container.read(homeControllerProvider);
  });

  tearDown(() async {
    container.dispose();
    await disposed.future;
    await database.close();
    messenger.setMockMethodCallHandler(recorder, null);
    messenger.setMockMethodCallHandler(paths, null);
    await directory.delete(recursive: true);
  });

  test(
    'recording readiness waits for the native mic and deduplicates starts',
    () async {
      permissionReply = Completer<bool>();
      nativeStartReply = Completer<void>();
      final home = container.read(homeControllerProvider.notifier);
      final first = home.startRecording();
      final second = home.startRecording();
      expect(identical(first, second), isTrue);
      expect(home.state.isPreparingRecording, isTrue);
      expect(home.state.isRecording, isFalse);
      permissionReply!.complete(true);
      for (var i = 0; i < 100 && !calls.any((c) => c.method == 'start'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(calls.where((c) => c.method == 'hasPermission').length, 1);
      expect(calls.where((c) => c.method == 'start').length, 1);
      expect(home.state.isPreparingRecording, isTrue);
      expect(home.state.isRecording, isFalse);
      nativeStartReply!.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(home.state.isPreparingRecording, isFalse);
      expect(home.state.isRecording, isTrue);
      expect(await home.cancelRecording(), isTrue);
      expect(home.state.isRecording, isFalse);
      expect(container.read(remindersProvider), isEmpty);
    },
  );

  test(
    'denied mic resets readiness without starting or saving audio',
    () async {
      permitted = false;
      final home = container.read(homeControllerProvider.notifier);
      expect(await home.startRecording(), isFalse);
      expect(home.state.isPreparingRecording, isFalse);
      expect(home.state.isRecording, isFalse);
      expect(calls.where((c) => c.method == 'start'), isEmpty);
      expect(container.read(remindersProvider), isEmpty);
    },
  );

  test(
    'recording uses explicit AAC config and stops without inventing an audio file',
    () async {
      final controller = container.read(homeControllerProvider.notifier);
      expect(await controller.startRecording(), isTrue);
      expect(container.read(homeControllerProvider).isRecording, isTrue);
      final start = calls.singleWhere((call) => call.method == 'start');
      final args = start.arguments as Map;
      expect(args['path'], startsWith(directory.path));
      expect(args['path'], endsWith('.m4a'));
      expect(args['encoder'], 'aacLc');
      await controller.stopRecordingAndProcess();
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(container.read(homeControllerProvider).pendingTasksCount, 0);
      expect(calls.where((call) => call.method == 'stop'), hasLength(1));
    },
  );

  test('permission denial does not start recording', () async {
    permitted = false;
    expect(
      await container.read(homeControllerProvider.notifier).startRecording(),
      isFalse,
    );
    expect(container.read(homeControllerProvider).isRecording, isFalse);
    expect(calls.where((call) => call.method == 'start'), isEmpty);
    expect(container.read(homeControllerProvider).error, contains('麦克风权限未开启'));
  });

  test(
    'cancel discards capture without stop, imports, transcription or tasks',
    () async {
      speech.enabled = true;
      final controller = container.read(homeControllerProvider.notifier);
      expect(await controller.startRecording(), isTrue);
      expect(await controller.cancelRecording(), isTrue);
      expect(calls.where((c) => c.method == 'cancel'), hasLength(1));
      expect(calls.where((c) => c.method == 'stop'), isEmpty);
      expect(speech.calls, 0);
      expect(controller.state.isRecording, isFalse);
      final db = await database.database;
      expect(await db.query('Reminders'), isEmpty);
      expect(await db.query('MediaRecords'), isEmpty);
    },
  );

  test(
    'text disposition returns editable text without importing or extracting tasks',
    () async {
      speech.enabled = true;
      produceAudio = true;
      final controller = container.read(homeControllerProvider.notifier);
      await controller.startRecording();
      expect(await controller.stopRecordingToText(), '明日9時に予定を確認');
      expect(speech.calls, 1);
      final db = await database.database;
      expect(await db.query('Reminders'), isEmpty);
      expect(await db.query('MediaRecords'), isEmpty);
      expect(await File(recordingPath!).exists(), isFalse);
      expect(controller.state.pendingTasksCount, 0);
    },
  );

  test(
    'closing the draft destination preserves the recording instead of losing it',
    () async {
      speech.enabled = true;
      produceAudio = true;
      final controller = container.read(homeControllerProvider.notifier);
      await controller.startRecording();
      expect(
        await controller.stopRecordingToText(canAcceptDraft: () => false),
        isNull,
      );
      final db = await database.database;
      final media = (await db.query('MediaRecords')).single;
      final task = (await db.query('Reminders')).single;
      expect(task['record_id'], media['id']);
      expect(task['trigger_time'], isNull);
      expect(
        await File(media['content_or_path'] as String).readAsBytes(),
        m4aMetadata(ticks: captureMillis),
      );
      expect(await File(recordingPath!).exists(), isFalse);
      expect(controller.state.pendingTasksCount, 0);
    },
  );

  test(
    'text permission failure preserves an accessible raw memo without cloud fallback',
    () async {
      speech.enabled = true;
      speech.error = PlatformException(code: 'speech_permission_denied');
      produceAudio = true;
      final controller = container.read(homeControllerProvider.notifier);
      await controller.startRecording();
      expect(await controller.stopRecordingToText(), isNull);
      final db = await database.database;
      final media = (await db.query('MediaRecords')).single;
      final task = (await db.query('Reminders')).single;
      expect(task['record_id'], media['id']);
      expect(
        await File(media['content_or_path'] as String).readAsBytes(),
        m4aMetadata(ticks: captureMillis),
      );
      expect(task['trigger_time'], isNull);
      expect(controller.state.error, contains('语音识别权限未开启'));
      expect(await File(recordingPath!).exists(), isFalse);
    },
  );

  test('text disposition rejects short audio before recognition', () async {
    speech.enabled = true;
    produceAudio = true;
    captureMillis = 22;
    final controller = container.read(homeControllerProvider.notifier);
    await controller.startRecording();
    expect(await controller.stopRecordingToText(), isNull);
    expect(speech.calls, 0);
    expect(await File(recordingPath!).exists(), isFalse);
    expect(await (await database.database).query('Reminders'), isEmpty);
  });

  test('recovery cancels speech and rejects a late editable result', () async {
    speech.enabled = true;
    speech.pending = Completer<String>();
    produceAudio = true;
    final controller = container.read(homeControllerProvider.notifier);
    await controller.startRecording();
    final result = controller.stopRecordingToText();
    for (var i = 0; i < 100 && speech.calls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(speech.calls, 1);
    await container.read(runtimeRecoveryGateProvider).pause();
    speech.pending!.complete('Do not insert this stale text');
    expect(await result, isNull);
    expect(speech.cancels, 1);
    expect(await File(recordingPath!).exists(), isFalse);
    expect(await (await database.database).query('Reminders'), isEmpty);
  });

  test(
    'unwritable cache path fails before activating the native recorder',
    () async {
      final blocker = File('${directory.path}/not-a-directory');
      await blocker.writeAsString('preserve');
      temporaryPath = '${blocker.path}/cache';
      expect(
        await container.read(homeControllerProvider.notifier).startRecording(),
        isFalse,
      );
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(container.read(homeControllerProvider).error, contains('启动录音失败'));
      expect(calls.where((call) => call.method == 'start'), isEmpty);
      expect(await blocker.readAsString(), 'preserve');
    },
  );

  test(
    'recording without an AI key remains an accessible local audio memo',
    () async {
      produceAudio = true;
      final finished = Completer<void>();
      final subscription = container.listen(homeControllerProvider, (
        before,
        after,
      ) {
        if ((before?.pendingTasksCount ?? 0) > 0 &&
            after.pendingTasksCount == 0 &&
            !finished.isCompleted) {
          finished.complete();
        }
      });
      final controller = container.read(homeControllerProvider.notifier);
      expect(await controller.startRecording(), isTrue);
      await controller.stopRecordingAndProcess();
      await finished.future.timeout(const Duration(seconds: 5));
      subscription.close();

      final db = await database.database;
      final media = await db.query('MediaRecords');
      final reminders = await db.query('Reminders');
      expect(media, hasLength(1));
      expect(reminders, hasLength(1));
      expect(reminders.single['record_id'], media.single['id']);
      expect(media.single['type'], 'audio');
      final saved = File(media.single['content_or_path'] as String);
      expect(
        p.isWithin(p.join(directory.path, 'missing', 'documents'), saved.path),
        isTrue,
      );
      expect(await saved.readAsBytes(), m4aMetadata(ticks: captureMillis));
      expect(notifications.scheduled, isEmpty);
      expect(reminders.single['trigger_time'], isNull);
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(container.read(homeControllerProvider).error, isNull);
    },
  );

  test(
    'short capture is discarded without a task, media import or model work',
    () async {
      produceAudio = true;
      captureMillis = 22;
      final finished = Completer<void>();
      final subscription = container.listen(homeControllerProvider, (
        before,
        after,
      ) {
        if ((before?.pendingTasksCount ?? 0) > 0 &&
            after.pendingTasksCount == 0) {
          if (!finished.isCompleted) finished.complete();
        }
      });
      final controller = container.read(homeControllerProvider.notifier);
      expect(await controller.startRecording(), isTrue);
      await controller.stopRecordingAndProcess();
      await finished.future.timeout(const Duration(seconds: 5));
      subscription.close();
      final db = await database.database;
      expect(await db.query('MediaRecords'), isEmpty);
      expect(await db.query('Reminders'), isEmpty);
      expect(await File(recordingPath!).exists(), isFalse);
      expect(notifications.scheduled, isEmpty);
      expect(controller.state.isRecording, isFalse);
      expect(controller.state.pendingTasksCount, 0);
      expect(controller.state.error, contains('录音过短，未创建任务'));
      expect(
        Directory('${directory.path}/missing/documents/media').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'local text entry is quiet and does not invent a reminder time',
    () async {
      final controller = container.read(homeControllerProvider.notifier);
      final errors = <String>[];
      final finished = Completer<void>();
      final subscription = container.listen(homeControllerProvider, (
        before,
        after,
      ) {
        if (after.error != null) errors.add(after.error!);
        if ((before?.pendingTasksCount ?? 0) > 0 &&
            after.pendingTasksCount == 0 &&
            !finished.isCompleted) {
          finished.complete();
        }
      });
      await controller.processText('买牛奶');
      await finished.future.timeout(const Duration(seconds: 5));
      subscription.close();
      final db = await database.database;
      final rows = await db.query('Reminders');
      expect(rows, hasLength(1));
      expect(rows.single['task_summary'], '买牛奶');
      expect(rows.single['trigger_time'], isNull);
      expect(errors, isEmpty);
      expect(notifications.scheduled, isEmpty);
    },
  );

  test(
    'local text write failure remains visible and is not retried as success',
    () async {
      final db = await database.database;
      await db.execute(
        "CREATE TRIGGER fail_save BEFORE INSERT ON Reminders BEGIN SELECT RAISE(ABORT, 'disk failure'); END",
      );
      final finished = Completer<void>();
      final subscription = container.listen(homeControllerProvider, (
        before,
        after,
      ) {
        if ((before?.pendingTasksCount ?? 0) > 0 &&
            after.pendingTasksCount == 0 &&
            !finished.isCompleted) {
          finished.complete();
        }
      });
      await container
          .read(homeControllerProvider.notifier)
          .processText('保存失败样本');
      await finished.future.timeout(const Duration(seconds: 5));
      subscription.close();
      expect(await db.query('Reminders'), isEmpty);
      expect(container.read(homeControllerProvider).error, contains('未能完整保存'));
      expect(notifications.scheduled, isEmpty);
    },
  );

  test(
    'native start failure leaves recording off and reports an error',
    () async {
      failStart = true;
      expect(
        await container.read(homeControllerProvider.notifier).startRecording(),
        isFalse,
      );
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(
        container.read(homeControllerProvider).error,
        contains('device_unavailable'),
      );
    },
  );
  test(
    'audio keeps its original file and waits for extraction confirmation',
    () async {
      container.dispose();
      await disposed.future;
      disposed = Completer<void>();
      final model = _PreviewModel();
      container = ProviderContainer(
        overrides: [
          databaseHelperProvider.overrideWithValue(database),
          notificationServiceProvider.overrideWithValue(notifications),
          localSpeechServiceProvider.overrideWithValue(speech),
          llmServiceProvider.overrideWithValue(model),
        ],
      );
      await container.read(settingsProvider.notifier).ready;
      await container
          .read(settingsProvider.notifier)
          .updateSettings(
            container.read(settingsProvider).copyWith(apiKey: 'synthetic-only'),
          );
      await container.read(remindersProvider.notifier).ready;
      await container.read(mediaRecordsProvider.notifier).ready;
      speech.enabled = true;
      produceAudio = true;
      final home = container.read(homeControllerProvider.notifier);
      final done = Completer<void>();
      var sawPending = false;
      final stop = home.addListener((state) {
        if (state.pendingTasksCount > 0) sawPending = true;
        if (sawPending && state.pendingTasksCount == 0 && !done.isCompleted) {
          done.complete();
        }
      }, fireImmediately: false);
      expect(await home.startRecording(), isTrue);
      await home.stopRecordingAndProcess();
      await done.future.timeout(const Duration(seconds: 5));
      stop();
      final raw = container.read(remindersProvider).single;
      expect(raw.captureProposalJson, isNotNull);
      expect(raw.recordId, isNotNull);
      expect(raw.sourceText, '明日9時に予定を確認');
      expect(raw.taskTitle, isNot('Audio proposal'));
      final record = container.read(mediaRecordsProvider).single;
      expect(await File(record.contentOrPath).exists(), isTrue);
      final proposal = (jsonDecode(raw.captureProposalJson!) as List)
          .map(
            (row) => Reminder.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList();
      await container
          .read(remindersProvider.notifier)
          .applyCaptureProposal(raw, proposal);
      expect(
        container.read(remindersProvider).single.taskTitle,
        'Audio proposal',
      );
      expect(container.read(remindersProvider).single.recordId, record.id);
      model.dispose();
    },
  );
}
