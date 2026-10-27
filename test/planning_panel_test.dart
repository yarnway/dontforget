import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/models/medication_plan.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/widgets/planning_panel.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/workspace_drafts.dart';

class _Notifications implements NotificationService {
  @override
  Future<void> scheduleReminderStrict(Reminder task) async {}
  @override
  Future<void> cancelReminderStrict(String id) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'dontforget-planning-ui-',
    );
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    final notifications = _Notifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        routineScheduleStatusReaderProvider.overrideWith(
          (ref) =>
              (planId) async => NotificationScheduleStatus.fromSaved(
                ref.read(remindersProvider),
                {},
                DateTime.now(),
                nativePendingLimit: 50,
                planId: planId,
              ),
        ),
        notificationServiceProvider.overrideWithValue(notifications),
        remindersProvider.overrideWith(
          (_) => RemindersNotifier(
            database,
            notifications: notifications,
            runLoadEffects: false,
          ),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    await container.read(mediaRecordsProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
  });
  tearDown(() async {
    container.dispose();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
  });
  Future<void> pump(
    WidgetTester tester, {
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
        container: container,
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
          home: Scaffold(body: PlanningPanel(onClose: () {})),
        ),
      ),
    );
    for (var tick = 0; tick < 100; tick++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, container);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final locale in ['zh', 'en', 'ja']) {
      testWidgets('planning tabs fit $width $locale large text', (
        tester,
      ) async {
        await pump(tester, width: width, locale: locale, scale: 1.8);
        for (var i = 0; i < 5; i++) {
          final chips = find.byType(ChoiceChip);
          await tester.tap(chips.at(i));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        await finish(tester);
      });
    }
  }
  testWidgets('confirmed medication preview commits one finite course', (
    tester,
  ) async {
    final day = DateTime.now().add(const Duration(days: 2));
    final plan = MedicationPlan(
      id: 'ui-course',
      title: 'UI fixture course',
      start: DateTime(day.year, day.month, day.day),
      end: DateTime(day.year, day.month, day.day + 1),
      medicines: [
        Medicine(
          id: 'ui-med',
          name: 'Fixture medicine',
          strength: 'Fixture form',
          amount: '1',
          unit: 'Fixture unit',
          meal: 'Confirmed instruction',
          times: ['07:30', '19:30'],
        ),
      ],
    );
    await tester.runAsync(
      () => container
          .read(workspaceDraftsProvider.notifier)
          .put('medicationDraft', plan.toJson()),
    );
    await pump(tester);
    final preview = find.text('预览');
    await tester.scrollUntilVisible(
      preview,
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(preview);
    await tester.pump();
    final confirm = find.text('已逐药核对用量、时刻和疗程');
    await tester.scrollUntilVisible(
      confirm,
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(confirm);
    await tester.pump();
    final activate = find.text('确认并启用');
    await tester.scrollUntilVisible(
      activate,
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(activate);
    await tester.pump();
    for (var i = 0; i < 150; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
      if (container.read(remindersProvider).length == 5 &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    expect(container.read(remindersProvider).length, 5);
    expect(
      container
          .read(remindersProvider)
          .where((r) => r.details.kind == 'medication')
          .length,
      4,
    );
    expect(
      container.read(remindersProvider).every((r) => !r.isCompleted),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets('invalid departure input does not crash or activate a plan', (
    tester,
  ) async {
    await tester.runAsync(
      () => container
          .read(workspaceDraftsProvider.notifier)
          .put('departureDraft', DeparturePlan(id: 'ui-departure').toJson()),
    );
    await pump(tester);
    await tester.tap(find.byType(ChoiceChip).at(1));
    await tester.pump();
    final input = find.byKey(const ValueKey('ui-departure:lead'));
    await tester.scrollUntilVisible(
      input,
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(input, '-1');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(container.read(remindersProvider), isEmpty);
    await finish(tester);
  });
  testWidgets('malformed saved editor data has a safe blank fallback', (
    tester,
  ) async {
    await tester.runAsync(
      () => container.read(workspaceDraftsProvider.notifier).put(
        'medicationDraft',
        {'id': 'bad', 'medicines': null},
      ),
    );
    await tester.runAsync(
      () => container.read(workspaceDraftsProvider.notifier).put(
        'departureDraft',
        {'id': false},
      ),
    );
    await pump(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(ChoiceChip).at(1));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
