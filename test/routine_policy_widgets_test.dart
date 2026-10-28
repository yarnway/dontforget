import 'dart:convert';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/holiday_calendar.dart';
import 'package:dont_forget/models/ordinary_series.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/location_access_service.dart';
import 'package:dont_forget/ui/widgets/departure_plan_panel.dart';
import 'package:dont_forget/ui/widgets/holiday_policy_editor.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/planning_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'support/workspace_drafts.dart';

class _Location extends LocationAccessService {
  int requests = 0;
  @override
  Future<LocationAccessResult> locate({
    required bool Function() isCurrent,
  }) async {
    requests++;
    return const LocationAccessResult(
      LocationAccess.available,
      ApproximateLocation(31.23, 121.99),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  late _Location location;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    location = _Location();
  });
  tearDown(() async => h.dispose());
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 30));
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
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: ProviderScope(
          overrides: [
            locationAccessServiceProvider.overrideWithValue(location),
          ],
          child: MaterialApp(
            locale: Locale(locale),
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
              child: InlineFeedback(child: child!),
            ),
            home: Scaffold(body: child),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Key key) async {
    if (find.byKey(key).evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        find.byKey(key),
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
    }
    await tester.ensureVisible(find.byKey(key));
    await settle(tester);
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final sample in [
    (375.0, 'zh', 1.5),
    (768.0, 'en', 1.0),
    (1440.0, 'ja', 1.0),
  ]) {
    testWidgets(
      'departure policies fit ${sample.$1}/${sample.$2} and never implicitly request location',
      (tester) async {
        await tester.runAsync(
          () => h.container
              .read(workspaceDraftsProvider.notifier)
              .put(
                'departureDraft',
                DeparturePlan(
                  id: 'fixture',
                  title: 'Fixture',
                  weatherEnabled: true,
                  items: const [ChecklistItem('keys', 'Keys')],
                ).toJson(),
              ),
        );
        await host(
          tester,
          const DeparturePlanPanel(),
          width: sample.$1,
          locale: sample.$2,
          scale: sample.$3,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('departure-background-weather')),
          300,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 40,
        );
        await settle(tester);
        expect(location.requests, 0);
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('departure-background-weather')),
              )
              .value,
          false,
        );
        await finish(tester);
      },
    );
  }
  testWidgets(
    'one explicit location request stays in memory until adopted into the draft',
    (tester) async {
      await tester.runAsync(
        () => h.container
            .read(workspaceDraftsProvider.notifier)
            .put(
              'departureDraft',
              DeparturePlan(
                id: 'fixture',
                title: 'Fixture',
                weatherEnabled: true,
                items: const [ChecklistItem('keys', 'Keys')],
              ).toJson(),
            ),
      );
      await host(tester, const DeparturePlanPanel());
      await tap(tester, const ValueKey('departure-locate'));
      expect(location.requests, 1);
      final before =
          jsonDecode((await tester.runAsync<String?>(h.drafts))!) as Map;
      expect(before['departureDraft']['latitude'], isNull);
      await tap(tester, const ValueKey('departure-apply-location'));
      final after =
          jsonDecode((await tester.runAsync<String?>(h.drafts))!) as Map;
      expect(after['departureDraft']['latitude'], 31.23);
      expect(after['departureDraft']['longitude'], 121.99);
      expect((await tester.runAsync(h.rows))!, isEmpty);
      await finish(tester);
    },
  );
  testWidgets(
    'calendar import rejects invalid data, supports cancellation and preserves a validated snapshot',
    (tester) async {
      var value = const HolidayPolicy();
      await host(
        tester,
        StatefulBuilder(
          builder: (context, set) => SingleChildScrollView(
            child: HolidayPolicyEditor(
              value: value,
              onChanged: (next) => set(() => value = next),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('避开已公布放假日').last);
      await settle(tester);
      await tester.tap(find.text('导入日历 JSON'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('calendar-import-json')),
        '{}',
      );
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await settle(tester);
      expect(value.calendar!.id, 'CN-2026-20251104');
      await tester.tap(find.text('导入日历 JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(tester);
      await tester.tap(find.text('导入日历 JSON'));
      await tester.pumpAndSettle();
      final raw = {
        ...HolidayCalendar.mainland2026.toJson(),
        'id': 'next-year-fixture',
        'from': '2027-01-01',
        'to': '2027-12-31',
        'holidays': <String>[],
        'workdays': <String>[],
      };
      await tester.enterText(
        find.byKey(const ValueKey('calendar-import-json')),
        jsonEncode(raw),
      );
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await settle(tester);
      await tap(tester, const ValueKey('calendar-apply-update'));
      expect(value.calendar!.snapshots.map((e) => e.id), [
        'CN-2026-20251104',
        'next-year-fixture',
      ]);
      expect(value.calendar!.from, '2026-01-01');
      await finish(tester);
    },
  );
  testWidgets(
    'explicitly converting a future legacy task creates an owner with independent dates',
    (tester) async {
      final due = DateTime.now().add(const Duration(days: 1));
      final row = Reminder(
        id: 'legacy',
        taskTitle: 'Fixture task',
        quadrantLevel: 2,
        triggerTime: due,
        isRecurring: true,
        recurrenceRule: 'daily',
      );
      await tester.runAsync(() => h.seed(row));
      await host(
        tester,
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('edit'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => TaskManagementEditor(task: row),
            ),
            child: const Text('Open'),
          ),
        ),
      );
      await tap(tester, const ValueKey('edit'));
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('ordinary-independent')),
            )
            .value,
        false,
      );
      await tap(tester, const ValueKey('ordinary-independent'));
      await tap(tester, const ValueKey('task-management-save'));
      final rows = (await tester.runAsync(h.rows))!;
      expect(
        OrdinarySeries.isOwner(rows.singleWhere((r) => r.id == 'legacy')),
        true,
      );
      expect(rows.where(OrdinarySeries.isOccurrence).length, greaterThan(50));
      await finish(tester);
    },
  );
}
