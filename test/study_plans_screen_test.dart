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
        expect(tester.takeException(), isNull);
        await finish(tester);
      }
    });
  }
}
