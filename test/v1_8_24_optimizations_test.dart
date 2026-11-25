import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/dp_scheduler_service.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/local_speech_service.dart';
import 'package:dont_forget/services/multi_agent_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/quick_reminder_parser.dart';
import 'package:dont_forget/services/voice_text_draft.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:dont_forget/ui/widgets/unsaved_editor_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/interaction_preview.dart';
import 'support/workspace_drafts.dart';

class _StreamRecorder implements AudioRecorder {
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

class _SilentNotifications implements NotificationService {
  @override
  Future<void> scheduleReminderStrict(Reminder task) async {}

  @override
  Future<void> cancelReminderStrict(String id) async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _WhisperStubLlm extends LLMService {
  final List<String> snapshotPaths = [];

  @override
  Future<String> transcribeAudio(
    String audioFilePath,
    AppSettings settings, {
    String language = 'zh',
  }) async {
    final file = File(audioFilePath);
    expect(await file.exists(), isTrue);
    final bytes = await file.readAsBytes();
    // Verify valid RIFF WAVE header on progressive in-hold snapshot.
    expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
    snapshotPaths.add(audioFilePath);
    return snapshotPaths.length == 1 ? '上滑右转实时识别中' : '上滑右转实时识别完成';
  }
}

class _GestureCaptureHome extends HomeController {
  _GestureCaptureHome(super.ref) : super(audioRecorder: _StreamRecorder());

  int gestureTranscriptionStarts = 0;

  @override
  Future<bool> startRecording() async {
    state = HomeState(isRecording: true);
    return true;
  }

  @override
  void prepareRecordingTranscription() {}

  @override
  void startGestureTranscription() {
    gestureTranscriptionStarts++;
    state = state.copyWith(
      isLiveTranscribing: true,
      voicePreview: '正在边按住边转写',
    );
  }

  @override
  VoiceTextDraft createVoiceTextDraft() => VoiceTextDraft(
    result: stopRecordingToText(),
    saveOriginal: () async => true,
    releaseCapture: (_) async {},
  );

  @override
  Future<String?> stopRecordingToText({bool Function()? canAcceptDraft}) async {
    state = state.copyWith(isRecording: false, isLiveTranscribing: false);
    return '正在边按住边转写';
  }

  @override
  Future<bool> cancelRecording() async {
    state = HomeState();
    return true;
  }
}

class _FakeMultiAgentAdapter implements HttpClientAdapter {
  _FakeMultiAgentAdapter(this.responses);
  final List<Map<String, dynamic>> responses;
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final payload = responses[_index < responses.length ? _index++ : responses.length - 1];
    final body = jsonEncode({
      'choices': [
        {
          'message': {'content': jsonEncode(payload)},
        },
      ],
    });
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadInteractionPreviewFonts);

  group('Immediate swipe-up-right live transcription', () {
    const channel = MethodChannel('test/v1_8_24_local_speech');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
      'LocalSpeechService.startLive streams PCM and emits partial text before release',
      () async {
        final calls = <MethodCall>[];
        int? activeSessionId;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'startStream') {
            activeSessionId = (call.arguments as Map)['sessionId'] as int;
          } else if (call.method == 'finishStream') {
            return '明天下午三点二十开会';
          }
          return null;
        });

        final service = LocalSpeechService(
          isIOS: false,
          isAndroid: true,
          channel: channel,
        );
        final controller = StreamController<List<int>>();
        final partials = <String>[];
        final session = service.startLive(
          (_) => controller.stream,
          'zh',
          onText: partials.add,
        );

        await Future<void>.delayed(Duration.zero);
        expect(activeSessionId, isNotNull);

        controller.add(Uint8List(3200));
        await Future<void>.delayed(Duration.zero);
        expect(calls.map((c) => c.method), containsAll(['startStream', 'pushPcm']));

        // Simulate native on-device recognizer emitting partial text while held.
        final encoded = const StandardMethodCodec().encodeMethodCall(
          MethodCall('onLiveText', {
            'sessionId': activeSessionId,
            'text': ' 明天下午三点 ',
          }),
        );
        await messenger.handlePlatformMessage(channel.name, encoded, (_) {});
        expect(partials, ['明天下午三点']);

        await controller.close();
        expect(await session.result, '明天下午三点二十开会');
      },
    );

    test(
      'HomeController.startGestureTranscription starts local live stream immediately while holding',
      () async {
        sqfliteFfiInit();
        final root = await Directory.systemTemp.createTemp('gesture-local-');
        final db = DatabaseHelper.forTesting(
          '${root.path}/db',
          databaseFactoryFfi,
        );
        final recorder = _StreamRecorder();
        var streamStarts = 0;
        int? sessionId;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startStream') {
            streamStarts++;
            sessionId = (call.arguments as Map)['sessionId'] as int;
          } else if (call.method == 'finishStream') {
            return '上滑右转即时转写成功';
          }
          return null;
        });
        final localSpeech = LocalSpeechService(
          isIOS: false,
          isAndroid: true,
          channel: channel,
        );
        final container = ProviderContainer(
          overrides: [
            databaseHelperProvider.overrideWithValue(db),
            notificationServiceProvider.overrideWithValue(_SilentNotifications()),
            localSpeechServiceProvider.overrideWithValue(localSpeech),
            homeControllerProvider.overrideWith(
              (ref) => HomeController(
                ref,
                audioRecorder: recorder,
                temporaryDirectory: () async => root,
                importFile: (p) async => p,
              ),
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await db.close(createBackup: false);
          await root.delete(recursive: true);
        });
        await container.read(settingsProvider.notifier).ready;
        await container.read(remindersProvider.notifier).ready;
        final home = container.read(homeControllerProvider.notifier);

        expect(await home.startRecording(), isTrue);
        // Plain hold before swiping up-right does not start speech recognition.
        expect(streamStarts, 0);

        recorder.audio!.add(Uint8List(20000));
        home.startGestureTranscription();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(streamStarts, 1);
        expect(container.read(homeControllerProvider).isLiveTranscribing, isTrue);

        final partial = const StandardMethodCodec().encodeMethodCall(
          MethodCall('onLiveText', {
            'sessionId': sessionId,
            'text': '上滑右转即时',
          }),
        );
        await messenger.handlePlatformMessage(channel.name, partial, (_) {});
        // Recognized text updates while recording is STILL held (before release)!
        expect(container.read(homeControllerProvider).isRecording, isTrue);
        expect(
          container.read(homeControllerProvider).voicePreview,
          '上滑右转即时',
        );

        expect(await home.stopRecordingToText(), '上滑右转即时转写成功');
      },
    );

    test(
      'createVoiceTextDraft swallows pre-rejected speech_language_unavailable without unhandled Zone errors',
      () async {
        sqfliteFfiInit();
        final root = await Directory.systemTemp.createTemp('gesture-unavail-');
        final db = DatabaseHelper.forTesting(
          '${root.path}/db',
          databaseFactoryFfi,
        );
        final recorder = _StreamRecorder();
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startStream') {
            throw PlatformException(code: 'speech_language_unavailable');
          }
          return null;
        });
        final localSpeech = LocalSpeechService(
          isIOS: false,
          isAndroid: true,
          channel: channel,
        );
        final unhandled = <Object>[];
        await runZonedGuarded(
          () async {
            final container = ProviderContainer(
              overrides: [
                databaseHelperProvider.overrideWithValue(db),
                notificationServiceProvider.overrideWithValue(
                  _SilentNotifications(),
                ),
                localSpeechServiceProvider.overrideWithValue(localSpeech),
                homeControllerProvider.overrideWith(
                  (ref) => HomeController(
                    ref,
                    audioRecorder: recorder,
                    temporaryDirectory: () async => root,
                    importFile: (p) async => p,
                  ),
                ),
              ],
            );
            try {
              await container.read(settingsProvider.notifier).ready;
              await container.read(remindersProvider.notifier).ready;
              final home = container.read(homeControllerProvider.notifier);
              expect(await home.startRecording(), isTrue);
              recorder.audio!.add(Uint8List(20000));
              home.startGestureTranscription();
              await Future<void>.delayed(const Duration(milliseconds: 25));
              final draft = home.createVoiceTextDraft();
              expect(await draft.result, isNull);
              await draft.release(sentText: true);
              await Future<void>.delayed(const Duration(milliseconds: 25));
            } finally {
              container.dispose();
            }
          },
          (error, _) => unhandled.add(error),
        );
        await db.close(createBackup: false);
        await root.delete(recursive: true);
        expect(unhandled, isEmpty);
      },
    );

    test(
      'HomeController.startGestureTranscription runs progressive WAV snapshots on Whisper endpoints before release',
      () async {
        sqfliteFfiInit();
        final root = await Directory.systemTemp.createTemp('gesture-snap-');
        final db = DatabaseHelper.forTesting(
          '${root.path}/db',
          databaseFactoryFfi,
        );
        final recorder = _StreamRecorder();
        final llm = _WhisperStubLlm();
        final localSpeech = LocalSpeechService(
          isIOS: false,
          isAndroid: false,
          channel: channel,
        );
        final container = ProviderContainer(
          overrides: [
            databaseHelperProvider.overrideWithValue(db),
            notificationServiceProvider.overrideWithValue(_SilentNotifications()),
            localSpeechServiceProvider.overrideWithValue(localSpeech),
            llmServiceProvider.overrideWithValue(llm),
            homeControllerProvider.overrideWith(
              (ref) => HomeController(
                ref,
                audioRecorder: recorder,
                temporaryDirectory: () async => root,
                importFile: (p) async => p,
              ),
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await db.close(createBackup: false);
          await root.delete(recursive: true);
        });
        await container.read(settingsProvider.notifier).ready;
        await container
            .read(settingsProvider.notifier)
            .updateSettings(
              AppSettings.defaults().copyWith(
                apiKey: 'sk-test-whisper',
                baseUrl: 'https://api.openai.com/v1',
                modelName: 'gpt-4o-mini',
              ),
            );
        final home = container.read(homeControllerProvider.notifier);

        expect(await home.startRecording(), isTrue);
        home.startGestureTranscription();
        // Feed >= 16000 PCM bytes (~0.5s of 16kHz 16-bit mono audio) while held.
        recorder.audio!.add(Uint8List(18000));
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(container.read(homeControllerProvider).isRecording, isTrue);
        expect(
          container.read(homeControllerProvider).voicePreview,
          '上滑右转实时识别中',
        );

        recorder.audio!.add(Uint8List(8000));
        final resolved = await home.stopRecordingToText();
        expect(resolved, '上滑右转实时识别完成');
      },
    );

    testWidgets(
      'InputBottomBar swipe-up-right starts transcription immediately while finger is held and hides release-only hint',
      (tester) async {
        sqfliteFfiInit();
        final root = await tester.runAsync(
          () => Directory.systemTemp.createTemp('gesture-ui-'),
        );
        final db = DatabaseHelper.forTesting(
          '${root!.path}/db',
          databaseFactoryFfi,
        );
        final container = ProviderContainer(
          overrides: [
            databaseHelperProvider.overrideWithValue(db),
            localSpeechServiceProvider.overrideWithValue(
              LocalSpeechService(isIOS: false, isAndroid: true, channel: channel),
            ),
            homeControllerProvider.overrideWith((ref) => _GestureCaptureHome(ref)),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await db.close(createBackup: false);
          await root.delete(recursive: true);
        });
        await tester.runAsync(
          () => container.read(settingsProvider.notifier).ready,
        );
        await tester.runAsync(
          () => container.read(workspaceDraftsProvider.notifier).ready,
        );
        final home =
            container.read(homeControllerProvider.notifier)
                as _GestureCaptureHome;

        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('zh'),
              supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
              localizationsDelegates: const [
                AppLocalizationsDelegate(),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: ThemeData(platform: TargetPlatform.android),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: const Scaffold(
                body: Column(
                  children: [
                    Expanded(child: SizedBox()),
                    InputBottomBar(),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final origin = tester.getCenter(
          find.byKey(const ValueKey('composer-input-surface')),
        );
        final gesture = await tester.startGesture(origin);
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pumpAndSettle();
        expect(home.gestureTranscriptionStarts, 0);

        // Swipe up and turn right while STILL holding finger down:
        await gesture.moveTo(origin + const Offset(60, -70));
        await tester.pump();

        expect(home.gestureTranscriptionStarts, 1);
        expect(find.text('正在边按住边转写'), findsOneWidget);
        expect(find.text('松手后转写'), findsNothing);

        await gesture.up();
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await drainWorkspaceDrafts(tester, container);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('Backend, scheduler, parser & architecture regressions', () {
    test(
      'MultiAgentService clamps out-of-range targetQuadrant to 1..4 and honors needsDecomposition=false',
      () async {
        final dio = Dio()
          ..httpClientAdapter = _FakeMultiAgentAdapter([
            {
              'macro_title': '买一瓶矿泉水',
              'quadrant': 99,
              'needs_decomposition': false,
              'strategic_advice': '顺路购买',
            },
          ]);
        final service = MultiAgentService(client: dio);
        addTearDown(service.dispose);

        final result = await service.executePipeline(
          '买一瓶矿泉水',
          settings: AppSettings(
            id: 'default',
            apiKey: 'sk-test',
            baseUrl: 'https://api.example.com/v1',
            modelName: 'test-model',
            language: 'zh',
          ),
        );

        expect(result.executionTrace, hasLength(6));
        expect(result.overallPriorityQuadrant, 4);
        expect(result.scheduledTasks, hasLength(1));
        expect(result.scheduledTasks.single.quadrantLevel, 4);
      },
    );

    test(
      'DPSchedulerService.findOptimalSlot handles short free windows without Infinity.round crash',
      () {
        final ref = DateTime(2026, 11, 25, 19, 30);
        // Busy 20:00..20:30 leaves two 30m windows (19:30..20:00 and 20:30..21:00),
        // and busy intervals throughout tomorrow leave only 20m gaps if packed.
        final busy = <Reminder>[
          Reminder(
            id: 'b0',
            taskTitle: 'Busy tonight',
            quadrantLevel: 1,
            triggerTime: DateTime(2026, 11, 25, 20, 0),
          ),
          for (var hour = 9; hour < 21; hour++)
            Reminder(
              id: 'b-$hour',
              taskTitle: 'Busy $hour',
              quadrantLevel: 1,
              triggerTime: DateTime(2026, 11, 26, hour, 20),
            ),
          // Hidden/trashed task at 19:30 must NOT block 19:30..20:00!
          Reminder(
            id: 'trashed',
            taskTitle: 'Trashed',
            quadrantLevel: 1,
            triggerTime: DateTime(2026, 11, 25, 19, 30),
            detailsJson: TaskDetails(
              deletedAt: DateTime.utc(2026, 11, 24),
            ).encode(),
          ),
        ];

        final slot = DPSchedulerService.instance.findOptimalSlot(
          existingTasks: busy,
          taskDurationMinutes: 60,
          referenceTime: ref,
          language: 'en',
        );
        expect(slot.fragmentationReductionScore, inInclusiveRange(0, 100));
        expect(slot.optimalTime.isAfter(ref.subtract(const Duration(minutes: 1))), isTrue);
      },
    );

    test(
      'QuickReminderParser parses spoken CJK minutes, quarters, half-hour offsets and noon 1..4pm',
      () {
        final now = DateTime(2026, 11, 24, 9, 0);
        expect(
          QuickReminderParser.parse('下午三点二十开会', now: now),
          DateTime(2026, 11, 24, 15, 20),
        );
        expect(
          QuickReminderParser.parse('明天早上八点零五吃早餐', now: now),
          DateTime(2026, 11, 25, 8, 5),
        );
        expect(
          QuickReminderParser.parse('下午两点一刻交报告', now: now),
          DateTime(2026, 11, 24, 14, 15),
        );
        expect(
          QuickReminderParser.parse('今晚七点三刻散步', now: now),
          DateTime(2026, 11, 24, 19, 45),
        );
        expect(
          QuickReminderParser.parse('半小时后喝水', now: now),
          DateTime(2026, 11, 24, 9, 30),
        );
        expect(
          QuickReminderParser.parse('一个半小时后复盘', now: now),
          DateTime(2026, 11, 24, 10, 30),
        );
        expect(
          QuickReminderParser.parse('中午1点午休', now: now),
          DateTime(2026, 11, 24, 13, 0),
        );
      },
    );

    test(
      'DatabaseHelper.readTransaction enforces read-only scope without invalidating bootstrap cache',
      () async {
        sqfliteFfiInit();
        final dir = await Directory.systemTemp.createTemp('read-tx-');
        final db = DatabaseHelper.forTesting(
          '${dir.path}/db',
          databaseFactoryFfi,
        );
        addTearDown(() async {
          await db.close(createBackup: false);
          await dir.delete(recursive: true);
        });

        final before = db.captureGeneration();
        db.cacheBootstrapSnapshot(
          before,
          defaultSettingsRow: const {'id': 'default', 'language': 'ja'},
          mediaRecords: const [],
          reminders: const [],
        );
        final count = await db.readTransaction(before, (txn) async {
          await expectLater(
            () => txn.insert('MediaRecords', {'id': 'm1'}),
            throwsStateError,
          );
          return (await txn.query('Reminders')).length;
        });
        expect(count, 0);
        expect(db.isCurrent(before), isTrue);
        expect(db.peekBootstrapLanguage(before), 'ja');
      },
    );

    test(
      'ContextTriggerService detects pending profile triggers and evaluates matching profile once per session',
      () {
        final service = ContextTriggerService.forTesting();
        final task = Reminder(
          id: 'ctx-1',
          taskTitle: '提交周报',
          quadrantLevel: 2,
          contextTrigger: const ContextTriggerRule(
            type: 'profile',
            value: 'office',
            prompt: '打开飞书文档',
          ).toJsonString(),
        );
        expect(service.hasPendingProfileTrigger([task]), isTrue);
        expect(service.evaluateContextTriggers([task]), isEmpty);

        service.switchProfile(ContextProfile.office);
        final matched = service.evaluateContextTriggers([task]);
        expect(matched.map((r) => r.id), ['ctx-1']);
        // Subsequent heartbeat in same session does not re-fire duplicate toast.
        expect(service.hasPendingProfileTrigger([task]), isFalse);
      },
    );

    testWidgets(
      'UnsavedEditorScope.hasBlockingEditor distinguishes clean vs dirty editors',
      (tester) async {
        var dirty = false;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return UnsavedEditorScope(
                  dirty: dirty,
                  busy: false,
                  onSave: () async => true,
                  builder: (_, __, ___) => const Scaffold(body: SizedBox()),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(UnsavedEditorScope.hasBlockingEditor, isFalse);
        update(() => dirty = true);
        await tester.pump();
        expect(UnsavedEditorScope.hasBlockingEditor, isTrue);

        await tester.pumpWidget(const SizedBox());
        expect(UnsavedEditorScope.hasBlockingEditor, isFalse);
      },
    );
  });
}
