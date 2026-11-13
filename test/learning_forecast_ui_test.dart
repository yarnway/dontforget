import 'dart:convert';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/l10n/study_management_strings.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/learning_workload_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'learning_workload_test.dart' show task;
import 'support/offline_management_harness.dart';

void main() {
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  Future<void> show(
    WidgetTester tester, {
    String language = 'zh',
    double width = 390,
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: dark ? AppTheme.dark : AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: LearningWorkloadCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final found = find.byKey(
      key == 'learning-workload' ? PageStorageKey(key) : ValueKey(key),
    );
    await tester.ensureVisible(found);
    await tester.tap(found);
    await tester.pumpAndSettle();
  }

  Future<String?> snapshot(WidgetTester tester) => tester.runAsync(
    () => h.database.read(
      h.database.captureGeneration(),
      (db) async => jsonEncode({
        for (final t in ['Reminders', 'MediaRecords', 'Settings'])
          t: await db.query(t, orderBy: 'id'),
      }),
    ),
  );
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets(
    'switching forecast and feedback is read-only and includes repeat reviews',
    (tester) async {
      await tester.runAsync(
        () => h.seed(task('a', 'apple', due: DateTime.now())),
      );
      h.notifications.scheduled.clear();
      h.notifications.cancelled.clear();
      final before = await snapshot(tester);
      await show(tester);
      expect(find.text('1 词已排期'), findsOneWidget);
      await tap(tester, 'learning-workload');
      await tap(tester, 'workload-view-forecast');
      expect(find.text('假定反馈'), findsOneWidget);
      final day1 = find.byKey(const ValueKey('workload-day-1'));
      expect(
        find.descendant(of: day1, matching: find.text('新词 0 · 复习 1')),
        findsOneWidget,
      );
      await tap(tester, 'workload-grade-0');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('workload-day-6')),
          matching: find.text('新词 0 · 复习 1'),
        ),
        findsOneWidget,
      );
      await tap(tester, 'workload-view-scheduled');
      expect(find.text('按当前排期，未计后续复习'), findsOneWidget);
      expect(await snapshot(tester), before);
      expect(h.notifications.scheduled, isEmpty);
      expect(h.notifications.cancelled, isEmpty);
      await finish(tester);
    },
  );

  testWidgets(
    'forecast refreshes for capacity and interval preference changes',
    (tester) async {
      await tester.runAsync(
        () => h.seed(task('a', 'apple', due: DateTime.now())),
      );
      await show(tester);
      await tap(tester, 'learning-workload');
      await tap(tester, 'workload-view-forecast');
      await tester.runAsync(
        () => h.container.read(workspaceDraftsProvider.notifier).put(
          'learningPreferences',
          {'daily': 5, 'new': 0},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('待排 1'), findsNWidgets(7));
      await tester.runAsync(() async {
        await h.container.read(workspaceDraftsProvider.notifier).put(
          'learningPreferences',
          {'daily': 5, 'new': 1},
        );
        await h.container.read(workspaceDraftsProvider.notifier).put(
          'learningIntervals',
          [2, 3, 5, 9, 15],
        );
      });
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('workload-day-1')),
          matching: find.text('新词 0 · 复习 0'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('workload-day-2')),
          matching: find.text('新词 0 · 复习 1'),
        ),
        findsOneWidget,
      );
      await finish(tester);
    },
  );

  testWidgets('real feedback and pause invalidate a visible cached forecast', (
    tester,
  ) async {
    await tester.runAsync(
      () => h.seed(task('a', 'apple', due: DateTime.now())),
    );
    await show(tester);
    await tap(tester, 'learning-workload');
    await tap(tester, 'workload-view-forecast');
    final day0 = find.byKey(const ValueKey('workload-day-0'));
    expect(
      find.descendant(of: day0, matching: find.text('新词 1 · 复习 0')),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      await h.notifier.gradeWord(await h.row('a'), 'apple', 2);
    });
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: day0, matching: find.text('新词 0 · 复习 0')),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      final current = await h.row('a');
      await h.notifier.updateReminder(
        current.copyWith(
          detailsJson: current.details.patch({'paused': true}).encode(),
        ),
        baseline: current,
      );
    });
    await tester.pumpAndSettle();
    expect(find.text('新词 0 · 复习 0'), findsNWidgets(7));
    await finish(tester);
  });

  testWidgets(
    'damaged intervals show an error and preserve the schedule and stored data',
    (tester) async {
      await tester.runAsync(() async {
        await h.seed(task('a', 'apple'));
        await h.container.read(workspaceDraftsProvider.notifier).put(
          'learningIntervals',
          ['bad'],
        );
      });
      final before = await snapshot(tester);
      await show(tester);
      await tap(tester, 'learning-workload');
      await tap(tester, 'workload-view-forecast');
      expect(find.text('暂时无法生成预测'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester, 'workload-view-scheduled');
      expect(find.text('1 词已排期'), findsOneWidget);
      expect(find.text('按当前排期，未计后续复习'), findsOneWidget);
      expect(await snapshot(tester), before);
      await finish(tester);
    },
  );

  for (final language in ['zh', 'en', 'ja']) {
    testWidgets(
      'forecast fits narrow and wide, large text, both themes: $language',
      (tester) async {
        await tester.runAsync(() => h.seed(task('a', 'apple')));
        for (final width in [320.0, 1280.0]) {
          for (final dark in [false, true]) {
            await show(
              tester,
              language: language,
              width: width,
              scale: 2,
              dark: dark,
            );
            await tap(tester, 'learning-workload');
            await tap(tester, 'workload-view-forecast');
            for (final grade in [2, 1, 0]) {
              await tap(tester, 'workload-grade-$grade');
            }
            expect(
              find.text(studyManagementText(language, 'forecastScope')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            await finish(tester);
          }
        }
      },
    );
  }
}
