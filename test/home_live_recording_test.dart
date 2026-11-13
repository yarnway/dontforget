import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:record/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/speech_settings.dart';
import 'package:dont_forget/models/tencent_speech_credentials.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/speech_recognition_service.dart';

class _Recorder implements AudioRecorder {
  StreamController<Uint8List>? audio;
  RecordConfig? config;
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    this.config = config;
    audio = StreamController<Uint8List>.broadcast(sync: true);
    return audio!.stream;
  }

  @override
  Future<String?> stop() async {
    await audio?.close();
    return null;
  }

  @override
  Future<void> cancel() async {
    await audio?.close();
  }

  @override
  Future<void> dispose() async {
    await audio?.close();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Speech extends SpeechRecognitionService {
  int starts = 0, fallbacks = 0;
  Completer<String>? deferredFinal;
  void Function(String)? preview;
  CancelToken? token;
  @override
  LiveSpeechSession startRealtime(
    Stream<List<int>> Function(CancelToken) audio,
    SpeechSettings settings, {
    required void Function(String) onText,
  }) {
    starts++;
    preview = onText;
    final cancellation = CancelToken();
    token = cancellation;
    final result = Completer<String>();
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    audio(cancellation).listen(
      (_) {},
      onDone: () {
        if (deferredFinal != null) {
          deferredFinal!.future.then(
            (value) {
              if (!result.isCompleted) result.complete(value);
            },
            onError: (Object error) {
              if (!result.isCompleted) result.completeError(error);
            },
          );
        } else if (!result.isCompleted) {
          result.complete('明天买牛奶');
        }
      },
      onError: (Object error) {
        if (!result.isCompleted) result.completeError(error);
      },
    );
    return LiveSpeechSession(result.future, () => cancellation.cancel());
  }

  @override
  Future<String> transcribe(
    String path,
    SpeechSettings settings, {
    CancelToken? cancelToken,
  }) async {
    fallbacks++;
    return 'fallback';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DatabaseHelper db;
  late ProviderContainer container;
  late _Recorder recorder;
  late _Speech speech;
  late HomeController home;
  var failImport = false;
  var imports = 0;
  setUp(() async {
    sqfliteFfiInit();
    failImport = false;
    imports = 0;
    root = await Directory.systemTemp.createTemp('home-live-');
    db = DatabaseHelper.forTesting('${root.path}/database', databaseFactoryFfi);
    recorder = _Recorder();
    speech = _Speech();
    final notifications = NotificationService.forTesting(
      FlutterLocalNotificationsPlugin(),
      usesNativeNotifications: false,
    );
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(notifications),
        speechRecognitionServiceProvider.overrideWithValue(speech),
        homeControllerProvider.overrideWith(
          (ref) => HomeController(
            ref,
            audioRecorder: recorder,
            importFile: (path) async {
              imports++;
              if (failImport) {
                throw const FileSystemException('Fixture full disk');
              }
              final media = await Directory(
                '${root.path}/media',
              ).create(recursive: true);
              return (await File(path).copy('${media.path}/saved.wav')).path;
            },
            temporaryDirectory: () async =>
                Directory('${root.path}/recordings'),
          ),
        ),
        remindersProvider.overrideWith(
          (_) => RemindersNotifier(
            db,
            notifications: notifications,
            runLoadEffects: false,
          ),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    await container.read(mediaRecordsProvider.notifier).ready;
    final notifier = container.read(settingsProvider.notifier);
    await notifier.updateSettings(
      notifier.state.copyWith(
        speech: SpeechSettings(
          enabled: true,
          apiKey: const TencentSpeechCredentials(
            appId: '1259000000',
            secretId: 'AKIDTESTID12345678',
            secretKey: 'unit-key',
          ).encode(),
        ),
      ),
    );
    home = container.read(homeControllerProvider.notifier);
  });
  tearDown(() async {
    await home.cancelRecording();
    container.dispose();
    // Disposal serializes recorder cleanup before closing its test directory.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await db.close(createBackup: false);
    await root.delete(recursive: true);
  });
  test(
    'enabled realtime recognition starts with capture before the upward gesture',
    () async {
      expect(await home.startRecording(), isTrue);
      expect(recorder.config?.encoder, AudioEncoder.pcm16bits);
      expect(recorder.config?.sampleRate, 16000);
      expect(recorder.config?.numChannels, 1);
      recorder.audio!.add(Uint8List(16000));
      expect(speech.starts, 1);
      home.prepareRecordingTranscription();
      home.prepareRecordingTranscription();
      expect(speech.starts, 1);
      speech.preview!('正在识别');
      expect(container.read(homeControllerProvider).voicePreview, '正在识别');
      expect(await home.stopRecordingToText(), '明天买牛奶');
      expect(speech.fallbacks, 0);
      expect(container.read(remindersProvider), isEmpty);
      expect(container.read(mediaRecordsProvider), isEmpty);
      expect(Directory('${root.path}/recordings').listSync(), isEmpty);
    },
  );
  test(
    'cancel recognition discards owned PCM and ignores a late callback',
    () async {
      await home.startRecording();
      recorder.audio!.add(Uint8List(16000));
      home.prepareRecordingTranscription();
      final callback = speech.preview!;
      expect(await home.cancelRecording(), isTrue);
      expect(speech.token!.isCancelled, isTrue);
      expect(Directory('${root.path}/recordings').listSync(), isEmpty);
      await home.startRecording();
      callback('stale previous recording');
      expect(container.read(homeControllerProvider).voicePreview, isEmpty);
      expect(speech.starts, 2);
    },
  );
  test('ordinary save cancels the already prepared realtime session', () async {
    await home.startRecording();
    recorder.audio!.add(Uint8List(16000));
    await home.stopRecordingAndProcess();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (container.read(homeControllerProvider).pendingTasksCount > 0 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(homeControllerProvider).pendingTasksCount, 0);
    expect(speech.starts, 1);
    expect(speech.token!.isCancelled, isTrue);
    expect(speech.fallbacks, 0);
    expect(container.read(mediaRecordsProvider), hasLength(1));
    expect(container.read(remindersProvider), hasLength(1));
  });

  Future<void> waitFor(bool Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!predicate() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(predicate(), isTrue);
  }

  Future<void> capturePending() async {
    speech.deferredFinal = Completer<String>();
    unawaited(
      speech.deferredFinal!.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
    expect(await home.startRecording(), isTrue);
    recorder.audio!.add(
      Uint8List.fromList(List.generate(64000, (i) => i % 256)),
    );
  }

  test(
    'original audio sends once before final ASR and retains exact WAV bytes',
    () async {
      await capturePending();
      final draft = home.createVoiceTextDraft();
      final first = draft.sendOriginal();
      expect(identical(first, draft.sendOriginal()), isTrue);
      expect(await first.timeout(const Duration(seconds: 5)), isTrue);
      expect(await draft.sendOriginal(), isTrue);
      expect(speech.deferredFinal!.isCompleted, isFalse);
      final sql = await db.database;
      final media = (await sql.query('MediaRecords')).single;
      final reminder = (await sql.query('Reminders')).single;
      expect(reminder['record_id'], media['id']);
      final original = File(media['content_or_path'] as String);
      final bytes = await original.readAsBytes();
      expect(bytes.sublist(44), List.generate(64000, (i) => i % 256));
      expect(imports, 1);
      expect(speech.fallbacks, 0);
      await draft.release();
      expect(Directory('${root.path}/recordings').listSync(), hasLength(1));
      speech.deferredFinal!.complete('late text must not become another task');
      expect(await draft.result, isNull);
      await waitFor(
        () => Directory('${root.path}/recordings').listSync().isEmpty,
      );
      expect(await original.readAsBytes(), bytes);
      expect(await sql.query('MediaRecords'), hasLength(1));
      expect(await sql.query('Reminders'), hasLength(1));
    },
  );

  test(
    'sending edited text does not wait for ASR or delete an active reader',
    () async {
      await capturePending();
      final draft = home.createVoiceTextDraft();
      await draft.release(sentText: true).timeout(const Duration(seconds: 5));
      await waitFor(() => !container.read(homeControllerProvider).isRecording);
      expect(Directory('${root.path}/recordings').listSync(), hasLength(1));
      speech.deferredFinal!.complete('finished later');
      expect(await draft.result, 'finished later');
      await waitFor(
        () => Directory('${root.path}/recordings').listSync().isEmpty,
      );
      final sql = await db.database;
      expect(await sql.query('MediaRecords'), isEmpty);
      expect(await sql.query('Reminders'), isEmpty);
      expect(imports, 0);
      expect(await draft.sendOriginal(), isFalse);
    },
  );

  test(
    'failed ASR stays editable and closing preserves only one audio memo',
    () async {
      await capturePending();
      final draft = home.createVoiceTextDraft();
      speech.deferredFinal!.completeError(
        StateError('fixture recognition failure'),
      );
      expect(await draft.result, isNull);
      final sql = await db.database;
      expect(await sql.query('MediaRecords'), isEmpty);
      await Future.wait([draft.release(), draft.release()]);
      await waitFor(
        () => Directory('${root.path}/recordings').listSync().isEmpty,
      );
      expect(await sql.query('MediaRecords'), hasLength(1));
      expect(await sql.query('Reminders'), hasLength(1));
      expect(imports, 1);
    },
  );

  test(
    'original save failure can retry without losing or duplicating the recording',
    () async {
      await capturePending();
      final draft = home.createVoiceTextDraft();
      failImport = true;
      expect(await draft.sendOriginal(), isFalse);
      expect(Directory('${root.path}/recordings').listSync(), hasLength(1));
      failImport = false;
      expect(await draft.sendOriginal(), isTrue);
      speech.deferredFinal!.complete('late');
      await draft.release();
      await waitFor(
        () => Directory('${root.path}/recordings').listSync().isEmpty,
      );
      final sql = await db.database;
      expect(await sql.query('MediaRecords'), hasLength(1));
      expect(await sql.query('Reminders'), hasLength(1));
      expect(imports, 2);
    },
  );

  test('too short editor capture cannot be sent as original audio', () async {
    expect(await home.startRecording(), isTrue);
    recorder.audio!.add(Uint8List(64));
    final draft = home.createVoiceTextDraft();
    expect(await draft.result, isNull);
    expect(await draft.sendOriginal(), isFalse);
    await draft.release();
    await waitFor(
      () => Directory('${root.path}/recordings').listSync().isEmpty,
    );
    expect(imports, 0);
  });

  test('memo database failure retries the same media identity', () async {
    await capturePending();
    final draft = home.createVoiceTextDraft();
    final sql = await db.database;
    await sql.execute(
      "CREATE TRIGGER fail_voice_memo BEFORE INSERT ON Reminders BEGIN SELECT RAISE(ABORT, 'fixture memo failure'); END",
    );
    expect(await draft.sendOriginal(), isFalse);
    final mediaBefore = (await sql.query('MediaRecords')).single;
    expect(await sql.query('Reminders'), isEmpty);
    expect(Directory('${root.path}/recordings').listSync(), hasLength(1));
    await sql.execute('DROP TRIGGER fail_voice_memo');
    expect(await draft.sendOriginal(), isTrue);
    expect(await sql.query('MediaRecords'), [mediaBefore]);
    expect(
      (await sql.query('Reminders')).single['record_id'],
      mediaBefore['id'],
    );
    speech.deferredFinal!.complete('late final');
    await draft.release();
    await waitFor(
      () => Directory('${root.path}/recordings').listSync().isEmpty,
    );
    expect(imports, 1);
  });

  test(
    'recovery invalidates a retained capture before original send',
    () async {
      await capturePending();
      final draft = home.createVoiceTextDraft();
      await waitFor(() => !container.read(homeControllerProvider).isRecording);
      await container.read(runtimeRecoveryGateProvider).pause();
      expect(await draft.sendOriginal(), isFalse);
      speech.deferredFinal!.complete('stale generation');
      expect(await draft.result, isNull);
      await draft.release();
      await waitFor(
        () => Directory('${root.path}/recordings').listSync().isEmpty,
      );
      expect(imports, 0);
      expect(await (await db.database).query('Reminders'), isEmpty);
    },
  );
}
