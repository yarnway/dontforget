import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _TestNotifications implements NotificationService {
  final List<Reminder> scheduled = [];

  @override
  Future<void> scheduleReminder(Reminder reminder) async {
    scheduled.add(reminder);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
    recordingPath = null;
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
          return permitted;
        case 'start':
          final path = (call.arguments as Map)['path'] as String;
          if (!await File(path).parent.exists()) {
            throw PlatformException(code: 'missing_recording_directory');
          }
          if (failStart) throw PlatformException(code: 'device_unavailable');
          recordingPath = path;
          return null;
        case 'stop':
          if (produceAudio) {
            // Protocol fixture only; this is not encoded microphone audio.
            await File(recordingPath!).writeAsBytes([1, 5, 1, 2]);
            return recordingPath;
          }
          return null; // No audio file or external AI request in this test.
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
      expect(saved.path, startsWith('${directory.path}/missing/documents/'));
      expect(await saved.readAsBytes(), [1, 5, 1, 2]);
      expect(notifications.scheduled, hasLength(1));
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(container.read(homeControllerProvider).error, contains('已创建原声任务'));
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
}
