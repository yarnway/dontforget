import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/ai_profile.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/credential_reference.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/ui/screens/ai_profiles_screen.dart';
import 'support/interaction_preview.dart';

AiProfile profile(String id) => AiProfile(
  id: id,
  label: id,
  settings: AppSettings.defaults().copyWith(
    baseUrl: 'https://$id.example/v1',
    modelName: 'model-$id',
    apiKey: 'fixture-$id',
  ),
);

void main() {
  setUpAll(loadInteractionPreviewFonts);
  late Directory directory;
  late DatabaseHelper helper;
  late ProviderContainer container;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-profiles-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    container = ProviderContainer(
      overrides: [databaseHelperProvider.overrideWithValue(helper)],
    );
    await container.read(settingsProvider.notifier).ready;
  });
  tearDown(() async {
    container.dispose();
    await helper.close();
    await directory.delete(recursive: true);
  });

  test(
    'ordered profiles and opt-in survive storage, backup and reopen',
    () async {
      final settings = AppSettings.defaults().copyWith(
        aiProfiles: [profile('b'), profile('a')],
        aiFallbackEnabled: true,
      );
      await container.read(settingsProvider.notifier).updateSettings(settings);
      await helper.createMirrorBackup();
      final data = jsonDecode(
        await File('${directory.path}/ha_snapshot.json').readAsString(),
      );
      final saved = AppSettings.fromJson(
        Map<String, dynamic>.from(data['settings'].single),
      );
      expect(saved.aiProfiles.map((p) => p.id), ['b', 'a']);
      expect(saved.aiProfiles.map((p) => p.settings.apiKey), ['', '']);
      expect(isCredentialReference(saved.apiKey), isTrue);
      expect(jsonEncode(data), isNot(contains('fixture-b')));
      expect(jsonEncode(data), isNot(contains('fixture-a')));
      expect(saved.aiFallbackEnabled, isTrue);
      await helper.close();
      final db = await helper.database;
      expect(await db.getVersion(), DatabaseHelper.schemaVersion);
      expect(
        AppSettings.fromJson((await db.query('Settings')).single).toJson(),
        saved.toJson(),
      );
      final reloaded = SettingsNotifier(helper);
      await reloaded.ready;
      expect(reloaded.state.aiProfiles.map((p) => p.settings.apiKey), [
        'fixture-b',
        'fixture-a',
      ]);
      reloaded.dispose();
    },
  );

  for (final malformed in [false, true]) {
    test(
      'extraction routes after ${malformed ? 'invalid content' : 'auth failure'} without leaking credentials',
      () async {
        final dio = Dio();
        final calls = <String>[];
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final id = options.uri.host.split('.').first;
              calls.add(id);
              expect(options.headers['Authorization'], 'Bearer fixture-$id');
              expect(options.data['model'], 'model-$id');
              if (id == 'a' && !malformed) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.badResponse,
                    response: Response(
                      requestOptions: options,
                      statusCode: 401,
                    ),
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    data: {
                      'choices': [
                        {
                          'message': {
                            'content': id == 'a'
                                ? 'invalid response'
                                : '{"tasks":[{"title":"One task","quadrant":2,"time":"2050-01-01 09:00"}]}',
                          },
                        },
                      ],
                    },
                  ),
                );
              }
            },
          ),
        );
        final tasks = await LLMService(client: dio).extractTasks(
          'synthetic text',
          AppSettings.defaults().copyWith(
            aiProfiles: [profile('a'), profile('b')],
            aiFallbackEnabled: true,
          ),
        );
        expect(calls, ['a', 'b']);
        expect(tasks.single.taskTitle, 'One task');
        dio.close();
      },
    );
  }

  test(
    'disabled or empty lists never resurrect legacy credentials for extraction or reports',
    () async {
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );
      final service = LLMService(client: dio);
      addTearDown(service.dispose);
      for (final profiles in [
        <AiProfile>[],
        [profile('a').copyWith(enabled: false)],
      ]) {
        final settings = AppSettings.defaults().copyWith(
          apiKey: 'legacy-fixture',
          aiProfiles: profiles,
        );
        expect(settings.hasConfiguredExtraction, isFalse);
        await expectLater(
          service.extractTasks('synthetic input', settings),
          throwsException,
        );
        await service.decomposeTaskToMicroHabits(
          Reminder(id: 'x', taskTitle: 'x', quadrantLevel: 2),
          settings,
        );
        expect(calls, 0);
      }
    },
  );

  test(
    'malformed task JSON cannot be salvaged into a successful route',
    () async {
      final dio = Dio();
      final calls = <String>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls.add(options.uri.host);
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'choices': [
                    {
                      'message': {
                        'content': options.uri.host == 'a.example'
                            ? '{"tasks":[{"title":"must not be salvaged"}'
                            : '{"tasks":[{"title":"valid task"}]}',
                      },
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      final service = LLMService(client: dio);
      addTearDown(service.dispose);
      final tasks = await service.extractTasks(
        'synthetic',
        AppSettings.defaults().copyWith(
          aiProfiles: [profile('a'), profile('b')],
          aiFallbackEnabled: true,
        ),
      );
      expect(calls, ['a.example', 'b.example']);
      expect(tasks.single.taskTitle, 'valid task');
      expect(service.lastExtraction.value?.label, 'b');
      expect(service.lastExtraction.value?.usedFallback, isTrue);
    },
  );

  test(
    'failed attachment extraction creates one local task without a guessed reminder time',
    () async {
      final service = LLMService();
      addTearDown(service.dispose);
      final settings = AppSettings.defaults().copyWith(aiProfiles: []);
      for (final tasks in [
        await service.extractTasksFromImage('synthetic', settings),
        await service.extractTasksFromFile(
          'fixture.txt',
          'synthetic text',
          settings,
        ),
        await service.extractTasksFromVideo('fixture.mov', settings),
      ]) {
        expect(tasks, hasLength(1));
        expect(tasks.single.triggerTime, isNull);
      }
    },
  );

  test(
    'transcription preserves a custom endpoint even when its path names OpenAI',
    () async {
      final file = await File(
        '${directory.path}/synthetic.m4a',
      ).writeAsString('synthetic bytes');
      final dio = Dio();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            expect(
              options.uri.toString(),
              'https://gateway.invalid/openai.com/v1/audio/transcriptions',
            );
            expect(options.headers['Authorization'], 'Bearer custom-fixture');
            expect(options.followRedirects, isFalse);
            handler.resolve(
              Response(
                requestOptions: options,
                data: {'text': 'synthetic transcript'},
              ),
            );
          },
        ),
      );
      final service = LLMService(client: dio);
      addTearDown(service.dispose);
      final settings = AppSettings.defaults().copyWith(
        aiProfiles: [
          AiProfile(
            id: 'custom',
            label: 'Custom',
            settings: AppSettings.defaults().copyWith(
              baseUrl: 'https://gateway.invalid/openai.com/v1/',
              apiKey: 'custom-fixture',
            ),
          ),
        ],
      );
      expect(
        await service.transcribeAudio(file.path, settings),
        'synthetic transcript',
      );
      expect(requests, 1);
    },
  );

  test('unknown or duplicate configuration shapes are rejected', () {
    final data = AppSettings.defaults().toJson();
    expect(
      () => AppSettings.fromJson({...data, 'ai_profiles_json': '[{}]'}),
      throwsFormatException,
    );
    expect(
      () => AppSettings.fromJson({
        ...data,
        'ai_profiles_json': jsonEncode([
          profile('a').toJson(),
          profile('a').toJson(),
        ]),
      }),
      throwsFormatException,
    );
  });

  testWidgets(
    'a model draft from before database maintenance cannot overwrite new settings',
    (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AiProfilesScreen()),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final before = container.read(settingsProvider).toJson();
      await tester.runAsync(() async {
        final lease = await helper.beginMaintenance();
        await lease.resume();
      });
      await tester.tap(find.text('保存模型配置'));
      await tester.pumpAndSettle();
      expect(find.text('配置未保存，请检查本地存储后重试。'), findsOneWidget);
      expect(container.read(settingsProvider).toJson(), before);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final language in ['zh', 'en', 'ja']) {
      testWidgets(
        'model editor fits $language width $width at larger text size',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                locale: Locale(language),
                supportedLocales: const [
                  Locale('zh'),
                  Locale('en'),
                  Locale('ja'),
                ],
                localizationsDelegates: const [
                  AppLocalizationsDelegate(),
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: const TextScaler.linear(1.3),
                  ),
                  child: const AiProfilesScreen(),
                ),
              ),
            ),
          );
          // Localizations load before the screen starts its settings read.
          for (var i = 0; i < 10; i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump();
            if (find.byKey(const ValueKey('primary')).evaluate().isNotEmpty) {
              break;
            }
          }
          expect(find.byKey(const ValueKey('primary')), findsOneWidget);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('changing service origin clears the previous credential', (
    tester,
  ) async {
    await tester.runAsync(
      () => container
          .read(settingsProvider.notifier)
          .updateSettings(
            AppSettings.defaults().copyWith(aiProfiles: [profile('a')]),
          ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AiProfilesScreen()),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('a/url')),
      'https://other.example/v1',
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('a/key/1')),
    );
    expect(field.initialValue, isEmpty);
    await tester.tap(find.text('保存模型配置'));
    await tester.pumpAndSettle();
    expect(find.text('请补全已启用模型的名称、地址、模型标识和密钥，或关闭该项。'), findsOneWidget);
    expect(container.read(settingsProvider).apiKey, isEmpty);
    expect(
      container.read(settingsProvider).aiProfiles.single.settings.apiKey,
      'fixture-a',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'saving inherited model draft does not commit the parent language draft',
    (tester) async {
      final stored = AppSettings.defaults().copyWith(
        language: 'zh',
        aiProfiles: [profile('a')],
      );
      await tester.runAsync(
        () => container.read(settingsProvider.notifier).updateSettings(stored),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh')],
            home: AiProfilesScreen(
              initialDraft: stored.copyWith(
                language: 'ja',
                aiFallbackEnabled: true,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        if (find.byKey(const ValueKey('a/model')).evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('有未保存的修改'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.text('保存并返回')));
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (container.read(settingsProvider).aiFallbackEnabled) break;
      }
      expect(container.read(settingsProvider).language, 'zh');
      expect(container.read(settingsProvider).aiFallbackEnabled, true);
      final db = await tester.runAsync(() => helper.database);
      final rows = await tester.runAsync(() => db!.query('Settings'));
      expect(AppSettings.fromJson(rows!.single).language, 'zh');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(375, 667), const Size(667, 375)]) {
    testWidgets('model editor input and save survive keyboard at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.viewInsets = FakeViewPadding(
        bottom: size.height > 400 ? 300 : 150,
      );
      addTearDown(tester.view.reset);
      await tester.runAsync(
        () => container
            .read(settingsProvider.notifier)
            .updateSettings(
              AppSettings.defaults().copyWith(aiProfiles: [profile('a')]),
            ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (_, child) =>
                RepaintBoundary(key: interactionPreviewKey, child: child!),
            home: const AiProfilesScreen(),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('a/model'));
      await tester.scrollUntilVisible(
        field,
        120,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 50,
      );
      await tester.pumpAndSettle();
      expect(field.hitTestable(), findsOneWidget);
      await tester.enterText(field, 'new-model');
      await tester.pumpAndSettle();
      expect(find.text('保存模型配置').hitTestable(), findsOneWidget);
      expect(
        tester.getRect(find.text('保存模型配置')).bottom,
        lessThan(size.height - tester.view.viewInsets.bottom),
      );
      expect(tester.takeException(), isNull);
      await captureInteractionPreview(
        tester,
        'models-keyboard-${size.width.toInt()}',
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'profile ordering saves the user order with fallback disabled by default',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(settingsProvider.notifier)
            .updateSettings(
              AppSettings.defaults().copyWith(
                aiProfiles: [profile('a'), profile('b')],
              ),
            ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AiProfilesScreen()),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('不可用时自动尝试下一模型'), findsOneWidget);
      await tester.tap(find.byTooltip('下移').first);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('保存模型配置')));
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (container.read(settingsProvider).aiProfiles.first.id == 'b') break;
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final saved = container.read(settingsProvider);
      expect(saved.aiProfiles.map((p) => p.id), ['b', 'a']);
      expect(saved.apiKey, 'fixture-b');
      expect(saved.aiFallbackEnabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
