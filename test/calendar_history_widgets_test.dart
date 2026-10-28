import 'dart:async';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/holiday_calendar.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/holiday_calendar_file_service.dart';
import 'package:dont_forget/ui/widgets/holiday_policy_editor.dart';
import 'package:dont_forget/ui/widgets/routine_dates_panel.dart';
import 'package:dont_forget/ui/widgets/planning_panel.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'support/workspace_drafts.dart';

class _Files extends HolidayCalendarFileService {
  Completer<HolidayCalendar?>? pending;
  HolidayCalendar? incoming;
  @override
  Future<HolidayCalendar?> pick() async =>
      pending == null ? incoming : await pending!.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  late _Files files;
  final start = DateTime(2030, 1, 7, 6), now = DateTime(2030, 1, 10, 10);
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    files = _Files();
    await h.notifier.saveOrdinarySeries(
      Reminder(
        id: 'daily',
        taskTitle: 'Fixture daily',
        quadrantLevel: 2,
        triggerTime: DateTime(2030, 1, 7, 8),
        isRecurring: true,
        recurrenceRule: 'daily',
      ),
      h.database.captureGeneration(),
      now: start,
    );
  });
  tearDown(() async => h.dispose());
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpAndSettle();
  }

  Future<void> host(
    WidgetTester tester,
    Widget child, {
    double width = 375,
    String lang = 'zh',
    double scale = 1,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: ProviderScope(
          overrides: [holidayCalendarFilesProvider.overrideWithValue(files)],
          child: MaterialApp(
            locale: Locale(lang),
            supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
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
    final found = find.byKey(key);
    if (found.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        found,
        300,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 40,
      );
    }
    await tester.ensureVisible(found);
    await tester.pumpAndSettle();
    await tester.tap(found);
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final sample in [
    (375.0, 'zh', 1.8, 300.0),
    (375.0, 'en', 1.8, 300.0),
    (768.0, 'en', 1.8, 0.0),
    (1440.0, 'ja', 1.8, 0.0),
  ]) {
    testWidgets(
      'history layout and search ${sample.$1}/${sample.$2} ${(sample.$4)} keyboard',
      (tester) async {
        await host(
          tester,
          RoutineDatesPanel(planId: 'daily', now: now),
          width: sample.$1,
          lang: sample.$2,
          scale: sample.$3,
          keyboard: sample.$4,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('routine-dates-query')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('routine-dates-query')),
          '2030-01-08',
        );
        await settle(tester);
        await tester.ensureVisible(
          find.byKey(const ValueKey('routine-date:daily:ordinary:2030-01-08')),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }
  testWidgets(
    'historical completion requires confirmation and changes only one SQL row',
    (tester) async {
      await host(tester, RoutineDatesPanel(planId: 'daily', now: now));
      final sibling = await tester.runAsync(
        () => h.row('daily:ordinary:2030-01-09'),
      );
      await tap(
        tester,
        const ValueKey('routine-date-complete:daily:ordinary:2030-01-10'),
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(tester);
      expect(
        (await tester.runAsync(
          () => h.row('daily:ordinary:2030-01-10'),
        ))!.isCompleted,
        false,
      );
      await tap(
        tester,
        const ValueKey('routine-date-complete:daily:ordinary:2030-01-10'),
      );
      await tap(tester, const ValueKey('routine-date-confirm'));
      final saved = await tester.runAsync(
        () => h.row('daily:ordinary:2030-01-10'),
      );
      expect(saved!.isCompleted, true);
      expect(saved.details.completedAt, now);
      expect(
        (await tester.runAsync(() => h.row(sibling!.id)))!.toJson(),
        sibling!.toJson(),
      );
      await finish(tester);
    },
  );
  testWidgets('source plan link exposes dates and ordinary edit controls', (
    tester,
  ) async {
    await host(tester, const TaskManagementPanel(initialPlanId: 'daily'));
    expect(find.text('Fixture daily'), findsOneWidget);
    await tap(tester, const ValueKey('routine-dates:daily'));
    expect(find.byType(RoutineDatesPanel), findsOneWidget);
    await finish(tester);
  });
  testWidgets(
    'file update is previewed and cancelled without losing current years',
    (tester) async {
      var policy = HolidayPolicy(
        mode: 'skip_holidays',
        calendar: HolidayCalendar.mainland2026,
      );
      files.incoming = HolidayCalendar.fromJson({
        ...HolidayCalendar.mainland2026.toJson(),
        'id': 'synthetic-2027',
        'from': '2027-01-01',
        'to': '2027-12-31',
        'source': 'https://example.test/fixture-2027',
        'holidays': <String>[],
        'workdays': <String>[],
      });
      await host(
        tester,
        StatefulBuilder(
          builder: (c, set) => SingleChildScrollView(
            child: HolidayPolicyEditor(
              value: policy,
              onChanged: (value) => set(() => policy = value),
            ),
          ),
        ),
      );
      await tap(tester, const ValueKey('calendar-import-file'));
      expect(
        find.byKey(const ValueKey('calendar-apply-update')),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(tester);
      expect(policy.calendar!.snapshots, hasLength(1));
      await tap(tester, const ValueKey('calendar-import-file'));
      await tap(tester, const ValueKey('calendar-apply-update'));
      expect(policy.calendar!.snapshots, hasLength(2));
      expect(policy.calendar!.snapshots.first.id, 'CN-2026-20251104');
      await finish(tester);
    },
  );
  testWidgets(
    'a late picker response cannot change a retired editing session',
    (tester) async {
      var policy = HolidayPolicy(
            mode: 'skip_holidays',
            calendar: HolidayCalendar.mainland2026,
          ),
          active = true;
      files.pending = Completer<HolidayCalendar?>();
      await host(
        tester,
        SingleChildScrollView(
          child: HolidayPolicyEditor(
            value: policy,
            isCurrent: () => active,
            onChanged: (value) => policy = value,
          ),
        ),
      );
      await tap(tester, const ValueKey('calendar-import-file'));
      active = false;
      files.pending!.complete(HolidayCalendar.mainland2026);
      await settle(tester);
      expect(find.byKey(const ValueKey('calendar-apply-update')), findsNothing);
      expect(policy.calendar!.snapshots, hasLength(1));
      await finish(tester);
    },
  );
  testWidgets('history mounted while recovery is paused remains inert', (
    tester,
  ) async {
    final gate = h.container.read(runtimeRecoveryGateProvider);
    final token = await gate.pause();
    await host(tester, RoutineDatesPanel(planId: 'daily', now: now));
    expect(find.byKey(const ValueKey('routine-dates-query')), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
    gate.resume(token);
  });
}
