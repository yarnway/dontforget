import 'dart:async';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/recovery/runtime_gate.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/spaced_repetition_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _card = Reminder(
  id: 'review-fixture',
  taskTitle: 'Review fixture',
  quadrantLevel: 2,
  spacedRepetitionLevel: 1,
  nextReviewAt: DateTime(2020),
);

class _Rows implements DatabaseExecutor {
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async => [_card.toJson()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Supplies startup rows in memory; no database file is opened or written.
class _ReadDatabase extends DatabaseHelper {
  _ReadDatabase()
    : super.forTesting('/unused-memory-fixture', databaseFactoryFfi);

  @override
  Future<T> read<T>(
    DataGeneration generation,
    Future<T> Function(DatabaseExecutor) operation,
  ) => operation(_Rows());
}

class _ControlledReminders extends RemindersNotifier {
  _ControlledReminders(super.database) : super(runLoadEffects: false);
  final writes = <Completer<void>>[];

  @override
  Future<ReminderActionResult> updateReminder(
    Reminder task, {
    Reminder? baseline,
  }) async {
    final completion = Completer<void>();
    writes.add(completion);
    await completion.future;
    if (mounted) state = [task];
    return ReminderActionResult(
      ReminderActionDisposition.applied,
      reminder: task,
    );
  }
}

void main() {
  late ProviderContainer container;
  late _ControlledReminders reminders;
  late RuntimeRecoveryGate gate;
  final loc = AppLocalizations(const Locale('zh'));

  setUp(() async {
    final database = _ReadDatabase();
    gate = RuntimeRecoveryGate();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        runtimeRecoveryGateProvider.overrideWithValue(gate),
        remindersProvider.overrideWith(
          (ref) => reminders = _ControlledReminders(database),
        ),
      ],
    );
    await container.read(remindersProvider.notifier).ready;
  });

  tearDown(() => container.dispose());

  Future<void> showSheet(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (_, child) => InlineFeedback(child: child!),
          home: const Scaffold(body: Center(child: SpacedRepetitionSheet())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder remembered() =>
      find.widgetWithText(ElevatedButton, loc.get('markRemembered'));
  Finder difficult() =>
      find.widgetWithText(OutlinedButton, loc.get('markDifficult'));

  testWidgets(
    'review waits for persistence and disables duplicate submissions',
    (tester) async {
      await showSheet(tester);
      final staleCallback = tester
          .widget<ElevatedButton>(remembered())
          .onPressed!;
      await tester.tap(remembered());
      await tester.pump();
      expect(reminders.writes, hasLength(1));
      expect(tester.widget<ElevatedButton>(remembered()).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(difficult()).onPressed, isNull);
      staleCallback();
      await tester.pump();
      expect(reminders.writes, hasLength(1));
      expect(reminders.state.single.spacedRepetitionLevel, 1);
      expect(find.text('Review fixture'), findsOneWidget);
      expect(find.textContaining('已晋级到第'), findsNothing);
      reminders.writes.single.complete();
      await tester.pumpAndSettle();
      expect(reminders.state.single.spacedRepetitionLevel, 2);
      expect(find.textContaining('已晋级到第 2'), findsOneWidget);
      expect(find.text('Review fixture'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed persistence keeps the card and allows a deliberate retry',
    (tester) async {
      await showSheet(tester);
      await tester.tap(remembered());
      await tester.pump();
      reminders.writes.single.completeError(
        const DatabaseAccessException(DatabaseAccessError.staleGeneration),
      );
      await tester.pumpAndSettle();
      expect(reminders.state.single.spacedRepetitionLevel, 1);
      expect(find.text('Review fixture'), findsOneWidget);
      expect(find.text(loc.get('reminderUpdateFailed')), findsOneWidget);
      expect(find.textContaining('已晋级到第'), findsNothing);
      expect(tester.widget<ElevatedButton>(remembered()).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.tap(remembered());
      await tester.pump();
      expect(reminders.writes, hasLength(2));
      reminders.writes.last.complete();
      await tester.pumpAndSettle();
      expect(reminders.state.single.spacedRepetitionLevel, 2);
    },
  );

  testWidgets(
    'old runtime callbacks and late failures cannot announce or resubmit reviews',
    (tester) async {
      await showSheet(tester);
      final oldCallback = tester
          .widget<ElevatedButton>(remembered())
          .onPressed!;
      await tester.tap(remembered());
      await tester.pump();
      final token = await gate.pause();
      gate.resume(token);
      reminders.writes.single.completeError(
        const DatabaseAccessException(DatabaseAccessError.staleGeneration),
      );
      await tester.pumpAndSettle();
      oldCallback();
      await tester.pumpAndSettle();
      expect(reminders.writes, hasLength(1));
      expect(find.text(loc.get('reminderUpdateFailed')), findsNothing);
      expect(find.textContaining('已晋级到第'), findsNothing);
      expect(reminders.state.single.spacedRepetitionLevel, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposed review page observes a late failure without UI callbacks',
    (tester) async {
      await showSheet(tester);
      await tester.tap(difficult());
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      reminders.writes.single.completeError(
        StateError('Synthetic storage failure'),
      );
      await tester.pumpAndSettle();
      expect(reminders.state.single.spacedRepetitionLevel, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
