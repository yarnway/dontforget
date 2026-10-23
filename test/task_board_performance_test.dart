import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/dynamic_urgency_service.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/quadrant_view.dart';
import 'package:dont_forget/ui/widgets/task_board.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ControlledReminders extends RemindersNotifier {
  _ControlledReminders(super.database, this.saved);
  final Completer<void> saved;
  Reminder? requested;

  @override
  Future<ReminderActionResult> updateReminder(
    Reminder reminder, {
    Reminder? baseline,
  }) async {
    requested = reminder;
    await saved.future;
    state = [
      for (final old in state)
        if (old.id == reminder.id) reminder else old,
    ];
    return ReminderActionResult(
      ReminderActionDisposition.applied,
      reminder: reminder,
    );
  }
}

class _CountingUrgency extends DynamicUrgencyService {
  int checks = 0;
  final referenceTimes = <DateTime?>{};

  @override
  bool isQ4StagnantFolded(
    Reminder reminder, {
    int thresholdHours = 48,
    DateTime? now,
  }) {
    checks++;
    referenceTimes.add(now);
    return super.isQ4StagnantFolded(
      reminder,
      thresholdHours: thresholdHours,
      now: now,
    );
  }
}

Reminder task(
  String id, {
  int level = 1,
  bool done = false,
  bool old = false,
}) => Reminder(
  id: id,
  taskTitle: 'Task $id',
  quadrantLevel: level,
  isCompleted: done,
  createdAt: DateTime.now().subtract(Duration(hours: old ? 72 : 0)),
);

Widget app(Widget board, {double scale = 1}) => MaterialApp(
  localizationsDelegates: const [AppLocalizationsDelegate()],
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: InlineFeedback(child: child!),
  ),
  home: Scaffold(body: board),
);

void viewport(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('all wide-board memo rows use one projection time', (
    tester,
  ) async {
    viewport(tester, 768);
    final urgency = _CountingUrgency();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dynamicUrgencyServiceProvider.overrideWithValue(urgency)],
        child: app(
          TaskBoard(
            reminders: List.generate(
              10000,
              (i) => task('$i', level: i % 4 + 1),
            ),
            onPlayMedia: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(QuadrantView), findsNWidgets(4));
    expect(urgency.checks, 2500);
    expect(urgency.referenceTimes, hasLength(1));
    expect(urgency.referenceTimes.single, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('5000 tasks build only the visible cards and scroll cache', (
    tester,
  ) async {
    viewport(tester, 375);
    await tester.pumpWidget(
      ProviderScope(
        child: app(
          TaskBoard(
            reminders: List.generate(5000, (i) => task('$i')),
            onPlayMedia: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(TaskCard).evaluate().length, inInclusiveRange(1, 30));
    expect(find.byKey(const ValueKey('task-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-4999')), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.byType(TaskCard).evaluate().length, inInclusiveRange(1, 30));
    expect(find.byKey(const ValueKey('task-0')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('task identity survives a newly inserted first row', (
    tester,
  ) async {
    viewport(tester, 375);
    final items = ValueNotifier([task('first'), task('second')]);
    addTearDown(items.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: app(
          ValueListenableBuilder(
            valueListenable: items,
            builder: (_, value, _) =>
                TaskBoard(reminders: value, onPlayMedia: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump();
    final card = find.byWidgetPredicate(
      (widget) => widget is TaskCard && widget.task.id == 'first',
    );
    final previousState = tester.state(card);
    items.value = [task('inserted'), ...items.value];
    await tester.pump();
    expect(tester.state(card), same(previousState));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'completed and stagnant sections remain folded and expand lazily',
    (tester) async {
      viewport(tester, 375);
      await tester.pumpWidget(
        ProviderScope(
          child: app(
            TaskBoard(
              reminders: [
                ...List.generate(
                  1000,
                  (i) => task('done-$i', level: 4, done: true),
                ),
                ...List.generate(
                  1000,
                  (i) => task('old-$i', level: 4, old: true),
                ),
              ],
              onPlayMedia: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('category-4')));
      await tester.pump();
      expect(find.byType(TaskCard), findsNothing);
      await tester.tap(find.byKey(const ValueKey('folded-4')));
      await tester.pump();
      expect(find.byType(TaskCard).evaluate().length, inInclusiveRange(1, 30));
      expect(find.byKey(const ValueKey('task-old-999')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('folded-4')));
      await tester.pump();
      expect(find.byType(TaskCard), findsNothing);
      await tester.tap(find.byKey(const ValueKey('completed-4')));
      await tester.pump();
      expect(find.byType(TaskCard).evaluate().length, inInclusiveRange(1, 30));
      expect(find.byKey(const ValueKey('task-done-999')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'phone categories support keyboard selection and fill available height',
    (tester) async {
      viewport(tester, 375);
      await tester.pumpWidget(
        ProviderScope(
          child: app(
            TaskBoard(
              reminders: [task('urgent'), task('focus', level: 2)],
              onPlayMedia: (_) {},
            ),
            scale: 1.5,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(QuadrantView), findsOneWidget);
      expect(
        tester.getSize(find.byType(QuadrantView)).height,
        greaterThan(400),
      );
      await tester.tap(find.byKey(const ValueKey('category-2')));
      await tester.pump();
      expect(find.byKey(const ValueKey('task-focus')), findsOneWidget);
      expect(find.byKey(const ValueKey('task-urgent')), findsNothing);
      tester
          .widget<TextButton>(find.byKey(const ValueKey('category-2')))
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.byKey(const ValueKey('quadrant-4')), findsOneWidget);
      expect(find.text('No memos or notes'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('category-4')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'layout switches at 640 and all quadrants fit tablet and desktop',
    (tester) async {
      viewport(tester, 639);
      for (final width in [639.0, 640.0, 768.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(
          ProviderScope(
            child: app(
              TaskBoard(
                reminders: List.generate(
                  4,
                  (i) => task('responsive-$i', level: i + 1),
                ),
                onPlayMedia: (_) {},
              ),
              scale: 1.5,
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(QuadrantView), findsNWidgets(width < 640 ? 1 : 4));
        expect(
          find.byKey(const ValueKey('category-1')),
          width < 640 ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull, reason: 'width $width');
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('short phone viewport retains a usable category picker', (
    tester,
  ) async {
    viewport(tester, 375);
    await tester.pumpWidget(
      ProviderScope(
        child: app(
          SizedBox(
            height: 240,
            child: TaskBoard(reminders: [task('short')], onPlayMedia: (_) {}),
          ),
          scale: 1.5,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('short-category-picker')), findsOneWidget);
    final first = tester.widget<TextButton>(
      find.byKey(const ValueKey('category-1')),
    );
    first.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('category-4')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('No memos or notes'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('time-sensitive board refreshes per minute and on resume', (
    tester,
  ) async {
    viewport(tester, 375);
    final urgency = _CountingUrgency();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dynamicUrgencyServiceProvider.overrideWithValue(urgency)],
        child: app(
          TaskBoard(reminders: [task('memo', level: 4)], onPlayMedia: (_) {}),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('category-4')));
    await tester.pump();
    final before = urgency.checks;
    await tester.pump(const Duration(seconds: 59));
    expect(urgency.checks, before);
    await tester.pump(const Duration(seconds: 1));
    expect(urgency.checks, before + 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 2));
    expect(urgency.checks, before + 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(urgency.checks, before + 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fails in [false, true]) {
    testWidgets(
      'drag feedback waits for ${fails ? 'failed' : 'successful'} persistence',
      (tester) async {
        viewport(tester, 1440);
        sqfliteFfiInit();
        final directory = Directory.systemTemp.createTempSync('board-move-');
        final database = DatabaseHelper.forTesting(
          directory.path,
          databaseFactoryFfi,
        );
        late _ControlledReminders notifier;
        final saved = Completer<void>();
        await tester.runAsync(() async {
          final db = await database.database;
          await db.insert('Reminders', task('move').toJson());
          notifier = _ControlledReminders(database, saved);
          await notifier.ready;
        });
        final container = ProviderContainer(
          overrides: [remindersProvider.overrideWith((_) => notifier)],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
          await directory.delete(recursive: true);
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: app(
              Consumer(
                builder: (_, ref, _) => TaskBoard(
                  reminders: ref.watch(remindersProvider),
                  onPlayMedia: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Task move')),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(
          tester.getCenter(find.byKey(const ValueKey('quadrant-2'))),
        );
        await tester.pump();
        await gesture.up();
        await tester.pump();
        expect(notifier.requested?.quadrantLevel, 2);
        expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
        expect(container.read(remindersProvider).single.quadrantLevel, 1);
        if (fails) {
          notifier.saved.completeError(StateError('synthetic save failure'));
        } else {
          notifier.saved.complete();
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('inline-feedback')), findsOneWidget);
        expect(
          container.read(remindersProvider).single.quadrantLevel,
          fails ? 1 : 2,
        );
        expect(
          find.text(
            fails
                ? 'Could not update this reminder. Please try again.'
                : 'Moved to: Key Focus: Task move',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
