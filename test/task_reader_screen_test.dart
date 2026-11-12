import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/editor_keyboard_actions.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/task_details_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'support/real_io.dart';

void main() {
  late OfflineManagementHarness h;
  late Reminder task;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    task = Reminder(
      id: 'reader',
      taskTitle: '查看测试 alpha',
      taskSummary: '第一行\n第二行 beta',
      quadrantLevel: 2,
      triggerTime: DateTime(2030, 1, 8, 8),
      eventTime: DateTime(2030, 1, 8, 9),
      detailsJson: const TaskDetails(
        project: '项目',
        tags: ['标签'],
        checklist: [ChecklistItem('one', '确认清单')],
      ).encode(),
    );
    await h.seed(task);
    h.notifications.cancelled.clear();
    h.notifications.scheduled.clear();
  });
  tearDown(() => h.dispose());
  Future<String> saved() async => jsonEncode(
    await h.database.read(
      h.database.captureGeneration(),
      (db) async => {
        for (final table in ['Reminders', 'MediaRecords', 'Settings'])
          table: await db.query(table, orderBy: 'id'),
      },
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    bool dialog = false,
    String locale = 'zh',
    double width = 390,
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
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
          theme: dark ? AppTheme.dark : AppTheme.light,
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: InlineFeedback(child: child!),
          ),
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  c,
                  MaterialPageRoute<void>(
                    builder: (_) => dialog
                        ? TaskDetailsDialog(task: task)
                        : TaskDetailScreen(task: task),
                  ),
                ),
                child: const Text('Open reader'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open reader'));
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('task-detail-modify')));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  for (final dialog in [false, true]) {
    testWidgets(
      '${dialog ? 'compatibility' : 'ordinary'} details are read-only including keyboard save',
      (tester) async {
        final before = await tester.runAsync(saved);
        await open(tester, dialog: dialog);
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
        expect(find.byType(EditorKeyboardActions), findsNothing);
        expect(find.byKey(const ValueKey('detail-save')), findsNothing);
        expect(find.text('修改'), findsOneWidget);
        expect(tester.testTextInput.isVisible, false);
        await tester.tap(find.byKey(const ValueKey('task-detail-read-title')));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, false);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(await tester.runAsync(saved), before);
        expect(h.notifications.cancelled, isEmpty);
        expect(h.notifications.scheduled, isEmpty);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'Edit opens the latest saved values and Save returns to the updated reader',
    (tester) async {
      await open(tester);
      await tester.runAsync(() async {
        final old = await h.row(task.id);
        await h.notifier.updateReminder(
          old.copyWith(taskTitle: '最新标题', taskSummary: '外部更新摘要'),
          baseline: old,
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('最新标题'), findsOneWidget);
      await edit(tester);
      expect(find.byType(TaskEditScreen), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('detail-title')))
            .controller!
            .text,
        '最新标题',
      );
      await tester.enterText(
        find.byKey(const ValueKey('detail-title')),
        '修改后的标题',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('detail-save')));
      await tester.pump();
      await pumpUntilRealIo(
        tester,
        () => find.byType(TaskEditScreen).evaluate().isEmpty,
        reason: 'Save must commit and return to reader',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task-detail-reader')), findsOneWidget);
      expect(find.text('修改后的标题'), findsOneWidget);
      await tester.runAsync(() async {
        final stored = await h.row(task.id);
        expect(stored.taskSummary, '外部更新摘要');
        expect(
          jsonDecode(stored.detailsJson!)..remove('history'),
          jsonDecode(task.detailsJson!)..remove('history'),
        );
        expect(stored.details.history.map((e) => e.action), [
          'edited',
          'edited',
        ]);
        expect(stored.triggerTime, task.triggerTime);
      });
      await finish(tester);
    },
  );

  testWidgets('unchanged edit Save returns without writing or rescheduling', (
    tester,
  ) async {
    final before = await tester.runAsync(saved);
    await open(tester);
    await edit(tester);
    await tester.tap(find.byKey(const ValueKey('detail-save')));
    await tester.pumpAndSettle();
    expect(find.byType(TaskEditScreen), findsNothing);
    expect(find.byKey(const ValueKey('task-detail-reader')), findsOneWidget);
    expect(await tester.runAsync(saved), before);
    expect(h.notifications.cancelled, isEmpty);
    expect(h.notifications.scheduled, isEmpty);
    await finish(tester);
  });

  testWidgets(
    'dirty Back keeps the draft or discards it without changing the stored task',
    (tester) async {
      final before = await tester.runAsync(saved);
      await open(tester);
      await edit(tester);
      await tester.enterText(
        find.byKey(const ValueKey('detail-title')),
        '未保存修改',
      );
      await tester.tap(find.byKey(const ValueKey('detail-editor-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('未保存修改'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('detail-editor-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskEditScreen), findsNothing);
      expect(await tester.runAsync(saved), before);
      await finish(tester);
    },
  );

  testWidgets(
    'attachments and checklist are visible without add, remove or toggle controls',
    (tester) async {
      final file = (await tester.runAsync(() async {
        final file = await File(
          '${h.directory.path}/original.txt',
        ).writeAsString('original');
        await h.database.writeTransaction(h.database.captureGeneration(), (
          db,
        ) async {
          await db.insert(
            'MediaRecords',
            MediaRecord(
              id: 'original',
              type: 'file',
              contentOrPath: file.path,
              createdAt: DateTime(2026, 11, 1),
            ).toJson(),
          );
        });
        final attached = task.copyWith(recordId: 'original');
        await h.notifier.updateReminder(attached, baseline: task);
        task = await h.row(task.id);
        return file;
      }))!;
      final before = await tester.runAsync(saved);
      await open(tester);
      final attachment = find.byKey(const ValueKey('task-attachments'));
      await tester.scrollUntilVisible(
        attachment,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('task-detail-reader-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await pumpUntilRealIo(
        tester,
        () => find
            .byKey(const ValueKey('attachment-original'))
            .evaluate()
            .isNotEmpty,
        reason: 'Original media should be read',
      );
      expect(find.byKey(const ValueKey('attach-file')), findsNothing);
      expect(find.byKey(const ValueKey('attach-photo')), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(await tester.runAsync(saved), before);
      expect(await tester.runAsync(file.readAsString), 'original');
      await finish(tester);
    },
  );

  testWidgets(
    'a recovery generation change cannot open an editor from the old reader',
    (tester) async {
      await open(tester);
      await tester.runAsync(
        () async => (await h.database.beginMaintenance()).resume(),
      );
      await tester.tap(find.byKey(const ValueKey('task-detail-modify')));
      await tester.pumpAndSettle();
      expect(find.byType(TaskEditScreen), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'linked navigation opens another reader without changing either task',
    (tester) async {
      await tester.runAsync(() async {
        await h.seed(
          Reminder(id: 'linked', taskTitle: '关联事项', quadrantLevel: 3),
        );
        await h.notifier.linkTwoTasks(task.id, 'linked');
      });
      final before = await tester.runAsync(saved);
      await open(tester);
      final link = find.byKey(const ValueKey('reader-linked-linked'));
      await tester.scrollUntilVisible(
        link,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('task-detail-reader-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TaskDetailScreen>(find.byType(TaskDetailScreen)).task.id,
        'linked',
      );
      expect(find.byType(TaskEditScreen), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(await tester.runAsync(saved), before);
      await finish(tester);
    },
  );

  testWidgets(
    'an externally deleted task stays readable and cannot be recreated by Edit',
    (tester) async {
      await open(tester);
      await tester.runAsync(() => h.notifier.deleteReminder(task.id));
      await tester.pumpAndSettle();
      final before = await tester.runAsync(saved);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('task-detail-modify')),
      );
      expect(button.onPressed, isNull);
      expect(find.byType(TextField), findsNothing);
      expect(await tester.runAsync(saved), before);
      await finish(tester);
    },
  );

  testWidgets(
    'reader cards and Edit stay aligned within landscape safe insets',
    (tester) async {
      tester.view.padding = const FakeViewPadding(left: 24, right: 16);
      addTearDown(tester.view.resetPadding);
      await open(tester, width: 375, scale: 2);
      final card = tester.getRect(find.byType(Card).first);
      final edit = tester.getRect(
        find.byKey(const ValueKey('task-detail-modify')),
      );
      expect(card.left, greaterThanOrEqualTo(40));
      expect(card.right, lessThanOrEqualTo(343));
      expect(card.left, closeTo(edit.left, 1));
      expect(card.width, closeTo(edit.width, 1));
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'yearly schedules and all saved profile values remain readable and editable',
    (tester) async {
      await tester.runAsync(() async {
        final edited = task.copyWith(
          isRecurring: true,
          recurrenceRule: 'yearly',
          contextTrigger: '{"type":"profile","value":"general"}',
        );
        await h.notifier.updateReminder(edited, baseline: task);
        task = await h.row(task.id);
      });
      final before = await tester.runAsync(saved);
      await open(tester);
      expect(find.text('每年重复'), findsOneWidget);
      await edit(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('detail-save')));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(saved), before);
      await finish(tester);
    },
  );

  for (final language in ['zh', 'en', 'ja']) {
    for (final width in [375.0, 1280.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          '$language reader and editor fit $width at 200%, dark=$dark',
          (tester) async {
            await open(
              tester,
              locale: language,
              width: width,
              scale: 2,
              dark: dark,
            );
            expect(tester.takeException(), isNull);
            await edit(tester);
            expect(find.byType(TaskEditScreen), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(find.byKey(const ValueKey('detail-editor-back')));
            await tester.pumpAndSettle();
            expect(find.byType(TaskEditScreen), findsNothing);
            await finish(tester);
          },
        );
      }
    }
  }
}
