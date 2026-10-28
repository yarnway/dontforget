import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:dont_forget/ui/widgets/task_metadata_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  @override
  Future<void> cancelReminderStrict(String id) async {}
  @override
  Future<void> scheduleReminderStrict(Reminder reminder) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tasks extends RemindersNotifier {
  bool failNextUpdate = false;
  _Tasks(super.database)
    : super(notifications: _Notifications(), runLoadEffects: false);

  @override
  Future<ReminderActionResult> updateReminder(
    Reminder reminder, {
    Reminder? baseline,
  }) {
    if (failNextUpdate) {
      failNextUpdate = false;
      return Future.error(StateError('Synthetic field write failure'));
    }
    return super.updateReminder(reminder, baseline: baseline);
  }
}

void main() {
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Tasks tasks;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('task-consistency-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    tasks = _Tasks(database);
    await tasks.ready;
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        remindersProvider.overrideWith((ref) => tasks),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  Reminder sample({String kind = 'task'}) => Reminder(
    id: 'metadata',
    taskTitle:
        'A very long task title that keeps its completion button available 任務標題 ' *
        3,
    quadrantLevel: 1,
    subTasks: '["Legacy habit"]',
    detailsJson: TaskDetails(
      kind: kind,
      project: 'Release project',
      tags: const ['one', 'two', 'three', 'four', 'five'],
      checklist: const [
        ChecklistItem('first', 'First item', done: true),
        ChecklistItem('second', 'Second item'),
      ],
    ).encode(),
  );

  Future<void> host(
    WidgetTester tester,
    Widget child, {
    String language = 'en',
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
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
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final language in ['en', 'zh', 'ja']) {
    testWidgets(
      'card project tags checklist and legacy content fit narrow large text ($language)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await host(
          tester,
          Scaffold(
            body: SingleChildScrollView(
              child: TaskCard(task: sample(), onPlayMedia: () {}),
            ),
          ),
          language: language,
          scale: 2,
        );
        expect(find.textContaining('Release project'), findsOneWidget);
        expect(find.text('one'), findsOneWidget);
        expect(find.text('three'), findsOneWidget);
        expect(find.text('four'), findsNothing);
        expect(find.text('+2'), findsOneWidget);
        expect(find.textContaining('1/2'), findsOneWidget);
        expect(find.text('Legacy habit'), findsNothing);
        final legacySteps = find.byKey(const ValueKey('subtasks-metadata'));
        await tester.ensureVisible(legacySteps);
        await tester.tap(legacySteps);
        await tester.pumpAndSettle();
        expect(find.text('Legacy habit'), findsOneWidget);
        final l10n = AppLocalizations.of(tester.element(find.byType(TaskCard)));
        expect(
          find.textContaining(l10n.get('taskMicroHabits')),
          findsOneWidget,
        );
        final expand = find.byKey(const ValueKey('checklist-metadata'));
        await tester.ensureVisible(expand);
        await tester.tap(expand);
        await tester.pumpAndSettle();
        expect(find.text('First item'), findsOneWidget);
        expect(find.text('Second item'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'card checkbox persists through setChecklistItem without changing legacy habits',
    (tester) async {
      final task = sample();
      await tester.runAsync(() => tasks.addReminder(task));
      await host(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: Consumer(
              builder: (context, ref, child) => TaskCard(
                task: ref.watch(remindersProvider).single,
                onPlayMedia: () {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('checklist-metadata')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final tile = tester.widget<CheckboxListTile>(
          find.byKey(const ValueKey('checklist-item-metadata-second')),
        );
        tile.onChanged!(true);
        await tasks.updateReminder(
          tasks.state.single,
          baseline: tasks.state.single,
        );
      });
      await tester.pumpAndSettle();
      final stored = (await tester.runAsync(
        () async => Reminder.fromJson(
          (await (await database.database).query('Reminders')).single,
        ),
      ))!;
      expect(stored.details.checklist.every((e) => e.done), isTrue);
      expect(stored.subTasks, task.subTasks);
      expect(stored.details.project, task.details.project);
      expect(find.textContaining('2/2'), findsOneWidget);
    },
  );

  testWidgets(
    'legacy-only card uses read-only micro habits and specialized checklist is read-only',
    (tester) async {
      final legacy = Reminder(
        id: 'legacy',
        taskTitle: 'Old task',
        quadrantLevel: 1,
        subTasks: '["Old habit"]',
      );
      await host(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                TaskCard(task: legacy, onPlayMedia: () {}),
                TaskCard(
                  task: sample(kind: 'departure'),
                  onPlayMedia: () {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Micro habits (1)'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('checklist-legacy')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('checklist-metadata')));
      await tester.pumpAndSettle();
      final tile = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('checklist-item-metadata-second')),
      );
      expect(tile.onChanged, isNull);
      expect(find.text('Old habit'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('subtasks-legacy')));
      await tester.tap(find.byKey(const ValueKey('subtasks-legacy')));
      await tester.pumpAndSettle();
      expect(find.text('Old habit'), findsOneWidget);
    },
  );

  testWidgets(
    'detail metadata draft participates in unsaved guard and persists with other edits',
    (tester) async {
      final task = sample();
      await tester.runAsync(() => tasks.addReminder(task));
      await host(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TaskDetailScreen(task: task),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final project = find.byKey(const ValueKey('detail-project'));
      await tester.ensureVisible(project);
      await tester.enterText(project, 'New project');
      await tester.pump();
      await tester.tap(find.byTooltip('Cancel').first);
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      final tag = find.byKey(const ValueKey('detail-new-tag'));
      await tester.ensureVisible(tag);
      await tester.enterText(tag, 'six');
      await tester.tap(find.byKey(const ValueKey('detail-add-tag')));
      await tester.pumpAndSettle();
      final firstUp = find.byKey(const ValueKey('detail-item-up-second'));
      await tester.ensureVisible(firstUp);
      await tester.tap(firstUp);
      await tester.pumpAndSettle();
      final done = find.byKey(const ValueKey('detail-item-done-second'));
      await tester.ensureVisible(done);
      await tester.tap(done);
      final title = find.byKey(const ValueKey('detail-title'));
      await tester.ensureVisible(title);
      await tester.enterText(title, 'Edited title');
      final save = tester.widget<FilledButton>(
        find.widgetWithIcon(FilledButton, Icons.save_outlined),
      );
      await tester.runAsync(
        () async => await (save.onPressed! as Future<void> Function())(),
      );
      await tester.pumpAndSettle();
      final stored = (await tester.runAsync(
        () async => Reminder.fromJson(
          (await (await database.database).query('Reminders')).single,
        ),
      ))!;
      expect(stored.taskTitle, 'Edited title');
      expect(stored.details.project, 'New project');
      expect(stored.details.tags.last, 'six');
      expect(stored.details.checklist.first.id, 'second');
      expect(stored.details.checklist.first.done, isTrue);
      expect(stored.subTasks, task.subTasks);
      expect(find.byType(TaskDetailScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'card from an earlier recovery session cannot change the new session',
    (tester) async {
      final task = sample();
      await tester.runAsync(() => tasks.addReminder(task));
      await host(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: TaskCard(task: task, onPlayMedia: () {}),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('checklist-metadata')));
      await tester.pumpAndSettle();
      final gate = container.read(runtimeRecoveryGateProvider);
      final paused = await gate.pause();
      gate.resume(paused);
      final tile = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('checklist-item-metadata-second')),
      );
      tile.onChanged!(true);
      await tester.pumpAndSettle();
      final stored = (await tester.runAsync(
        () async => Reminder.fromJson(
          (await (await database.database).query('Reminders')).single,
        ),
      ))!;
      expect(stored.details.checklist.last.done, isFalse);
      expect(stored.detailsJson, task.detailsJson);
    },
  );

  testWidgets(
    'detail retry preserves a metadata write when the later field write fails',
    (tester) async {
      final task = sample();
      await tester.runAsync(() => tasks.addReminder(task));
      await host(tester, TaskDetailScreen(task: task));
      final title = find.byKey(const ValueKey('detail-title'));
      await tester.ensureVisible(title);
      await tester.enterText(title, 'Retry title');
      final project = find.byKey(const ValueKey('detail-project'));
      await tester.ensureVisible(project);
      await tester.enterText(project, 'Saved metadata');
      tasks.failNextUpdate = true;
      Future<void> save() async {
        final button = tester.widget<FilledButton>(
          find.widgetWithIcon(FilledButton, Icons.save_outlined),
        );
        await tester.runAsync(
          () async => await (button.onPressed! as Future<void> Function())(),
        );
        await tester.pumpAndSettle();
      }

      await save();
      var stored = (await tester.runAsync(
        () async => Reminder.fromJson(
          (await (await database.database).query('Reminders')).single,
        ),
      ))!;
      expect(stored.details.project, 'Saved metadata');
      expect(stored.taskTitle, task.taskTitle);
      expect(find.byType(TaskDetailScreen), findsOneWidget);
      await save();
      stored = (await tester.runAsync(
        () async => Reminder.fromJson(
          (await (await database.database).query('Reminders')).single,
        ),
      ))!;
      expect(stored.details.project, 'Saved metadata');
      expect(stored.taskTitle, 'Retry title');
      expect(stored.details.history.length, 2);
    },
  );

  testWidgets(
    'metadata editor adds and removes checklist entries and tags in its draft',
    (tester) async {
      var draft = const TaskDetails(tags: ['remove-me']);
      var valid = true;
      await host(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => TaskMetadataEditor(
                details: draft,
                onChanged: (value) => setState(() => draft = value),
                onValidityChanged: (value) => valid = value,
              ),
            ),
          ),
        ),
      );
      final project = find.byKey(const ValueKey('detail-project'));
      await tester.enterText(project, '😀' * 64);
      expect(draft.project.length, 128);
      await tester.enterText(project, '😀' * 65);
      expect(draft.project.length, 128);
      final chip = tester.widget<InputChip>(find.byType(InputChip));
      chip.onDeleted!();
      await tester.pumpAndSettle();
      expect(draft.tags, isEmpty);
      final add = find.byKey(const ValueKey('detail-new-checklist-item'));
      await tester.ensureVisible(add);
      await tester.enterText(add, 'New item');
      await tester.tap(find.byKey(const ValueKey('detail-add-checklist-item')));
      await tester.pumpAndSettle();
      final id = draft.checklist.single.id;
      expect(draft.checklist.single.label, 'New item');
      final label = find.byKey(ValueKey('detail-item-label-$id'));
      await tester.ensureVisible(label);
      await tester.enterText(label, '');
      expect(valid, isFalse);
      await tester.tap(find.byKey(ValueKey('detail-item-remove-$id')));
      await tester.pumpAndSettle();
      expect(draft.checklist, isEmpty);
      expect(valid, isTrue);
    },
  );

  testWidgets('specialized detail never exposes the generic checklist editor', (
    tester,
  ) async {
    await host(tester, TaskDetailScreen(task: sample(kind: 'study')));
    expect(find.byType(TaskMetadataEditor), findsNothing);
    expect(find.textContaining('1/2'), findsOneWidget);
    expect(
      find.text('This task’s checklist is managed in its dedicated panel.'),
      findsOneWidget,
    );
  });
}
