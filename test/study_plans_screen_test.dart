import 'package:dont_forget/ui/widgets/study_plan_panel.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/study_plan_group.dart';
import 'package:dont_forget/ui/screens/study_plans_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'support/real_io.dart';
import 'study_plan_management_test.dart' show batch;

void main() {
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  Future<void> settle(WidgetTester tester) async {
    await pumpUntilRealIo(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      reason: 'Plan transaction and native reconciliation must finish',
    );
    await tester.pumpAndSettle();
  }

  Future<void> show(
    WidgetTester tester, {
    String locale = 'zh',
    double width = 390,
    double scale = 1,
    Widget? page,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: InlineFeedback(child: child!),
          ),
          home: page == null ? const StudyPlansScreen() : Scaffold(body: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String text) async {
    await tester.tap(find.byKey(const ValueKey('study-plan-actions-p')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('workload is collapsed and refreshes after pausing a plan', (
    tester,
  ) async {
    await tester.runAsync(
      () => h.seed(
        batch(
          'p-0',
        ).copyWith(wordProgressJson: null, nextReviewAt: DateTime.now()),
      ),
    );
    await show(tester);
    expect(find.text('未来7天'), findsOneWidget);
    expect(find.text('1 词已排期'), findsOneWidget);
    await tester.tap(find.byKey(const PageStorageKey('learning-workload')));
    await tester.pumpAndSettle();
    expect(find.text('按当前排期，未计后续复习'), findsOneWidget);
    await tester.tap(find.byKey(const PageStorageKey('learning-workload')));
    await tester.pumpAndSettle();
    await menu(tester, '暂停计划');
    await settle(tester);
    expect(find.text('0 词已排期'), findsOneWidget);
    await finish(tester);
  });

  Future<void> selectPlans(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('study-plan-select')));
    await tester.pumpAndSettle();
    for (final id in ['p', 'q']) {
      final check = find.byKey(ValueKey('study-plan-check-$id'));
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'date preview cancels without writes, validates days, and commits selected plans',
    (tester) async {
      await tester.runAsync(() async {
        await h.seed(batch('p-0'));
        await h.seed(batch('q-0', plan: 'q', paused: true));
      });
      await show(tester);
      await selectPlans(tester);
      final before = h.notifier.state.map((r) => r.toJson()).toList();
      await tester.tap(find.byKey(const ValueKey('study-plans-shift')));
      await tester.pumpAndSettle();
      expect(find.textContaining('→ '), findsNWidgets(2));
      await tester.enterText(
        find.byKey(const ValueKey('study-shift-days')),
        '0',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('study-shift-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(h.notifier.state.map((r) => r.toJson()).toList(), before);
      expect(find.byKey(const ValueKey('study-plans-shift')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('study-plans-shift')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('顺延7天'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('study-shift-confirm')));
      await tester.pump();
      await settle(tester);
      await tester.runAsync(() async {
        expect((await h.row('p-0')).nextReviewAt, DateTime(2030, 1, 15, 8));
        expect((await h.row('q-0')).nextReviewAt, DateTime(2030, 1, 15, 8));
        expect((await h.row('q-0')).details.paused, true);
      });
      expect(find.byKey(const ValueKey('study-plans-shift')), findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'single-plan preview explains shared progress without an enabled commit',
    (tester) async {
      await tester.runAsync(() async {
        await h.seed(batch('p-0'));
        await h.seed(batch('q-0', plan: 'q'));
      });
      await show(tester);
      await menu(tester, '调整日期');
      await tester.pumpAndSettle();
      expect(find.text('请同时选择共享已学词条的其他计划'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('study-shift-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets('a date preview cannot overwrite a concurrent edit', (
    tester,
  ) async {
    await tester.runAsync(() => h.seed(batch('p-0')));
    await show(tester);
    await menu(tester, '调整日期');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final row = await h.row('p-0');
      await h.notifier.updateReminder(
        row.copyWith(taskTitle: 'Changed'),
        baseline: row,
      );
    });
    await tester.tap(find.byKey(const ValueKey('study-shift-confirm')));
    await tester.pump();
    await settle(tester);
    expect(find.text('计划已变更，请重新操作'), findsOneWidget);
    await tester.runAsync(
      () async =>
          expect((await h.row('p-0')).nextReviewAt, DateTime(2030, 1, 8, 8)),
    );
    await finish(tester);
  });

  for (final locale in ['zh', 'en', 'ja']) {
    for (final width in [375.0, 1280.0]) {
      testWidgets('$locale date preview fits $width at 200% text', (
        tester,
      ) async {
        await tester.runAsync(() => h.seed(batch('p-0')));
        await show(tester, locale: locale, width: width, scale: 2);
        await tester.tap(find.byKey(const ValueKey('study-plan-actions-p')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(switch (locale) {
            'zh' => '调整日期',
            'ja' => '日程を調整',
            _ => 'Adjust dates',
          }),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('study-shift-confirm')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('study-shift-confirm')));
        await tester.pump();
        await settle(tester);
        expect(h.notifier.state.single.nextReviewAt, DateTime(2030, 1, 9, 8));
        expect(tester.takeException(), isNull);
        await finish(tester);
      });
    }
  }

  testWidgets(
    '50-batch preview stays scrollable above a small-screen keyboard',
    (tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 50; i++) {
          await h.seed(batch('p-$i'));
        }
      });
      await show(tester, width: 375, scale: 2);
      tester.view.physicalSize = const Size(375, 600);
      await tester.pumpAndSettle();
      await menu(tester, '调整日期');
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        find.byKey(const ValueKey('study-shift-days')),
        '-2',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Batch p-49'));
      await tester.pumpAndSettle();
      final apply = find.byKey(const ValueKey('study-shift-confirm'));
      expect(tester.getRect(apply).bottom, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
      await tester.tap(apply);
      await tester.pump();
      await settle(tester);
      expect(h.notifier.state.length, 50);
      expect(
        h.notifier.state.every(
          (r) => r.nextReviewAt == DateTime(2030, 1, 6, 8),
        ),
        true,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'selected plans pause together and clear selection after commit',
    (tester) async {
      await tester.runAsync(() async {
        await h.seed(batch('p-0'));
        await h.seed(batch('q-0', plan: 'q'));
      });
      await show(tester);
      await selectPlans(tester);
      expect(find.text('已选计划 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('study-plans-pause')));
      await tester.pump();
      await settle(tester);
      expect(h.notifier.state.every((r) => r.details.paused), true);
      expect(find.byKey(const ValueKey('study-plans-pause')), findsNothing);
      await selectPlans(tester);
      await tester.tap(find.byKey(const ValueKey('study-plans-resume')));
      await tester.pump();
      await settle(tester);
      expect(h.notifier.state.any((r) => r.details.paused), false);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets('selected snapshots stay frozen when another plan changes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await h.seed(batch('p-0'));
      await h.seed(batch('q-0', plan: 'q'));
    });
    await show(tester);
    await selectPlans(tester);
    await tester.runAsync(() async {
      final old = await h.row('q-0');
      await h.notifier.updateReminder(
        old.copyWith(taskTitle: 'Changed later'),
        baseline: old,
      );
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-plans-pause')));
    await tester.pump();
    await settle(tester);
    expect(h.notifier.state.any((r) => r.details.paused), false);
    expect(find.text('计划已变更，请重新操作'), findsOneWidget);
    expect(find.byKey(const ValueKey('study-plans-pause')), findsNothing);
    await finish(tester);
  });

  testWidgets('study editor opens plan management without losing its draft', (
    tester,
  ) async {
    await tester.runAsync(() => h.seed(batch('p-0')));
    final draft = StudyPlanDraft()..notes = 'Keep this unsaved preference';
    addTearDown(draft.dispose);
    await show(
      tester,
      page: StudyPlanPanel(
        draft: draft,
        onClose: () {},
        onBusyChanged: (_) {},
        onReview: () {},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('manage-study-plans')));
    await tester.pumpAndSettle();
    expect(find.byType(StudyPlansScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('study-plan-p')), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byType(StudyPlanPanel), findsOneWidget);
    expect(draft.notes, 'Keep this unsaved preference');
    expect(draft.plan, isNull);
    await finish(tester);
  });

  testWidgets(
    'pause, resume and confirmed trash refresh only the selected group',
    (tester) async {
      await tester.runAsync(() async {
        await h.seed(batch('p-0'));
        await h.seed(batch('p-1'));
        await h.seed(batch('q-0', plan: 'q'));
      });
      await show(tester);
      await menu(tester, '暂停计划');
      await settle(tester);
      expect(find.textContaining('2 已暂停'), findsOneWidget);
      expect(find.text('计划已更新'), findsNothing);
      expect(
        h.notifier.state
            .where((r) => StudyPlanGroup.identity(r) == 'p')
            .every((r) => r.details.paused),
        true,
      );
      expect(
        h.notifier.state.singleWhere((r) => r.id == 'q-0').details.paused,
        false,
      );
      await menu(tester, '继续计划');
      await settle(tester);
      expect(find.textContaining('2 已暂停'), findsNothing);
      expect(
        h.notifier.state
            .where((r) => StudyPlanGroup.identity(r) == 'p')
            .any((r) => r.details.paused),
        false,
      );
      await menu(tester, '移至回收站');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(h.notifier.state.any((r) => r.details.deletedAt != null), false);
      await tester.tap(find.byKey(const ValueKey('study-plan-confirm-trash')));
      await tester.pump();
      await settle(tester);
      expect(find.byKey(const ValueKey('study-plan-p')), findsNothing);
      expect(find.byKey(const ValueKey('study-plan-q')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'changed member while trash confirmation is open refuses the complete selection',
    (tester) async {
      await tester.runAsync(() async {
        await h.seed(batch('p-0'));
        await h.seed(batch('p-1'));
      });
      await show(tester);
      await menu(tester, '移至回收站');
      await tester.runAsync(() async {
        final old = await h.row('p-1');
        await h.notifier.updateReminder(
          old.copyWith(taskTitle: 'Edited elsewhere'),
          baseline: old,
        );
      });
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('study-plan-confirm-trash')));
      await tester.pump();
      await settle(tester);
      expect(find.text('计划已变更，请重新操作'), findsOneWidget);
      expect(h.notifier.state.every((r) => r.details.deletedAt == null), true);
      expect(
        h.notifier.state.singleWhere((r) => r.id == 'p-1').taskTitle,
        'Edited elsewhere',
      );
      await finish(tester);
    },
  );

  for (final locale in ['zh', 'en', 'ja']) {
    testWidgets('plan list fits narrow large text and wide $locale layouts', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await h.seed(batch('p-0'));
        await h.seed(batch('p-1', paused: true));
      });
      for (final width in [375.0, 1280.0]) {
        await show(tester, locale: locale, width: width, scale: 2);
        expect(find.byKey(const ValueKey('study-plan-p')), findsOneWidget);
        await tester.tap(
          find.byKey(const PageStorageKey('study-plan-members-p')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const PageStorageKey('learning-workload')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('study-plan-select')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('study-plans-pause')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await finish(tester);
      }
    });
  }
}
