import 'dart:convert';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/ui/screens/word_archive_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'support/real_io.dart';
import 'word_archive_cleanup_test.dart' show retainedWord;

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
    Size size = const Size(390, 800),
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
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
            child: InlineFeedback(child: child!),
          ),
          home: const WordArchiveScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      final past = DateTime.now().subtract(const Duration(days: 10));
      await h.seed(retainedWord('pear', reviewed: past));
      await h.seed(retainedWord('plum', reviewed: past));
      await h.seed(retainedWord('apple', reviewed: past));
      await h.seed(
        Reminder(
          id: 'control',
          taskTitle: 'Control',
          quadrantLevel: 4,
          taskSummary: 'apple — fruit\nAn example.',
        ),
      );
    });
    h.notifications.cancelled.clear();
    h.notifications.scheduled.clear();
  }

  Future<String?> snapshot(WidgetTester tester) => tester.runAsync(
    () async => jsonEncode({
      for (final table in ['Reminders', 'MediaRecords', 'Settings'])
        table: await h.database.read(
          h.database.captureGeneration(),
          (db) => db.query(table, orderBy: 'id'),
        ),
    }),
  );
  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('word-archive-cleanup')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('word-archive-cleanup-preview')),
      findsOneWidget,
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets(
    'preview and cancel leave all SQL fields and native calls unchanged',
    (tester) async {
      await seed(tester);
      final before = await snapshot(tester);
      await show(tester);
      await open(tester);
      expect(find.text('2 / 2 条保留记录'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('apple'),
        ),
        findsNothing,
      );
      expect(await snapshot(tester), before);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await snapshot(tester), before);
      expect(h.notifications.cancelled, isEmpty);
      await finish(tester);
    },
  );
  testWidgets(
    'explicit confirmation removes only the previewed histories and refreshes search',
    (tester) async {
      await seed(tester);
      await show(tester);
      await tester.enterText(find.byType(TextField), 'pear');
      await tester.pumpAndSettle();
      await open(tester);
      await tester.tap(
        find.byKey(const ValueKey('word-archive-cleanup-apply')),
      );
      await pumpUntilRealIo(
        tester,
        () => h.container.read(remindersProvider).length == 2,
        reason: 'Cleanup transaction and page state must complete',
      );
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配词条'), findsOneWidget);
      expect(await tester.runAsync(() => h.row('control')), isNotNull);
      expect(h.notifications.cancelled, isEmpty);
      expect(h.notifications.scheduled, isEmpty);
      await finish(tester);
    },
  );
  testWidgets(
    'a new reference while confirming rejects deletion and asks for a new preview',
    (tester) async {
      await seed(tester);
      await show(tester);
      await open(tester);
      await tester.runAsync(
        () => h.seed(
          Reminder(
            id: 'new',
            taskTitle: 'New',
            quadrantLevel: 4,
            taskSummary: 'pear — fruit\nAn example.',
          ),
        ),
      );
      final before = await snapshot(tester);
      await tester.tap(
        find.byKey(const ValueKey('word-archive-cleanup-apply')),
      );
      await pumpUntilRealIo(
        tester,
        () => find.text('档案已变更，请重新预览').evaluate().isNotEmpty,
        reason: 'Stale cleanup reports failure after real SQLite work',
      );
      expect(await snapshot(tester), before);
      await finish(tester);
    },
  );
  testWidgets('recovery invalidates the open preview', (tester) async {
    await seed(tester);
    await show(tester);
    await open(tester);
    final before = await snapshot(tester);
    await tester.runAsync(
      () async => (await h.database.beginMaintenance()).resume(),
    );
    await tester.tap(find.byKey(const ValueKey('word-archive-cleanup-apply')));
    await tester.pumpAndSettle();
    expect(await snapshot(tester), before);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('word-archive-cleanup')),
          )
          .onPressed,
      isNull,
    );
    await finish(tester);
  });
  testWidgets(
    'three languages, themes and narrow landscape retain scrollable preview and actions',
    (tester) async {
      await seed(tester);
      for (final locale in ['zh', 'en', 'ja']) {
        for (final size in [const Size(320, 568), const Size(568, 320)]) {
          await show(
            tester,
            locale: locale,
            size: size,
            scale: 2,
            dark: locale == 'ja',
          );
          await open(tester);
          expect(tester.takeException(), isNull);
          final button = find.byKey(
            const ValueKey('word-archive-cleanup-apply'),
          );
          expect(tester.getRect(button).bottom, lessThanOrEqualTo(size.height));
          expect(tester.getRect(button).top, greaterThanOrEqualTo(0));
          await tester.tap(
            find.text(
              AppLocalizations.of(tester.element(button)).get('cancel'),
            ),
          );
          await tester.pumpAndSettle();
          await finish(tester);
        }
      }
    },
  );
}
