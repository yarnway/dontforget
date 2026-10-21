import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/ai_profile.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/ui/screens/ai_profiles_screen.dart';

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
      expect(saved.aiProfiles.map((p) => p.settings.apiKey), [
        'fixture-b',
        'fixture-a',
      ]);
      expect(saved.aiFallbackEnabled, isTrue);
      await helper.close();
      final db = await helper.database;
      expect(await db.getVersion(), 9);
      expect(
        AppSettings.fromJson((await db.query('Settings')).single).toJson(),
        saved.toJson(),
      );
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
