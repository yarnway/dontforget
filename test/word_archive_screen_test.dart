import 'dart:convert';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/ui/screens/study_plans_screen.dart';
import 'package:dont_forget/ui/screens/word_archive_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/learning_management_panel.dart';
import 'package:dont_forget/ui/widgets/learning_workload_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'support/real_io.dart';
import 'word_archive_test.dart' show archivedWord;

void main() {
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  Future<void> show(
    WidgetTester tester, {
    String locale = 'zh',
    double width = 390,
    double scale = 1,
    bool dark = true,
    Widget? page,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          locale: Locale(locale),
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
          home: page ?? const WordArchiveScreen(),
        ),
      ),
    );
    if (page is Scaffold && page.body is LearningManagementPanel) {
      await pumpUntilRealIo(
        tester,
        () => find
            .byKey(const ValueKey('learning-word-archive'))
            .evaluate()
            .isNotEmpty,
        reason:
            'Wait for learning draft restoration before settling animations',
      );
    }
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
  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      await h.seed(archivedWord('a', 'apple', meaning: '苹果', reviews: 4));
      await h.seed(archivedWord('b', 'banana', day: 2));
    });
    h.notifications.scheduled.clear();
    h.notifications.cancelled.clear();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets(
    'search, copyable details and clearing search leave SQL and native calls unchanged',
    (tester) async {
      await seed(tester);
      final before = await snapshot(tester);
      await show(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('2 / 2 个词条'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '苹果');
      await tester.pumpAndSettle();
      expect(find.text('1 / 2 个词条'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('word-archive-apple')));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('学习阶段 1/5 · 复习次数 4'), findsOneWidget);
      expect(find.textContaining('记录的复习日期'), findsOneWidget);
      expect(find.text('保存修改'), findsNothing);
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2 个词条'), findsOneWidget);
      expect(await snapshot(tester), before);
      expect(h.notifications.scheduled, isEmpty);
      expect(h.notifications.cancelled, isEmpty);
      await finish(tester);
    },
  );
  testWidgets('empty and no-match states differ', (tester) async {
    await show(tester);
    expect(find.text('暂无学习记录'), findsOneWidget);
    await seed(tester);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'absent');
    await tester.pumpAndSettle();
    expect(find.text('未找到匹配词条'), findsOneWidget);
    await finish(tester);
  });
  testWidgets('live provider updates invalidate cached records and details', (
    tester,
  ) async {
    await seed(tester);
    await show(tester);
    await tester.enterText(find.byType(TextField), 'apple');
    await tester.runAsync(
      () => h.seed(
        archivedWord(
          'latest',
          'apple',
          day: 3,
          level: 4,
          reviews: 6,
          meaning: '新释义',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('新释义'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('word-archive-apple')));
    await tester.pumpAndSettle();
    expect(find.text('学习阶段 4/5 · 复习次数 6'), findsOneWidget);
    expect(find.text('1 / 2 个词条'), findsOneWidget);
    await finish(tester);
  });
  testWidgets(
    'invalid persisted progress shows error without deleting or rewriting it',
    (tester) async {
      await seed(tester);
      await tester.runAsync(() async {
        await h.database.writeTransaction(
          h.database.captureGeneration(),
          (db) => db.update(
            'Reminders',
            {'word_progress_json': '{"apple":[]}'},
            where: 'id = ?',
            whereArgs: ['a'],
          ),
        );
        await h.notifier.refreshReminders();
      });
      final before = await snapshot(tester);
      await show(tester);
      expect(find.textContaining('学习记录暂时无法读取'), findsOneWidget);
      expect(find.text('暂无学习记录'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(await snapshot(tester), before);
      await finish(tester);
    },
  );
  testWidgets(
    'study plans open the archive even when no retained plans remain',
    (tester) async {
      await seed(tester);
      await show(tester, page: const StudyPlansScreen());
      await tester.tap(find.byKey(const ValueKey('study-word-archive')));
      await tester.pumpAndSettle();
      expect(find.byType(WordArchiveScreen), findsOneWidget);
      expect(find.text('2 / 2 个词条'), findsOneWidget);
      await finish(tester);
    },
  );
  testWidgets(
    'learning management opens history and uses the shared collapsed workload',
    (tester) async {
      await seed(tester);
      await show(tester, page: const Scaffold(body: LearningManagementPanel()));
      await pumpUntilRealIo(
        tester,
        () => find
            .byKey(const ValueKey('learning-word-archive'))
            .evaluate()
            .isNotEmpty,
        reason: 'Learning panel restores its existing drafts',
      );
      await tester.pumpAndSettle();
      expect(find.byType(LearningWorkloadCard), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('learning-word-archive')));
      await tester.pumpAndSettle();
      expect(find.byType(WordArchiveScreen), findsOneWidget);
      await finish(tester);
    },
  );
  testWidgets(
    'damaged history does not crash learning management or its archive route',
    (tester) async {
      await seed(tester);
      await tester.runAsync(() async {
        await h.database.writeTransaction(
          h.database.captureGeneration(),
          (db) => db.update(
            'Reminders',
            {'word_progress_json': '{"apple":[]}'},
            where: 'id = ?',
            whereArgs: ['a'],
          ),
        );
        await h.notifier.refreshReminders();
      });
      await show(tester, page: const Scaffold(body: LearningManagementPanel()));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('learning-word-archive')));
      await tester.pumpAndSettle();
      expect(find.textContaining('学习记录暂时无法读取'), findsOneWidget);
      await finish(tester);
    },
  );
  for (final locale in ['zh', 'en', 'ja']) {
    for (final wide in [false, true]) {
      testWidgets(
        '$locale archive fits ${wide ? 'wide/light' : 'narrow/large/dark'} layout',
        (tester) async {
          await seed(tester);
          await show(
            tester,
            locale: locale,
            width: wide ? 1280 : 375,
            scale: wide ? 1 : 2,
            dark: !wide,
          );
          await tester.tap(find.byKey(const ValueKey('word-archive-banana')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await finish(tester);
        },
      );
    }
  }
}
