import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/calendar_exceptions.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/medication_evidence.dart';
import 'package:dont_forget/models/medication_plan.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/ui/widgets/calendar_exceptions_editor.dart';
import 'package:dont_forget/ui/widgets/departure_plan_panel.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/medication_plan_panel.dart';
import 'package:dont_forget/ui/widgets/planning_panel.dart';
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
    await h.container.read(mediaRecordsProvider.notifier).ready;
  });
  tearDown(() => h.dispose());
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 18; i++) {
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

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 30000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        finder,
        350,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 45,
      );
    } else {
      await tester.ensureVisible(finder);
    }
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await reveal(tester, finder);
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Map<String, dynamic> draft({bool evidence = false}) {
    final m = Medicine(
      id: 'medicine',
      name: 'Synthetic medicine',
      strength: 'Fixture form',
      amount: '1',
      unit: 'fixture unit',
      meal: 'explicit fixture instruction',
      mealLinks: const [MealDoseTime(mealId: 'breakfast', offsetMinutes: -30)],
    );
    final p = MedicationPlan(
      id: 'course',
      title: 'Synthetic course',
      start: DateTime(2030, 1, 7),
      end: DateTime(2030, 1, 9),
      medicines: [m],
      meals: const [
        MealTime(id: 'breakfast', label: 'Breakfast', time: '08:00'),
      ],
    );
    final raw = p.toJson();
    if (evidence) {
      raw['sources'] = [
        const MedicationSource(
          id: 'label',
          kind: 'text',
          label: 'Label',
          text: 'one tablet',
        ).toJson(),
        const MedicationSource(
          id: 'order',
          kind: 'text',
          label: 'Order',
          text: 'two tablets',
        ).toJson(),
      ];
      raw['review_sources'] = true;
      raw['resolved_fields'] = {
        for (final f in ['title', 'start', 'end'])
          f: MedicationFacts.fingerprint(f, raw[f], []),
      };
      final med = raw['medicines'][0] as Map<String, dynamic>;
      med['provenance'] = [
        const MedicationCitation(
          field: 'amount',
          sourceId: 'label',
          value: '1',
          quote: 'one tablet',
        ).toJson(),
        const MedicationCitation(
          field: 'amount',
          sourceId: 'order',
          value: '2',
          quote: 'two tablets',
        ).toJson(),
      ];
      med['resolved_fields'] = {
        for (final f in ['name', 'strength', 'unit', 'meal', 'times'])
          f: MedicationFacts.fingerprint(
            f,
            f == 'times' ? ['07:30'] : med[f],
            [],
          ),
      };
    }
    return raw;
  }

  Future<void> seedDraft(WidgetTester tester, Map<String, dynamic> raw) async {
    await tester.runAsync(
      () => h.container
          .read(workspaceDraftsProvider.notifier)
          .put('medicationDraft', raw),
    );
  }

  Finder field(String suffix) => find.byWidgetPredicate(
    (w) =>
        w is TextFormField &&
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.endsWith(suffix),
  );
  testWidgets(
    'conflicting source field blocks preview, choosing a fact updates form and enables finite plan',
    (tester) async {
      await seedDraft(tester, draft(evidence: true));
      await host(tester, const MedicationPlanPanel());
      await tap(tester, find.text('预览'));
      expect(find.text('还有资料冲突或缺少引用的字段，请先完成资料核对。'), findsOneWidget);
      expect(h.container.read(remindersProvider), isEmpty);
      await tap(tester, find.text('采用此值').last);
      await reveal(tester, field(':amount'));
      expect(tester.widget<TextFormField>(field(':amount')).initialValue, '2');
      await tap(tester, find.text('预览'));
      await tap(tester, find.text('已逐药核对用量、时刻和疗程'));
      await tap(tester, find.text('确认并启用'));
      final rows = (await tester.runAsync(h.rows))!;
      expect(rows, hasLength(4));
      expect(
        rows
            .where((r) => r.details.kind == 'medication')
            .every(
              (r) =>
                  r.details.data['amount'] == '2' &&
                  r.triggerTime!.hour == 7 &&
                  r.triggerTime!.minute == 30,
            ),
        isTrue,
      );
      await finish(tester);
    },
  );
  testWidgets(
    'explicit meal clock edit recalculates preview and survives reopening',
    (tester) async {
      await seedDraft(tester, draft());
      await host(tester, const MedicationPlanPanel());
      await tap(tester, find.text('用餐时间（可选）'));
      await reveal(
        tester,
        find.byKey(const ValueKey('meal-clock:breakfast:1')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('meal-clock:breakfast:1')),
        '09：00',
      );
      await settle(tester);
      await tap(tester, find.text('预览'));
      expect(find.textContaining('Breakfast 09:00 (-30 min)'), findsWidgets);
      await finish(tester);
      await host(tester, const MedicationPlanPanel());
      final raw =
          h.container.read(workspaceDraftsProvider)['medicationDraft'] as Map;
      expect(raw['meals'][0]['time'], '09:00');
      await tap(tester, find.text('预览'));
      expect(find.textContaining('Breakfast 09:00 (-30 min)'), findsWidgets);
      await finish(tester);
    },
  );
  testWidgets(
    'multiple saved sources add and detach without deleting original records',
    (tester) async {
      await tester.runAsync(() async {
        for (final id in ['a', 'b']) {
          await h.container
              .read(mediaRecordsProvider.notifier)
              .addRecord(
                MediaRecord(
                  id: id,
                  type: 'text',
                  contentOrPath: 'Source $id',
                  createdAt: DateTime(2030),
                ),
              );
        }
      });
      await host(tester, const MedicationPlanPanel());
      for (final id in ['a', 'b']) {
        await tap(tester, find.byType(DropdownButtonFormField<String>).first);
        await tester.tap(find.text('text · Source $id').last);
        await settle(tester);
      }
      expect(
        (h.container.read(workspaceDraftsProvider)['medicationDraft']
            as Map)['sources'],
        hasLength(2),
      );
      await tap(tester, find.widgetWithText(ListTile, 'text · Source a'));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(tester);
      await tap(
        tester,
        find.descendant(
          of: find.widgetWithText(ListTile, 'text · Source a'),
          matching: find.byType(IconButton),
        ),
      );
      expect(
        (h.container.read(workspaceDraftsProvider)['medicationDraft']
            as Map)['sources'],
        hasLength(1),
      );
      expect(h.container.read(mediaRecordsProvider), hasLength(2));
      await finish(tester);
    },
  );
  testWidgets(
    'incomplete meal link retains raw offset draft and cannot preview',
    (tester) async {
      final raw = draft();
      raw['medicines'][0]['meal_links'] = [
        {
          'meal_id': 'breakfast',
          'offset': null,
          'side': 'before',
          'minutes': 'bad',
        },
      ];
      await seedDraft(tester, raw);
      await host(tester, const MedicationPlanPanel());
      await tap(tester, find.text('预览'));
      expect(find.text('请补齐名称、起止日期，以及每种药的规格、用量、单位、餐次和具体时刻。'), findsOneWidget);
      await finish(tester);
      await host(tester, const MedicationPlanPanel());
      await tap(tester, find.text('按餐时安排（可选）'));
      final offset = find.byKey(const ValueKey('meal-offset:medicine:0:1'));
      await reveal(tester, offset);
      expect(tester.widget<TextFormField>(offset).initialValue, 'bad');
      await tester.enterText(offset, '30');
      await settle(tester);
      await tap(tester, find.text('预览'));
      await reveal(tester, find.text('已逐药核对用量、时刻和疗程'));
      expect(find.text('已逐药核对用量、时刻和疗程'), findsOneWidget);
      await finish(tester);
    },
  );
  testWidgets(
    'date editor rejects overlapping dates and recovers without changing last valid rule',
    (tester) async {
      CalendarExceptions? selected;
      await host(
        tester,
        ListView(
          children: [
            CalendarExceptionsEditor(
              initial: const CalendarExceptions(),
              scopeHint: 'reminderDatesHint',
              onChanged: (value, raw) => selected = value,
            ),
          ],
        ),
      );
      await tap(tester, find.text('指定日期调整'));
      await tester.enterText(
        find.byKey(const ValueKey('exceptions-skip')),
        '2030-01-07',
      );
      await tester.enterText(
        find.byKey(const ValueKey('exceptions-add')),
        '2030-01-07',
      );
      await tester.pump();
      expect(selected, isNull);
      expect(find.text('请检查日期格式、重复或冲突；修正后才能保存。'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('exceptions-add')),
        '2030-01-08',
      );
      await tester.pump();
      expect(selected!.skip, ['2030-01-07']);
      expect(selected!.add, ['2030-01-08']);
      await finish(tester);
    },
  );
  testWidgets(
    'ordinary editor skips initial month-end without drifting later months',
    (tester) async {
      final base = DateTime(2030, 1, 31, 8);
      await tester.runAsync(
        () => h.seed(
          Reminder(
            id: 'monthly',
            taskTitle: 'Month end',
            quadrantLevel: 2,
            createdAt: DateTime.now(),
            triggerTime: base,
            eventTime: base,
            isRecurring: true,
            recurrenceRule: 'monthly',
          ),
        ),
      );
      final row = h.container.read(remindersProvider).single;
      await host(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => TaskManagementEditor(task: row),
            ),
            child: const Text('Open'),
          ),
        ),
      );
      await tap(tester, find.text('Open'));
      await tap(tester, find.text('指定日期调整'));
      await reveal(tester, find.byKey(const ValueKey('exceptions-skip')));
      await tester.enterText(
        find.byKey(const ValueKey('exceptions-skip')),
        '2030-01-31',
      );
      await tap(tester, find.byKey(const ValueKey('task-management-save')));
      final saved = (await tester.runAsync(() => h.row('monthly')))!;
      expect(saved.triggerTime, DateTime(2030, 2, 28, 8));
      expect(saved.details.repeat!.anchor, base);
      expect(
        saved.getNextOccurrence(after: saved.triggerTime),
        DateTime(2030, 3, 31, 8),
      );
      await finish(tester);
    },
  );
  testWidgets(
    'invalid departure date raw draft survives reopen and prevents activation',
    (tester) async {
      final p = DeparturePlan(
        id: 'departure',
        title: 'Fixture',
        items: const [ChecklistItem('keys', 'Keys')],
      );
      await tester.runAsync(
        () => h.container.read(workspaceDraftsProvider.notifier).put(
          'departureDraft',
          {
            ...p.toJson(),
            'exceptions_draft': {'skip': '2030-02-30', 'add': ''},
          },
        ),
      );
      await host(tester, const DeparturePlanPanel());
      await tap(tester, find.text('指定日期调整'));
      expect(find.text('请检查日期格式、重复或冲突；修正后才能保存。'), findsWidgets);
      expect(
        (h.container.read(workspaceDraftsProvider)['departureDraft']
            as Map)['exceptions_draft']['skip'],
        '2030-02-30',
      );
      await reveal(tester, find.widgetWithText(FilledButton, '预览'));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '预览'))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('exceptions-skip')),
        '2030-01-07',
      );
      await settle(tester);
      expect(
        (h.container.read(workspaceDraftsProvider)['departureDraft']
            as Map)['calendar_exceptions']['skip'],
        ['2030-01-07'],
      );
      await finish(tester);
    },
  );
  for (final width in [375.0, 768.0, 1440.0]) {
    for (final locale in ['zh', 'en', 'ja']) {
      testWidgets(
        'expanded evidence meal and date controls fit $width $locale large text dark keyboard',
        (tester) async {
          await seedDraft(tester, draft(evidence: true));
          await host(
            tester,
            const MedicationPlanPanel(),
            width: width,
            locale: locale,
            scale: 1.8,
            brightness: Brightness.dark,
            keyboard: 260,
          );
          await reveal(
            tester,
            find.byKey(const ValueKey('review-current:amount')),
          );
          expect(tester.takeException(), isNull);
          final meals = find.widgetWithText(
            ExpansionTile,
            locale == 'zh'
                ? '用餐时间（可选）'
                : locale == 'en'
                ? 'Meal times (optional)'
                : '食事時刻（任意）',
          );
          await tap(tester, meals);
          await reveal(
            tester,
            find.byKey(const ValueKey('meal-clock:breakfast:1')),
          );
          expect(tester.takeException(), isNull);
          await finish(tester);
          await host(
            tester,
            ListView(
              children: [
                CalendarExceptionsEditor(
                  initial: const CalendarExceptions(),
                  scopeHint: 'departureDatesHint',
                  onChanged: (_, raw) {},
                ),
              ],
            ),
            width: width,
            locale: locale,
            scale: 1.8,
            brightness: Brightness.dark,
            keyboard: 260,
          );
          await tap(tester, find.byType(ExpansionTile));
          await reveal(tester, find.byKey(const ValueKey('exceptions-add')));
          expect(tester.takeException(), isNull);
          await finish(tester);
        },
      );
    }
  }
}
