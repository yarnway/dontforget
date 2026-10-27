import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'support/interaction_preview.dart';

void main() {
  setUpAll(loadInteractionPreviewFonts);
  TestWidgetsFlutterBinding.ensureInitialized();
  const notificationChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  late Directory directory;
  late DatabaseHelper helper;
  late ProviderContainer container;
  setUp(() async {
    // Persistence/layout tests have no native permission channel. The focused
    // permission tests exercise supported platforms and stalled native reads.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationChannel, (call) async {
          return switch (call.method) {
            'areNotificationsEnabled' ||
            'canScheduleExactNotifications' => true,
            _ => null,
          };
        });
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-settings-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    container = ProviderContainer(
      overrides: [
        // These tests exercise persistence, not a real OS channel. Dedicated
        // reader tests cover native results, partial failure and timeouts.
        notificationServiceProvider.overrideWithValue(
          NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ),
        notificationScheduleStatusReaderProvider.overrideWithValue(
          () async => const NotificationScheduleStatus(
            upcoming: 0,
            submitted: 0,
            needsAttention: 0,
            cancellations: 0,
            overdueUnconfirmed: 0,
          ),
        ),
        databaseHelperProvider.overrideWithValue(helper),
      ],
    );
    final notifier = container.read(settingsProvider.notifier);
    await notifier.ready;
    await notifier.updateSettings(
      notifier.state.copyWith(apiKey: 'user-test-key'),
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationChannel, null);
    container.dispose();
    await helper.close();
    await directory.delete(recursive: true);
  });

  Future<void> showSettings(WidgetTester tester, {bool routed = false}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => InlineFeedback(
            child: RepaintBoundary(key: interactionPreviewKey, child: child!),
          ),
          home: routed
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                )
              : const SettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    if (routed) {
      await tester.tap(find.text('open'));
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('appearance remains a draft until save and survives reopening', (
    tester,
  ) async {
    await showSettings(tester);
    await tester.tap(find.byKey(const ValueKey('appearance-dark')));
    await tester.pump();
    expect(container.read(settingsProvider).appearance, AppAppearance.system);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      for (
        var i = 0;
        i < 100 &&
            container.read(settingsProvider).appearance != AppAppearance.dark;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).appearance, AppAppearance.dark);
    late SettingsNotifier reloaded;
    await tester.runAsync(() async {
      reloaded = SettingsNotifier(helper);
      await reloaded.ready;
    });
    expect(reloaded.state.appearance, AppAppearance.dark);
    expect(reloaded.state.apiKey, 'user-test-key');
    reloaded.dispose();
    await tester.pumpWidget(const SizedBox());
    await showSettings(tester);
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('appearance-dark')),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .selected,
      isTrue,
    );
  });

  testWidgets('discarding an appearance change keeps the saved mode', (
    tester,
  ) async {
    await showSettings(tester, routed: true);
    await tester.tap(find.byKey(const ValueKey('appearance-light')));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).appearance, AppAppearance.system);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets(
    'settings draft back confirmation keeps or explicitly discards without writing',
    (tester) async {
      await showSettings(tester, routed: true);
      final field = find.byKey(const ValueKey('settings-api-key'));
      await tester.scrollUntilVisible(
        field,
        180,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 50,
      );
      await tester.pumpAndSettle();
      await tester.enterText(field, 'uncommitted-key');
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('有未保存的修改'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'uncommitted-key',
      );
      expect(container.read(settingsProvider).apiKey, 'user-test-key');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      await showSettings(tester, routed: true);
      await tester.scrollUntilVisible(
        field,
        180,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 50,
      );
      expect(tester.widget<TextField>(field).controller!.text, 'user-test-key');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(375, 667), const Size(667, 375)]) {
    testWidgets(
      'settings controls and active field remain usable above keyboard at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.view.viewInsets = FakeViewPadding(
          bottom: size.height > 400 ? 300 : 150,
        );
        addTearDown(tester.view.reset);
        await showSettings(tester);
        final field = find.byKey(const ValueKey('settings-api-key'));
        await tester.scrollUntilVisible(
          field,
          180,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 50,
        );
        await tester.pumpAndSettle();
        expect(field.hitTestable(), findsOneWidget);
        await tester.enterText(field, '中文日本語keyboard');
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field).controller!.text,
          '中文日本語keyboard',
        );
        for (final label in ['备份已保存的数据', '保存']) {
          expect(find.text(label).hitTestable(), findsOneWidget);
          expect(
            tester.getRect(find.text(label)).bottom,
            lessThan(size.height - tester.view.viewInsets.bottom),
          );
        }
        expect(tester.takeException(), isNull);
        await captureInteractionPreview(
          tester,
          'settings-keyboard-${size.width.toInt()}',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Switching providers clears the previous key without supplying a bundled key',
    (tester) async {
      await showSettings(tester);
      final keyField = find.byWidgetPredicate(
        (w) => w is TextField && w.obscureText,
      );
      await tester.scrollUntilVisible(
        keyField,
        350,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<TextField>(keyField).controller!.text,
        'user-test-key',
      );
      await tester.ensureVisible(find.text('一键选用 DeepSeek'));
      await tester.tap(find.text('一键选用 DeepSeek'));
      await tester.pump();
      expect(
        tester.widget<TextField>(keyField).controller!.text,
        'user-test-key',
      );
      await tester.tap(find.text('一键选用 Gemini'));
      await tester.pump();
      expect(tester.widget<TextField>(keyField).controller!.text, isEmpty);
      expect(container.read(settingsProvider).apiKey, 'user-test-key');
    },
  );

  testWidgets('Manual backup reports success only after files exist', (
    tester,
  ) async {
    await showSettings(tester);
    final button = find.text('备份已保存的数据');
    await tester.scrollUntilVisible(
      button,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.runAsync(() => tester.tap(button));
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.text('本地备份已生成。').evaluate().isNotEmpty) break;
    }
    expect(find.text('本地备份已生成。'), findsOneWidget);
    expect(
      File('${directory.path}/dont_forget_v3.mirror.db').existsSync(),
      isTrue,
    );
    expect(File('${directory.path}/ha_snapshot.json').existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('backup and save remain reachable without scrolling on a phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());
    await showSettings(tester);
    for (final label in ['备份已保存的数据', '保存']) {
      final button = find.text(label);
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getRect(button).bottom, lessThan(667));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Save failure keeps the settings screen open and shows an error',
    (tester) async {
      final db = await tester.runAsync(() => helper.database);
      await tester.runAsync(
        () => db!.execute(
          'CREATE TRIGGER reject_settings BEFORE INSERT ON Settings '
          "BEGIN SELECT RAISE(ABORT, 'test write failure'); END",
        ),
      );
      await showSettings(tester);
      await tester.scrollUntilVisible(
        find.text('保存'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(() => tester.tap(find.text('保存')));
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.text('设置保存失败，请检查本地存储后重试。').evaluate().isNotEmpty) break;
      }
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('设置保存失败，请检查本地存储后重试。'), findsOneWidget);
      expect(container.read(settingsProvider).apiKey, 'user-test-key');
      await tester.runAsync(() => db!.execute('DROP TRIGGER reject_settings'));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
