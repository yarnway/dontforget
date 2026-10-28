import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/medication_plan.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/task_templates_provider.dart';
import 'package:dont_forget/ui/widgets/dose_taken_time_dialog.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/medication_plan_panel.dart';
import 'package:dont_forget/ui/widgets/planning_panel.dart';
import 'package:dont_forget/ui/widgets/task_template_library.dart';
import 'package:dont_forget/ui/widgets/weekly_task_review_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'support/workspace_drafts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  Future<void> host(
    WidgetTester tester,
    Widget child, {
    double width = 375,
    String locale = 'zh',
    double scale = 1,
    Brightness brightness = Brightness.light,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
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
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: InlineFeedback(child: child!),
          ),
          home: Scaffold(body: child),
        ),
      ),
    );
    await settle(tester);
  }

  Widget editorLauncher() => Builder(
    builder: (context) => TextButton(
      key: const ValueKey('open-editor'),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const TaskManagementEditor(),
      ),
      child: const Text('Open'),
    ),
  );
  Future<void> tap(WidgetTester tester, Key key) async {
    final f = find.byKey(key);
    await tester.ensureVisible(f);
    await tester.tap(f);
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> seedTemplates(WidgetTester tester) async => tester.runAsync(
    () => h.container
        .read(taskTemplateStoreProvider)
        .save(
          name: 'Travel',
          title: 'Pack bag',
          items: ['Passport', 'Headphones'],
          tags: ['personal'],
          project: 'Trip',
        ),
  );
  Future<void> seedTasks(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final id in ['Alpha', 'Beta']) {
        await h.seed(
          Reminder(
            id: id,
            taskTitle: id,
            quadrantLevel: 2,
            detailsJson: const TaskDetails().encode(),
          ),
        );
      }
      await h.seed(
        Reminder(
          id: 'plan',
          taskTitle: 'Synthetic plan',
          quadrantLevel: 2,
          detailsJson: const TaskDetails(kind: 'medicationPlan').encode(),
        ),
      );
    });
  }

  testWidgets(
    'template library create edit and confirmed deletion persist through real controls',
    (tester) async {
      await host(tester, const TaskTemplateLibrary());
      await tap(tester, const ValueKey('template-new'));
      await tester.enterText(
        find.byKey(const ValueKey('template-name')),
        'Travel',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-title')),
        'Pack bag',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-items')),
        'Passport\nHeadphones',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-tags')),
        'personal',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-project')),
        'Trip',
      );
      await tap(tester, const ValueKey('template-save'));
      final item = (await tester.runAsync(
        () => h.container.read(taskTemplateStoreProvider).load(),
      ))!.single;
      expect(item.items, ['Passport', 'Headphones']);
      expect(item.tags, ['personal']);
      await tap(tester, ValueKey('template-edit:${item.id}'));
      await tester.enterText(
        find.byKey(const ValueKey('template-name')),
        'Renamed',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-title')),
        'Updated bag',
      );
      await tap(tester, const ValueKey('template-save'));
      expect(find.text('Renamed'), findsOneWidget);
      expect(find.text('Updated bag'), findsOneWidget);
      await tap(tester, ValueKey('template-delete:${item.id}'));
      await tester.tap(find.widgetWithText(FilledButton, '删除模板'));
      await settle(tester);
      expect(
        await tester.runAsync(
          () => h.container.read(taskTemplateStoreProvider).load(),
        ),
        isEmpty,
      );
      expect(h.container.read(remindersProvider), isEmpty);
      await finish(tester);
    },
  );
  testWidgets(
    'template application previews fields before saving and creates fresh unchecked task items',
    (tester) async {
      await seedTemplates(tester);
      await host(tester, editorLauncher());
      final item = (await tester.runAsync(
        () => h.container.read(taskTemplateStoreProvider).load(),
      ))!.single;
      for (var n = 0; n < 2; n++) {
        await tap(tester, const ValueKey('open-editor'));
        await tap(tester, const ValueKey('editor-templates'));
        await tap(tester, ValueKey('template-use:${item.id}'));
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('task-management-title')),
              )
              .controller!
              .text,
          'Pack bag',
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('task-management-items')),
              )
              .controller!
              .text,
          'Passport\nHeadphones',
        );
        expect(h.container.read(remindersProvider), hasLength(n));
        await tap(tester, const ValueKey('task-management-save'));
      }
      final rows = (await tester.runAsync(h.rows))!;
      expect(rows, hasLength(2));
      expect(
        rows.every(
          (e) =>
              e.triggerTime == null &&
              e.details.checklist.every((i) => !i.done),
        ),
        isTrue,
      );
      expect(
        rows.first.details.checklist
            .map((e) => e.id)
            .toSet()
            .intersection(rows.last.details.checklist.map((e) => e.id).toSet()),
        isEmpty,
      );
      await finish(tester);
    },
  );
  testWidgets('save as template retains unsaved form without creating a task', (
    tester,
  ) async {
    await host(tester, editorLauncher());
    await tap(tester, const ValueKey('open-editor'));
    await tester.enterText(
      find.byKey(const ValueKey('task-management-title')),
      'My checklist',
    );
    await tester.enterText(
      find.byKey(const ValueKey('task-management-items')),
      'Keys\nHeadphones',
    );
    await tap(tester, const ValueKey('editor-save-template'));
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('template-title')))
          .controller!
          .text,
      'My checklist',
    );
    await tester.enterText(
      find.byKey(const ValueKey('template-name')),
      'Morning',
    );
    await tap(tester, const ValueKey('template-save'));
    expect(h.container.read(remindersProvider), isEmpty);
    expect(
      (await tester.runAsync(
        () => h.container.read(taskTemplateStoreProvider).load(),
      ))!.single.items,
      ['Keys', 'Headphones'],
    );
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester);
    expect(h.container.read(remindersProvider), isEmpty);
    await finish(tester);
  });
  testWidgets(
    'template editor opened before recovery cannot write into the new generation',
    (tester) async {
      await host(tester, const TaskTemplateLibrary());
      await tap(tester, const ValueKey('template-new'));
      await tester.enterText(
        find.byKey(const ValueKey('template-name')),
        'Old',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-title')),
        'Old',
      );
      await tester.runAsync(() async {
        final lease = await h.database.beginMaintenance();
        await lease.resume();
      });
      await tap(tester, const ValueKey('template-save'));
      expect(find.text('模板未保存，请核对输入并重试'), findsOneWidget);
      expect(await tester.runAsync(h.drafts), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'bulk pause requires confirmation and excludes plans from matching selection',
    (tester) async {
      await seedTasks(tester);
      await host(tester, const TaskManagementPanel());
      await tap(tester, const ValueKey('bulk-select'));
      await tap(tester, const ValueKey('bulk-visible'));
      expect(find.byKey(const ValueKey('bulk-row:plan')), findsNothing);
      await tap(tester, const ValueKey('bulk-pause'));
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(tester);
      expect(
        h.container.read(remindersProvider).every((e) => !e.details.paused),
        isTrue,
      );
      await tap(tester, const ValueKey('bulk-pause'));
      await tap(tester, const ValueKey('bulk-confirm'));
      final rows = (await tester.runAsync(h.rows))!;
      expect(
        rows.where((e) => e.id != 'plan').every((e) => e.details.paused),
        isTrue,
      );
      expect(rows.singleWhere((e) => e.id == 'plan').details.paused, isFalse);
      await finish(tester);
    },
  );
  testWidgets(
    'bulk dialog rejects concurrent edits without pausing another selected task',
    (tester) async {
      await seedTasks(tester);
      await host(tester, const TaskManagementPanel());
      await tap(tester, const ValueKey('bulk-select'));
      await tap(tester, const ValueKey('bulk-visible'));
      await tap(tester, const ValueKey('bulk-pause'));
      await tester.runAsync(() async {
        final row = await h.row('Beta');
        await h.notifier.updateReminderForGeneration(
          row.copyWith(taskTitle: 'Concurrent edit'),
          h.database.captureGeneration(),
          baseline: row,
        );
      });
      await tap(tester, const ValueKey('bulk-confirm'));
      expect(
        h.container.read(remindersProvider).every((e) => !e.details.paused),
        isTrue,
      );
      expect(find.text('所选事项已变化或保存失败，请重新选择后重试'), findsOneWidget);
      await finish(tester);
    },
  );
  testWidgets(
    'changing the query clears the old selection and weekly review follows the query',
    (tester) async {
      final now = DateTime.now();
      await tester.runAsync(
        () => h.seed(
          Reminder(
            id: 'Alpha',
            taskTitle: 'Alpha',
            quadrantLevel: 2,
            detailsJson: TaskDetails(
              history: [TaskEvent('completed', now)],
            ).encode(),
          ),
        ),
      );
      await host(tester, const TaskManagementPanel());
      await tap(tester, const ValueKey('bulk-select'));
      await tap(tester, const ValueKey('bulk-visible'));
      await tester.enterText(find.byType(TextField).first, 'missing');
      await settle(tester);
      expect(find.text('已选择: 0/50'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('bulk-pause')))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField).first, 'Alpha');
      await tester.tap(find.widgetWithText(ChoiceChip, '执行记录'));
      await settle(tester);
      expect(find.text('执行记录周复盘'), findsOneWidget);
      expect(find.text('完成次数: 1'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('review-next-week')))
            .onPressed,
        isNull,
      );
      await tap(tester, const ValueKey('review-previous-week'));
      expect(find.text('完成次数: 0'), findsOneWidget);
      await tap(tester, const ValueKey('review-next-week'));
      expect(find.text('完成次数: 1'), findsOneWidget);
      await finish(tester);
    },
  );
  testWidgets(
    'dose time confirmation persists the outcome without moving the planned dose',
    (tester) async {
      final day = DateTime.now();
      final plan = MedicationPlan(
        id: 'owner',
        title: 'Synthetic course',
        start: DateTime(day.year, day.month, day.day),
        end: DateTime(day.year, day.month, day.day + 1),
        medicines: [
          Medicine(
            id: 'sample',
            name: 'Synthetic',
            strength: 'Test only',
            amount: '1',
            unit: 'fixture',
            meal: 'Fixture only',
            times: const ['07:00'],
          ),
        ],
      );
      final scheduled = DateTime(day.year, day.month, day.day, 7);
      await tester.runAsync(() async {
        await h.seed(
          Reminder(
            id: 'owner',
            taskTitle: plan.title,
            quadrantLevel: 2,
            detailsJson: TaskDetails(
              kind: 'medicationPlan',
              data: plan.toJson(),
            ).encode(),
          ),
        );
        await h.seed(
          Reminder(
            id: 'dose',
            taskTitle: 'Synthetic',
            quadrantLevel: 2,
            eventTime: scheduled,
            triggerTime: scheduled,
            detailsJson: TaskDetails(
              kind: 'medication',
              planId: 'owner',
              data: plan.medicines.single.toJson(),
            ).encode(),
          ),
        );
      });
      await host(tester, const MedicationPlanPanel(initialPlanId: 'owner'));
      final dose = h.container
          .read(remindersProvider)
          .firstWhere((e) => e.details.kind == 'medication');
      final button = find.byKey(ValueKey('dose-time:${dose.id}'));
      await tester.scrollUntilVisible(
        button,
        400,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // Lazy children can change the scroll extent after the first layout.
      await tester.pumpAndSettle();
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await settle(tester);
      expect(find.byType(DoseTakenTimeDialog), findsOneWidget);
      await tap(tester, const ValueKey('dose-actual-save'));
      final saved = (await tester.runAsync(() => h.row(dose.id)))!;
      expect(saved.isCompleted, isTrue);
      expect(saved.details.actualDoseTakenAt, isNotNull);
      expect(saved.eventTime, dose.eventTime);
      expect(saved.details.history.last.action, 'taken');
      await finish(tester);
    },
  );

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final locale in ['zh', 'en', 'ja']) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        testWidgets(
          'offline panels fit $locale $width $brightness large text',
          (tester) async {
            for (final child in [
              const TaskTemplateLibrary(),
              const TaskTemplateEditorDialog(),
              const WeeklyTaskReviewPanel(rows: []),
              DoseTakenTimeDialog(initialTime: DateTime(2020)),
            ]) {
              await host(
                tester,
                child,
                width: width,
                locale: locale,
                scale: 1.8,
                brightness: brightness,
              );
              expect(
                tester.takeException(),
                isNull,
                reason: child.runtimeType.toString(),
              );
              await finish(tester);
            }
          },
        );
      }
    }
  }
  testWidgets(
    'template form remains scrollable above a small-screen keyboard',
    (tester) async {
      await host(
        tester,
        const TaskTemplateEditorDialog(),
        width: 375,
        scale: 2,
        keyboard: 300,
      );
      final project = find.byKey(const ValueKey('template-project'));
      await tester.ensureVisible(project);
      await tester.enterText(project, 'Visible');
      await tester.pump();
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
}
