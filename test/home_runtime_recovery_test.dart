import 'support/workspace_drafts.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/agent_models.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/services/multi_agent_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/home_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/recovery/runtime_gate.dart';
import 'package:dont_forget/services/mac_menu_commands.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Llm extends LLMService {
  String? receivedText;
  final started = Completer<void>();
  final result = Completer<List<Reminder>>();
  @override
  Future<List<Reminder>> extractTasks(String text, AppSettings settings) {
    receivedText = text;
    started.complete();
    return result.future;
  }
}

class _Agent extends MultiAgentService {
  final started = Completer<void>();
  final result = Completer<MultiAgentExecutionResult>();
  bool disposed = false;
  @override
  Future<MultiAgentExecutionResult> executePipeline(
    String input, {
    AppSettings? settings,
    List<Reminder>? existingTasks,
    String language = 'zh',
  }) {
    started.complete();
    return result.future;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _Recorder implements AudioRecorder {
  Completer<void>? startRelease;
  Completer<String?>? stopRelease;
  final started = Completer<void>();
  final stopped = Completer<void>();
  int cancels = 0;
  bool cancelFails = false;
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    started.complete();
    await startRelease?.future;
  }

  @override
  Future<String?> stop() async {
    stopped.complete();
    return await stopRelease?.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (cancelFails) throw StateError('native cancellation failed');
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late RuntimeRecoveryGate gate;
  late _Recorder recorder;
  ProviderContainer? container;

  Future<HomeController> controller({
    _Llm? llm,
    _Agent? agent,
    Future<XFile?> Function(ImageSource)? picker,
  }) async {
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        runtimeRecoveryGateProvider.overrideWithValue(gate),
        if (llm != null) llmServiceProvider.overrideWithValue(llm),
        notificationServiceProvider.overrideWithValue(
          NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ),
        if (agent != null)
          multiAgentServiceProvider.overrideWith((ref) {
            ref.onDispose(agent.dispose);
            return agent;
          }),
        homeControllerProvider.overrideWith(
          (ref) => HomeController(
            ref,
            pickImage: picker,
            audioRecorder: recorder,
            temporaryDirectory: () async => directory,
          ),
        ),
      ],
    );
    await container!.read(settingsProvider.notifier).ready;
    await container!.read(workspaceDraftsProvider.notifier).ready;
    await container!
        .read(workspaceDraftsProvider.notifier)
        .put('homeView', 'board');
    if (llm != null) {
      await container!
          .read(settingsProvider.notifier)
          .updateSettings(
            container!.read(settingsProvider).copyWith(apiKey: 'isolated-test'),
          );
    }
    await container!.read(remindersProvider.notifier).ready;
    await container!.read(mediaRecordsProvider.notifier).ready;
    return container!.read(homeControllerProvider.notifier);
  }

  Future<List<Map<String, Object?>>> rows(String table) =>
      database.read(database.captureGeneration(), (db) => db.query(table));

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('home-runtime-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    gate = RuntimeRecoveryGate();
    recorder = _Recorder();
  });
  tearDown(() async {
    container?.dispose();
    container = null;
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'native confirmation uses the existing model pipeline and persists one task',
    () async {
      const channel = MethodChannel('dontforget/mac_commands');
      const codec = StandardMethodCodec();
      final llm = _Llm();
      final home = await controller(llm: llm);
      final idle = Completer<void>();
      final listener = container!.listen(homeControllerProvider, (_, state) {
        if (llm.started.isCompleted &&
            state.pendingTasksCount == 0 &&
            !idle.isCompleted) {
          idle.complete();
        }
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async =>
                call.method == 'showInput' ? '  明天下午三点检查报告  ' : null,
          );
      final commands = MacMenuCommands<RuntimeRecoveryToken>(
        beginInput: () async => gate.capture(),
        isCurrent: gate.isCurrent,
        submitInput: home.processText,
        openSettings: () => false,
      )..start();
      try {
        await commands.configure({}, enabled: true);
        final reply = Completer<ByteData?>();
        ui.channelBuffers.push(
          channel.name,
          codec.encodeMethodCall(const MethodCall('quickInput')),
          reply.complete,
        );
        expect(codec.decodeEnvelope((await reply.future)!), true);
        await llm.started.future;
        expect(llm.receivedText, '明天下午三点检查报告');
        llm.result.complete([
          Reminder(
            id: 'native-model-result',
            taskTitle: '检查报告',
            quadrantLevel: 2,
          ),
        ]);
        await idle.future.timeout(const Duration(seconds: 5));
        final saved = await rows('Reminders');
        expect(saved, hasLength(1));
        expect(saved.single['source_text'], '明天下午三点检查报告');
        expect(saved.single['task_title'], '检查报告');
        expect(saved.single['capture_proposal_json'], isNull);
        final raw = container!.read(remindersProvider).single;
        expect(raw.capturePending, isFalse);
        expect(raw.triggerTime, raw.eventTime);
        expect(raw.timeOrigin, ReminderTimeOrigin.manual);
        expect(raw.details.history.last.action, 'capture_auto_applied');
        expect((await rows('Reminders')).single['task_title'], '检查报告');
        expect(home.state.error, isNull);
      } finally {
        commands.dispose();
        listener.close();
        await Future<void>.delayed(Duration.zero);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );

  test(
    'pause does not await AI; late response and old controller input stay invalid after resume',
    () async {
      final llm = _Llm();
      final home = await controller(llm: llm);
      await home.processText('old input');
      await llm.started.future;
      final token = await gate.pause().timeout(const Duration(seconds: 2));
      expect(home.state.pendingTasksCount, 0);
      gate.resume(token);
      llm.result.complete([
        Reminder(id: 'old-result', taskTitle: 'old', quadrantLevel: 2),
      ]);
      await home.processText('late old controller input');
      await Future<void>.delayed(Duration.zero);
      expect((await rows('Reminders')).single['source_text'], 'old input');
      expect(home.state.error, isNull);
    },
  );

  test('a late file picker cannot import after runtime resume', () async {
    final selection = Completer<XFile?>();
    final home = await controller(picker: (_) => selection.future);
    final picking = home.processImage();
    final token = await gate.pause();
    gate.resume(token);
    selection.complete(XFile('${directory.path}/does-not-exist.jpg'));
    await picking;
    expect(await rows('MediaRecords'), isEmpty);
    expect(home.state.error, isNull);
  });

  test(
    'pause waits native start then cancels without importing its capture',
    () async {
      recorder.startRelease = Completer<void>();
      final home = await controller();
      final starting = home.startRecording();
      await recorder.started.future;
      var paused = false;
      final pausing = gate.pause().then((token) {
        paused = true;
        return token;
      });
      await Future<void>.delayed(Duration.zero);
      expect(paused, isFalse);
      recorder.startRelease!.complete();
      expect(await starting, isFalse);
      final token = await pausing;
      expect(recorder.cancels, 1);
      expect(home.state.isRecording, isFalse);
      expect(await rows('MediaRecords'), isEmpty);
      gate.resume(token);
    },
  );

  test(
    'native cleanup failure blocks recovery and retry performs cleanup',
    () async {
      final home = await controller();
      expect(await home.startRecording(), isTrue);
      recorder.cancelFails = true;
      await expectLater(gate.pause(), throwsStateError);
      expect(gate.paused, isTrue);
      recorder.cancelFails = false;
      final token = await gate.pause();
      expect(recorder.cancels, 2);
      expect(await rows('MediaRecords'), isEmpty);
      gate.resume(token);
    },
  );

  test(
    'stop racing recovery deletes the unconfirmed temporary capture',
    () async {
      final audio = File('${directory.path}/capture.m4a');
      await audio.writeAsString('isolated capture');
      recorder.stopRelease = Completer<String?>();
      final home = await controller();
      expect(await home.startRecording(), isTrue);
      final stopping = home.stopRecordingAndProcess();
      await recorder.stopped.future;
      final pausing = gate.pause();
      recorder.stopRelease!.complete(audio.path);
      await stopping;
      final token = await pausing;
      expect(await audio.exists(), isFalse);
      expect(await rows('MediaRecords'), isEmpty);
      gate.resume(token);
    },
  );

  test(
    'controller constructed while paused remains inert after resume',
    () async {
      final token = await gate.pause();
      final home = await controller();
      gate.resume(token);
      await home.processText('must not be saved');
      expect(await rows('Reminders'), isEmpty);
      container!.invalidate(homeControllerProvider);
      final fresh = container!.read(homeControllerProvider.notifier);
      await fresh.processText('new session');
      for (var i = 0; i < 50 && fresh.state.pendingTasksCount > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await rows('Reminders')).single['task_title'], 'new session');
    },
  );

  for (final recovering in [false, true]) {
    testWidgets(
      'relocated playback ${recovering ? 'stops at recovery boundary' : 'uses the current container'}',
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final channels = <MethodChannel>[
          const MethodChannel('xyz.luan/audioplayers.global'),
          const MethodChannel('xyz.luan/audioplayers.global/events'),
          const MethodChannel('xyz.luan/audioplayers'),
          const MethodChannel('plugins.flutter.io/path_provider'),
        ];
        final requested = Completer<void>();
        final release = Completer<String>();
        final sources = <String>[];
        for (final channel in channels.take(2)) {
          messenger.setMockMethodCallHandler(channel, (_) async => null);
        }
        messenger.setMockMethodCallHandler(channels[2], (call) async {
          if (call.method == 'create') {
            final events = MethodChannel(
              'xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}',
            );
            channels.add(events);
            messenger.setMockMethodCallHandler(events, (_) async => null);
          }
          if (call.method == 'setSourceUrl') {
            sources.add((call.arguments as Map)['url'] as String);
            // Simulated native preparation; this is not audio output evidence.
            await messenger.handlePlatformMessage(
              'xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'event': 'audio.onPrepared',
                'value': true,
              }),
              (_) {},
            );
          }
          return null;
        });
        messenger.setMockMethodCallHandler(channels[3], (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            if (!requested.isCompleted) requested.complete();
            return release.future;
          }
          return directory.path;
        });
        addTearDown(() {
          for (final channel in channels) {
            messenger.setMockMethodCallHandler(channel, null);
          }
        });
        final currentPath =
            '${directory.path}/Documents/media/import-saved/audio.m4a';
        await tester.runAsync(() async {
          await File(currentPath).create(recursive: true);
          final db = await database.database;
          await db.insert(
            'MediaRecords',
            MediaRecord(
              id: 'voice',
              type: 'audio',
              createdAt: DateTime.utc(2026, 10, 26),
              contentOrPath:
                  '/old-container/Documents/media/import-saved/audio.m4a',
            ).toJson(),
          );
          await db.insert(
            'Reminders',
            Reminder(
              id: 'voice-task',
              recordId: 'voice',
              taskTitle: 'Saved recording',
              quadrantLevel: 2,
            ).toJson(),
          );
          await controller();
        });
        addTearDown(() => drainWorkspaceDrafts(tester, container!));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container!,
            child: MaterialApp(
              localizationsDelegates: const [AppLocalizationsDelegate()],
              builder: (_, child) => InlineFeedback(child: child!),
              home: const HomeScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.mic_none));
        for (var i = 0; i < 40 && !requested.isCompleted; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        expect(requested.isCompleted, isTrue);
        await tester.runAsync(() async {
          if (recovering) {
            final token = await gate.pause();
            gate.resume(token);
          }
          release.complete('${directory.path}/Documents');
        });
        for (var i = 0; i < 40 && sources.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        await tester.pump();
        expect(sources, recovering ? isEmpty : [currentPath]);
        expect(tester.takeException(), isNull);
        final stored = await tester.runAsync(() => rows('MediaRecords'));
        expect(
          stored!.single['content_or_path'],
          '/old-container/Documents/media/import-saved/audio.m4a',
        );
        addTearDown(() => drainWorkspaceDrafts(tester, container!));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'multi-agent launch consumes a late shutdown failure after recovery',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final audioChannels = <MethodChannel>[
        const MethodChannel('xyz.luan/audioplayers.global'),
        const MethodChannel('xyz.luan/audioplayers.global/events'),
        const MethodChannel('xyz.luan/audioplayers'),
      ];
      for (final channel in audioChannels.take(2)) {
        messenger.setMockMethodCallHandler(channel, (_) async => null);
      }
      messenger.setMockMethodCallHandler(audioChannels.last, (call) async {
        if (call.method == 'create') {
          final playerId = (call.arguments as Map)['playerId'];
          final channel = MethodChannel(
            'xyz.luan/audioplayers/events/$playerId',
          );
          audioChannels.add(channel);
          messenger.setMockMethodCallHandler(channel, (_) async => null);
        }
        return null;
      });
      addTearDown(() {
        for (final channel in audioChannels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      final agent = _Agent();
      await tester.runAsync(() => controller(agent: agent));
      addTearDown(() => drainWorkspaceDrafts(tester, container!));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container!,
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (_, child) => InlineFeedback(child: child!),
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('目标规划'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('agent-goal-input')),
        '旧会话待处理项目',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('规划目标'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('规划目标'));
      await tester.pump();
      expect(agent.started.isCompleted, isTrue);
      await drainWorkspaceDrafts(tester, container!);
      await tester.runAsync(() async {
        final token = await gate.pause();
        container!.invalidate(multiAgentServiceProvider);
        expect(agent.disposed, isTrue);
        gate.resume(token);
        agent.result.completeError(StateError('old transport was closed'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(await tester.runAsync(() => rows('Reminders')), isEmpty);
      addTearDown(() => drainWorkspaceDrafts(tester, container!));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
