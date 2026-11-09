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
        if (!result.isCompleted) result.complete('明天买牛奶');
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
  setUp(() async {
    sqfliteFfiInit();
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
    'recording stays local until upward preparation, then one session feeds previews',
    () async {
      expect(await home.startRecording(), isTrue);
      expect(recorder.config?.encoder, AudioEncoder.pcm16bits);
      expect(recorder.config?.sampleRate, 16000);
      expect(recorder.config?.numChannels, 1);
      recorder.audio!.add(Uint8List(16000));
      expect(speech.starts, 0);
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
      expect(speech.starts, 1);
    },
  );
  test('ordinary recording save never starts cloud recognition', () async {
    await home.startRecording();
    recorder.audio!.add(Uint8List(16000));
    await home.stopRecordingAndProcess();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (container.read(homeControllerProvider).pendingTasksCount > 0 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(homeControllerProvider).pendingTasksCount, 0);
    expect(speech.starts, 0);
    expect(speech.fallbacks, 0);
    expect(container.read(mediaRecordsProvider), hasLength(1));
    expect(container.read(remindersProvider), hasLength(1));
  });
}
