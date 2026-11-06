import 'support/real_io.dart';
import 'support/interaction_preview.dart';
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/tencent_speech_credentials.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/security/credential_store.dart';
import 'package:dont_forget/ui/screens/preferences_screen.dart';
import 'package:dont_forget/ui/screens/speech_settings_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/notification_permission_panel.dart';
import 'package:dont_forget/ui/widgets/notification_diagnostics_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory root;
  late DatabaseHelper db;
  late ProviderContainer container;
  late MemoryCredentialStore vault;
  setUpAll(loadInteractionPreviewFonts);
  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('preferences-speech-');
    vault = MemoryCredentialStore();
    db = DatabaseHelper.forTesting(
      root.path,
      databaseFactoryFfi,
      credentialStore: vault,
    );
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWith(
          (_) => throw StateError('Notification transport must stay lazy'),
        ),
        lanSyncServiceProvider.overrideWith(
          (_) => throw StateError('LAN service must stay lazy'),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
  });
  tearDown(() async {
    container.dispose();
    await db.close(createBackup: false);
    await root.delete(recursive: true);
  });
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  Future<void> show(
    WidgetTester tester,
    Widget page, {
    String language = 'zh',
    Brightness brightness = Brightness.light,
    double width = 375,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 812);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: interactionPreviewKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: Locale(language),
            theme: brightness == Brightness.dark
                ? AppTheme.dark
                : AppTheme.light,
            supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => page)),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await settle(tester);
  }

  for (final language in ['zh', 'en', 'ja']) {
    testWidgets('responsive preferences preserve unsaved edits $language', (
      tester,
    ) async {
      await show(
        tester,
        const PreferencesScreen(),
        width: 1200,
        language: language,
      );
      Rect rect(String id) => tester.getRect(find.byKey(ValueKey(id)));
      expect(
        rect('preferences-language').top,
        rect('preferences-appearance').top,
      );
      expect(rect('preferences-ai').top, rect('preferences-notifications').top);
      expect(
        rect('preferences-ai').left,
        lessThan(rect('preferences-notifications').left),
      );
      final loc = AppLocalizations.of(
        tester.element(find.byType(PreferencesScreen)),
      );
      await tap(tester, 'preferences-send-mode');
      await tester.tap(find.text(loc.get('inputSend_button')).last);
      await settle(tester);
      expect(rect('preferences-save').width, lessThanOrEqualTo(960));
      tester.view.physicalSize = const Size(375, 812);
      await settle(tester);
      final field = tester.widget<DropdownButtonFormField<InputSendMode>>(
        find.byKey(const ValueKey('preferences-send-mode')),
      );
      expect(field.initialValue, InputSendMode.button);
      expect(
        container.read(settingsProvider).inputSendMode,
        InputSendMode.enter,
      );
      expect(
        rect('preferences-appearance').top,
        greaterThan(rect('preferences-language').top),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('preferences-ai')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      expect(
        rect('preferences-notifications').top,
        greaterThan(rect('preferences-ai').top),
      );
      await tap(tester, 'preferences-save');
      expect(
        container.read(settingsProvider).inputSendMode,
        InputSendMode.button,
      );
      expect(find.byType(PreferencesScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'wide preferences use readable single column for large type $language',
      (tester) async {
        await show(
          tester,
          const PreferencesScreen(),
          width: 1200,
          language: language,
          scale: 2,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('preferences-ai')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await settle(tester);
        final ai = tester.getRect(find.byKey(const ValueKey('preferences-ai')));
        final notifications = tester.getRect(
          find.byKey(const ValueKey('preferences-notifications')),
        );
        expect(ai.left, notifications.left);
        expect(notifications.top, greaterThan(ai.top));
        await tester.ensureVisible(
          find.byKey(const ValueKey('preferences-sync')),
        );
        await settle(tester);
        expect(
          find.byKey(const ValueKey('preferences-sync')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('preferences visual preview', (tester) async {
    await show(tester, const PreferencesScreen(), width: 1200);
    await captureInteractionPreview(tester, 'preferences-62-desktop');
    tester.view.physicalSize = const Size(375, 812);
    await settle(tester);
    await captureInteractionPreview(tester, 'preferences-62-mobile');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await show(
      tester,
      const PreferencesScreen(),
      width: 1200,
      brightness: Brightness.dark,
    );
    await captureInteractionPreview(tester, 'preferences-62-dark');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'everyday settings and AI page never mount notification diagnostics or LAN',
    (tester) async {
      await show(tester, const PreferencesScreen());
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(NotificationPermissionPanel), findsNothing);
      expect(find.byType(NotificationDiagnosticsPanel), findsNothing);
      expect(find.byKey(const ValueKey('preferences-save')), findsNothing);
      await tap(tester, 'preferences-ai');
      expect(find.byKey(const ValueKey('settings-speech')), findsOneWidget);
      expect(find.byType(NotificationPermissionPanel), findsNothing);
      expect(find.byType(NotificationDiagnosticsPanel), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-language-true')),
        findsNothing,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('本地存储 · 自主选择 AI 服务商'), findsNothing);
      await tap(tester, 'settings-advanced-connection');
      final model = find.byKey(const ValueKey('settings-model-name'));
      await tester.ensureVisible(model);
      await settle(tester);
      expect(model.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final language in ['zh', 'en', 'ja']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'compact preferences fit $language $brightness with large text',
        (tester) async {
          await show(
            tester,
            const PreferencesScreen(),
            language: language,
            brightness: brightness,
            width: 320,
            scale: 2,
          );
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('preferences-sync')),
            350,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('preferences-sync')),
          );
          await settle(tester);
          expect(
            find.byKey(const ValueKey('preferences-sync')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'changed preferences retain nested model changes and use explicit Save',
    (tester) async {
      await show(tester, const PreferencesScreen());
      await tap(tester, 'preferences-send-mode');
      await tester.tap(find.text('仅发送按钮').last);
      await settle(tester);
      expect(
        container.read(settingsProvider).inputSendMode,
        InputSendMode.enter,
      );
      await tester.runAsync(() async {
        final notifier = container.read(settingsProvider.notifier);
        await notifier.updateSettings(
          notifier.state.copyWith(
            modelName: 'nested-model',
            apiKey: 'nested-model-private',
          ),
        );
      });
      await tap(tester, 'preferences-save');
      await pumpUntilRealIo(
        tester,
        () =>
            container.read(settingsProvider).inputSendMode ==
            InputSendMode.button,
        reason: 'Preference transaction must commit before reading saved state',
      );
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).inputSendMode,
        InputSendMode.button,
      );
      expect(container.read(settingsProvider).modelName, 'nested-model');
      expect(container.read(settingsProvider).apiKey, 'nested-model-private');
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Tencent credential form stores all credentials only in vault and preserves model secret',
    (tester) async {
      await tester.runAsync(
        () => container
            .read(settingsProvider.notifier)
            .updateSettings(
              container
                  .read(settingsProvider)
                  .copyWith(apiKey: 'existing-model-private'),
            ),
      );
      await show(tester, const SpeechSettingsScreen());
      for (final entry in {
        'appid': '1259000000',
        'secret-id': 'AKIDTESTID12345678',
        'secret-key': 'tencent-unit-private-key',
      }.entries) {
        final target = find.byKey(ValueKey('speech-${entry.key}'));
        await tester.ensureVisible(target);
        await tester.enterText(target, entry.value);
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('speech-secret-id')))
            .obscureText,
        true,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('speech-secret-key')))
            .obscureText,
        true,
      );
      await tap(tester, 'speech-enabled');
      await tap(tester, 'speech-save');
      await pumpUntilRealIo(
        tester,
        () =>
            TencentSpeechCredentials.decode(
              container.read(settingsProvider).speech.apiKey,
            )?.secretKey ==
            'tencent-unit-private-key',
        reason: 'Vault and settings transaction must finish before readback',
      );
      await tester.pumpAndSettle();
      final state = container.read(settingsProvider);
      expect(
        TencentSpeechCredentials.decode(state.speech.apiKey)?.secretKey,
        'tencent-unit-private-key',
      );
      expect(state.apiKey, 'existing-model-private');
      expect(state.speech.enabled, true);
      final row = await tester.runAsync(
        () => db.read(db.captureGeneration(), (sql) => sql.query('Settings')),
      );
      for (final value in [
        '1259000000',
        'AKIDTESTID12345678',
        'tencent-unit-private-key',
        'existing-model-private',
      ]) {
        expect(jsonEncode(row), isNot(contains(value)));
      }
      expect(vault.values.values.join(), contains('tencent-unit-private-key'));
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'incomplete Tencent credentials never enable upload or overwrite saved state',
    (tester) async {
      await show(tester, const SpeechSettingsScreen());
      await tap(tester, 'speech-enabled');
      await tap(tester, 'speech-save');
      expect(container.read(settingsProvider).speech.enabled, false);
      expect(vault.values, isEmpty);
      expect(find.byType(SpeechSettingsScreen), findsOneWidget);
      expect(find.textContaining('请完整填写'), findsOneWidget);
    },
  );
}
