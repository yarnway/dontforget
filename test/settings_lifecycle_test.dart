import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _PendingProbe extends LLMService {
  late Completer<List<LocalInferenceEndpoint>> result;

  @override
  Future<List<LocalInferenceEndpoint>> probeLocalInferenceEndpoints() =>
      result.future;
}

class _ConsoleLauncher extends ConsoleUrlLauncher {
  Future<bool> Function(String)? handler;

  @override
  Future<bool> open(String url, {TargetPlatform? platform}) =>
      handler?.call(url) ?? Future.value(false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const notificationsChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  test('desktop console commands await the actual process result', () async {
    const url = 'https://platform.deepseek.com/api_keys';
    for (final entry in {
      TargetPlatform.windows: (
        'rundll32',
        ['url.dll,FileProtocolHandler', url],
      ),
      TargetPlatform.macOS: ('open', [url]),
      TargetPlatform.linux: ('xdg-open', [url]),
    }.entries) {
      final completion = Completer<ProcessResult>();
      final launcher = ConsoleUrlLauncher(
        runProcess: (executable, arguments) {
          expect(executable, entry.value.$1);
          expect(arguments, entry.value.$2);
          return completion.future;
        },
      );
      var finished = false;
      final result = launcher.open(url, platform: entry.key).then((value) {
        finished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      completion.complete(ProcessResult(0, 0, '', ''));
      expect(await result, isTrue);
    }
  });

  test(
    'missing opener, nonzero exit and mobile platforms request the fallback',
    () async {
      const url = 'https://platform.deepseek.com/api_keys';
      final missing = ConsoleUrlLauncher(
        runProcess: (_, _) =>
            throw const ProcessException('open', [], 'missing'),
      );
      expect(await missing.open(url, platform: TargetPlatform.macOS), isFalse);
      final failed = ConsoleUrlLauncher(
        runProcess: (_, _) async => ProcessResult(0, 1, '', 'failed'),
      );
      expect(await failed.open(url, platform: TargetPlatform.linux), isFalse);
      final noProcess = ConsoleUrlLauncher(
        runProcess: (_, _) => throw StateError('must not run'),
      );
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        expect(await noProcess.open(url, platform: platform), isFalse);
      }
      expect(
        await noProcess.open(
          'file:///private/example',
          platform: TargetPlatform.macOS,
        ),
        isFalse,
      );
    },
  );

  group('settings asynchronous actions', () {
    late Directory directory;
    late DatabaseHelper database;
    late ProviderContainer container;
    late _PendingProbe probe;
    late _ConsoleLauncher launcher;
    final notificationCalls = <String>[];
    final l10n = AppLocalizations(const Locale('en'));

    setUp(() async {
      notificationCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsChannel, (call) async {
            notificationCalls.add(call.method);
            switch (call.method) {
              case 'areNotificationsEnabled':
              case 'canScheduleExactNotifications':
                return true;
              case 'checkPermissions':
                return {
                  'isEnabled': true,
                  'isAlertEnabled': true,
                  'isSoundEnabled': true,
                  'isBadgeEnabled': true,
                  'isProvisionalEnabled': false,
                };
              default:
                throw UnsupportedError(
                  'Unexpected notification call: ${call.method}',
                );
            }
          });
      sqfliteFfiInit();
      directory = await Directory.systemTemp.createTemp('settings-lifecycle-');
      database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
      probe = _PendingProbe();
      launcher = _ConsoleLauncher();
      container = ProviderContainer(
        overrides: [
          notificationScheduleStatusReaderProvider.overrideWithValue(
            () async => const NotificationScheduleStatus(
              upcoming: 0,
              submitted: 0,
              needsAttention: 0,
              cancellations: 0,
              overdueUnconfirmed: 0,
            ),
          ),
          databaseHelperProvider.overrideWithValue(database),
          llmServiceProvider.overrideWithValue(probe),
          consoleUrlLauncherProvider.overrideWithValue(launcher),
        ],
      );
      await container.read(settingsProvider.notifier).ready;
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      container.dispose();
      await database.close();
      await directory.delete(recursive: true);
    });

    Future<void> showSettings(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: const [AppLocalizationsDelegate()],
            builder: (_, child) => InlineFeedback(child: child!),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Open settings'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(notificationCalls, isNotEmpty);
      expect(
        notificationCalls.where((call) => call.startsWith('request')),
        isEmpty,
      );
    }

    Future<void> tapAction(WidgetTester tester, String text) async {
      final action = find.text(text);
      await tester.scrollUntilVisible(
        action,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(action), alignment: 0.3);
      await tester.pumpAndSettle();
      expect(action.hitTestable(), findsOneWidget);
      await tester.tap(action);
      await tester.pump();
    }

    testWidgets('opening and saving preserves the stored model alias', (
      tester,
    ) async {
      const alias = 'deepseek-v4.1-flash-1017';
      await tester.runAsync(() async {
        final notifier = container.read(settingsProvider.notifier);
        await notifier.updateSettings(
          notifier.state.copyWith(modelName: alias),
        );
      });
      await showSettings(tester);
      final field = find.byKey(const ValueKey('settings-model-name'));
      await tester.scrollUntilVisible(
        field,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, alias);
      await tester.runAsync(() => tester.tap(find.text(l10n.get('save'))));
      for (
        var i = 0;
        i < 50 && find.byType(SettingsScreen).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(container.read(settingsProvider).modelName, alias);
      final rows = await tester.runAsync(
        () async => (await database.database).query('Settings'),
      );
      expect(rows!.single['model_name'], alias);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    for (final fails in [false, true]) {
      testWidgets(
        'probe ${fails ? 'failure' : 'success'} after leaving does not update a disposed screen',
        (tester) async {
          probe.result = Completer<List<LocalInferenceEndpoint>>();
          await showSettings(tester);
          await tapAction(tester, l10n.get('probeNow'));
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(SettingsScreen), findsNothing);
          if (fails) {
            probe.result.completeError(StateError('synthetic probe failure'));
          } else {
            probe.result.complete([]);
          }
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets('probe failure is visible and allows another attempt', (
      tester,
    ) async {
      probe.result = Completer<List<LocalInferenceEndpoint>>();
      await showSettings(tester);
      await tapAction(tester, l10n.get('probeNow'));
      probe.result.completeError(StateError('synthetic probe failure'));
      await tester.pump();
      expect(find.text(l10n.get('probeFailed')), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, l10n.get('probeNow')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'failed browser handoff offers selectable URL and working copy action on a phone',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(375, 667);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? clipboard;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'] as String;
              }
              return null;
            });
        await showSettings(tester);
        await tapAction(tester, 'DeepSeek');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('console-fallback-url')),
              )
              .data,
          'https://platform.deepseek.com/api_keys',
        );
        await tester.tap(find.text(l10n.get('copyLink')));
        await tester.pumpAndSettle();
        expect(clipboard, 'https://platform.deepseek.com/api_keys');
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(l10n.get('linkCopied')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'clipboard failure keeps the selectable address and explains manual copying',
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                throw PlatformException(code: 'copy-failed');
              }
              return null;
            });
        await showSettings(tester);
        await tapAction(tester, 'DeepSeek');
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.get('copyLink')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('console-fallback-url')),
          findsOneWidget,
        );
        expect(find.text(l10n.get('linkCopyFailed')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'browser handoff finishing after leaving does not open a dialog',
      (tester) async {
        final completion = Completer<bool>();
        launcher.handler = (_) => completion.future;
        await showSettings(tester);
        await tapAction(tester, 'DeepSeek');
        await tester.pageBack();
        await tester.pumpAndSettle();
        completion.complete(false);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Open settings'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
