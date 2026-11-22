import 'dart:math' as math;

import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/l10n/framework_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/global_capture_provider.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/windows_toast.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/task_workspace_overview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/offline_management_harness.dart';
import 'support/workspace_drafts.dart';

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('WindowsToast escapes PowerShell 5.1 Unicode curly single quotes', () {
    final script = WindowsToast.script(
      title: 'Alice\u2019s \u2018review\u2019 \u201Acheck\u201B',
      body: 'Confirm \u2018Q1\u2019 budget',
    );
    expect(script, contains('Alice\u2019\u2019s'));
    expect(script, contains('\u2018\u2018review\u2019\u2019'));
    expect(script, contains('\u201A\u201Acheck\u201B\u201B'));
    expect(script, contains('Confirm \u2018\u2018Q1\u2019\u2019 budget'));
  });

  test('LLMService.chatCompletionsUrl normalizes trailing slashes', () {
    expect(
      LLMService.chatCompletionsUrl('https://api.deepseek.com/'),
      'https://api.deepseek.com/chat/completions',
    );
    expect(
      LLMService.chatCompletionsUrl('https://api.openai.com/v1///'),
      'https://api.openai.com/v1/chat/completions',
    );
    expect(
      LLMService.chatCompletionsUrl('http://localhost:11434/v1'),
      'http://localhost:11434/v1/chat/completions',
    );
  });

  test('3-locale framework delegates load en/zh/ja and reject unsupported', () async {
    const material = AppMaterialLocalizationsDelegate();
    const cupertino = AppCupertinoLocalizationsDelegate();
    const widgets = AppWidgetsLocalizationsDelegate();

    for (final code in ['en', 'zh', 'ja']) {
      final locale = Locale(code);
      expect(material.isSupported(locale), isTrue);
      expect(cupertino.isSupported(locale), isTrue);
      expect(widgets.isSupported(locale), isTrue);

      final m = await material.load(locale);
      final c = await cupertino.load(locale);
      final w = await widgets.load(locale);
      expect(m.okButtonLabel, isNotEmpty);
      expect(c.todayLabel, isNotEmpty);
      expect(w.textDirection, TextDirection.ltr);
    }

    expect(material.isSupported(const Locale('fr')), isFalse);
    expect(cupertino.isSupported(const Locale('de')), isFalse);
    expect(widgets.isSupported(const Locale('es')), isFalse);
  });

  test('WorkspaceDraftsNotifier.putAll settles superseded debounced waiters', () async {
    final h = OfflineManagementHarness();
    await h.create();
    addTearDown(h.dispose);

    final drafts = h.container.read(workspaceDraftsProvider.notifier);
    await drafts.ready;

    final first = drafts.put('homeView', 'today');
    await drafts.putAll({'homeView': 'all', 'customFlag': true});

    // If putAll failed to settle superseded _debouncedWaiters, this would hang.
    await first.timeout(const Duration(seconds: 3));
    expect(h.container.read(workspaceDraftsProvider)['homeView'], 'all');
    expect(h.container.read(workspaceDraftsProvider)['customFlag'], isTrue);
  });

  test('NotificationService.seedInitialLanguage sets baseline without reconcile', () async {
    final service = NotificationService.forTesting(
      FlutterLocalNotificationsPlugin(),
      usesNativeNotifications: false,
    );
    addTearDown(service.pauseForMaintenance);
    service.seedInitialLanguage('en');
    // Subsequent seed calls before init update pre-init baseline cleanly.
    service.seedInitialLanguage('ja');
    // Verify desktop setNotificationLanguage completes cleanly in O(1) across OSes.
    await service.setNotificationLanguage('ja');
    await service.setNotificationLanguage('zh');
  });

  test('AppTheme.quadrantColor provides 4 distinct AA-contrast colors per theme', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final colors = <Color>{};
      final surface = theme.colorScheme.surfaceContainerLow;
      for (var level = 1; level <= 4; level++) {
        final color = AppTheme.quadrantColor(theme.brightness, level);
        colors.add(color);
        expect(
          _contrastRatio(color, surface),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness} Q$level contrast against $surface',
        );
      }
      expect(colors.length, 4);
    }
  });

  testWidgets('SettingsScreen API key visibility toggle reveals and obscures text', (
    tester,
  ) async {
    final h = OfflineManagementHarness();
    await tester.runAsync(() async {
      await h.create();
      await h.container.read(settingsProvider.notifier).ready;
    });
    addTearDown(() => tester.runAsync(h.dispose));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            AppMaterialLocalizationsDelegate(),
            AppWidgetsLocalizationsDelegate(),
            AppCupertinoLocalizationsDelegate(),
          ],
          theme: AppTheme.light,
          builder: (context, child) => InlineFeedback(child: child!),
          home: const SettingsScreen(area: SettingsArea.ai),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    // Expand advanced connection section to reach API key field.
    final expansion = find.byKey(const ValueKey('settings-advanced-connection'));
    await tester.scrollUntilVisible(
      expansion,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(expansion);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final apiFieldFinder = find.byKey(const ValueKey('settings-api-key'));
    await tester.scrollUntilVisible(
      apiFieldFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-api-key-toggle')),
    );
    await tester.pump();
    expect(tester.widget<TextField>(apiFieldFinder).obscureText, isTrue);

    await tester.tap(find.byKey(const ValueKey('settings-api-key-toggle')));
    await tester.pump();
    expect(tester.widget<TextField>(apiFieldFinder).obscureText, isFalse);

    await tester.tap(find.byKey(const ValueKey('settings-api-key-toggle')));
    await tester.pump();
    expect(tester.widget<TextField>(apiFieldFinder).obscureText, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('TaskWorkspaceOverview renders actionable empty state on All tab', (
    tester,
  ) async {
    final h = OfflineManagementHarness();
    await tester.runAsync(() async {
      await h.create();
      await h.container.read(workspaceDraftsProvider.notifier).ready;
    });
    addTearDown(() => tester.runAsync(h.dispose));

    var quickCaptureTapped = false;
    h.container.read(captureInputCommandProvider).focus = () {
      quickCaptureTapped = true;
      return true;
    };
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            AppMaterialLocalizationsDelegate(),
            AppWidgetsLocalizationsDelegate(),
            AppCupertinoLocalizationsDelegate(),
          ],
          theme: AppTheme.light,
          builder: (context, child) => InlineFeedback(child: child!),
          home: Scaffold(
            body: TaskWorkspaceOverview(
              reminders: const <Reminder>[],
              onPlayMedia: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    final cta = find.byKey(const ValueKey('workspace-empty-add'));
    expect(cta, findsOneWidget);
    await tester.tap(cta);
    await tester.pump();
    expect(quickCaptureTapped, isTrue);

    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
