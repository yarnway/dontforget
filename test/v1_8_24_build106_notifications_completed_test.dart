import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/saved_task_filters_provider.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/quadrant_view.dart';
import 'package:dont_forget/ui/widgets/saved_task_filters_bar.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:dont_forget/ui/widgets/task_details_dialog.dart';
import 'package:dont_forget/ui/widgets/task_search_panel.dart';
import 'package:dont_forget/ui/widgets/task_workspace_overview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/real_io.dart';
import 'support/workspace_drafts.dart';

class _StubNotifications implements NotificationService {
  final scheduled = <Reminder>[];
  final canceled = <String>[];
  bool failNative = false;

  @override
  Future<void> scheduleReminder(Reminder task) async => scheduled.add(task);

  @override
  Future<void> cancelReminder(String id) async => canceled.add(id);

  @override
  Future<void> scheduleReminderStrict(Reminder task) async {
    await scheduleReminder(task);
    if (failNative) throw StateError('native schedule failed');
  }

  @override
  Future<void> cancelReminderStrict(String id) async {
    await cancelReminder(id);
    if (failNative) throw StateError('native cancel failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _StubNotifications notifications;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'dontforget-build106-ux-',
    );
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = _StubNotifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> mountHost(
    WidgetTester tester,
    Widget body, {
    String language = 'zh',
    double textScale = 1.0,
    bool accessibleNavigation = false,
    Size size = const Size(900, 800),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              accessibleNavigation: accessibleNavigation,
              textScaler: TextScaler.linear(textScale),
            ),
            child: InlineFeedback(child: child!),
          ),
          home: Scaffold(body: body),
        ),
      ),
    );
    await tester.pump();
  }

  Reminder completedReminder({
    required String id,
    required String title,
    required DateTime completedAt,
    int quadrant = 2,
    DateTime? deletedAt,
    bool learningArchive = false,
  }) {
    final details = TaskDetails(
      completedAt: completedAt,
      deletedAt: deletedAt,
      data: learningArchive ? const {'learning_archive': true} : const {},
    );
    return Reminder(
      id: id,
      taskTitle: title,
      quadrantLevel: quadrant,
      isCompleted: true,
      detailsJson: details.encode(),
      createdAt: completedAt.subtract(const Duration(hours: 2)),
    );
  }

  testWidgets(
    'completed TaskCard 1-tap delete exposes Undo and auto-closes after 5 seconds',
    (tester) async {
      final completedAt = DateTime(2026, 11, 25, 19, 30);
      final task = completedReminder(
        id: 'done-1',
        title: '整理季度复盘文档',
        completedAt: completedAt,
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).addReminder(task),
      );

      await mountHost(
        tester,
        Consumer(
          builder: (context, ref, _) {
            final item = ref
                .watch(remindersProvider)
                .where((r) => r.id == task.id && r.isWorkspaceItem)
                .firstOrNull;
            return item == null
                ? const SizedBox.shrink()
                : SingleChildScrollView(
                    child: TaskCard(task: item, onPlayMedia: () {}),
                  );
          },
        ),
        accessibleNavigation: true,
      );

      expect(find.textContaining('完成于:'), findsOneWidget);
      final deleteButton = find.byKey(const ValueKey('delete-done-1'));
      expect(deleteButton, findsOneWidget);
      expect(tester.getSize(deleteButton), const Size(48, 48));

      // Completed card menu hides AI habit breakdown clutter.
      await tester.tap(find.byKey(const ValueKey('actions-done-1')));
      await tester.pumpAndSettle();
      expect(find.text('5分钟微习惯拆解'), findsNothing);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();

      // 1-tap delete -> Undo within 5s restores the task.
      await tester.tap(deleteButton);
      await pumpUntilRealIo(
        tester,
        () => find.text('已删除事项: 整理季度复盘文档').evaluate().isNotEmpty,
        reason: 'delete feedback appears',
      );
      expect(find.byType(TaskCard), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('撤销'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await pumpUntilRealIo(
        tester,
        () => container
            .read(remindersProvider)
            .any((r) => r.id == task.id && r.isWorkspaceItem),
        reason: 'Undo restores completed task from Trash',
      );
      expect(find.byType(TaskCard), findsOneWidget);

      // Delete again and let 5 seconds elapse -> notification auto-closes!
      await tester.tap(find.byKey(const ValueKey('delete-done-1')));
      await pumpUntilRealIo(
        tester,
        () => find.text('已删除事项: 整理季度复盘文档').evaluate().isNotEmpty,
        reason: 'second delete feedback appears',
      );
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('已删除事项: 整理季度复盘文档'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));
      expect(find.text('已删除事项: 整理季度复盘文档'), findsNothing);
      expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'native sync warning on delete stays visible past 5s while normal dialog/filter deletes auto-close in 5s',
    (tester) async {
      final activeTask = Reminder(
        id: 'dialog-del',
        taskTitle: '弹窗删除任务',
        quadrantLevel: 1,
      );
      final warnTask = Reminder(
        id: 'warn-del',
        taskTitle: '系统提醒取消失败任务',
        quadrantLevel: 1,
        triggerTime: DateTime.now().add(const Duration(hours: 2)),
      );
      await tester.runAsync(() async {
        final notifier = container.read(remindersProvider.notifier);
        await notifier.addReminder(activeTask);
        await notifier.addReminder(warnTask);
        await container
            .read(savedTaskFilterStoreProvider)
            .save('今日重点', 'manage', '重点');
      });

      await mountHost(
        tester,
        Consumer(
          builder: (context, ref, _) {
            final current = ref
                .watch(remindersProvider)
                .where((r) => r.id == warnTask.id && r.isWorkspaceItem)
                .firstOrNull;
            return Column(
              children: [
                SavedTaskFiltersBar(
                  view: 'manage',
                  query: '',
                  onSelected: (_) {},
                ),
                Builder(
                  builder: (ctx) => TextButton(
                    key: const ValueKey('open-edit-dialog'),
                    onPressed: () => showDialog<void>(
                      context: ctx,
                      builder: (_) => TaskEditDialog(task: activeTask),
                    ),
                    child: const Text('打开编辑'),
                  ),
                ),
                if (current != null)
                  TaskCard(task: current, onPlayMedia: () {}),
              ],
            );
          },
        ),
      );

      // 1. Delete via TaskEditDialog -> auto-closes after 5s.
      await tester.tap(find.byKey(const ValueKey('open-edit-dialog')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await pumpUntilRealIo(
        tester,
        () => find.text('已删除事项: 弹窗删除任务').evaluate().isNotEmpty,
        reason: 'TaskEditDialog delete banner appears',
      );
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('已删除事项: 弹窗删除任务'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));
      expect(find.text('已删除事项: 弹窗删除任务'), findsNothing);

      // 2. Delete saved filter -> Undo banner auto-closes after 5s.
      await pumpUntilRealIo(
        tester,
        () => find.text('常用筛选 (1)').evaluate().isNotEmpty,
        reason: 'saved filters loaded',
      );
      await tester.tap(find.text('常用筛选 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('筛选选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除筛选'));
      await pumpUntilRealIo(
        tester,
        () => find.text('已删除常用筛选').evaluate().isNotEmpty,
        reason: 'saved filter delete banner appears',
      );
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('已删除常用筛选'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));
      expect(find.text('已删除常用筛选'), findsNothing);

      // 3. Native cancellation failure warning stays visible past 5s!
      notifications.failNative = true;
      await tester.tap(find.byKey(const ValueKey('actions-warn-del')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除事项'));
      const nativeFailMsg = '任务已删除，但系统提醒未能移除。请在设置中点击“重新安排提醒”重试。';
      await pumpUntilRealIo(
        tester,
        () => find.text(nativeFailMsg).evaluate().isNotEmpty,
        reason: 'native cancel warning appears',
      );
      await tester.pump(const Duration(seconds: 6));
      expect(find.text(nativeFailMsg), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TaskWorkspaceOverview excludes trashed completed tasks, sorts newest first, and supports batch delete/reopen/clear with 5s Undo',
    (tester) async {
      final base = DateTime(2026, 11, 25, 12, 0);
      final doneOldest = completedReminder(
        id: 'done-a',
        title: '最早完成事项',
        completedAt: base.subtract(const Duration(hours: 3)),
      );
      final doneMiddle = completedReminder(
        id: 'done-b',
        title: '中间完成事项',
        completedAt: base.subtract(const Duration(hours: 1)),
      );
      final doneNewest = completedReminder(
        id: 'done-c',
        title: '最新完成事项',
        completedAt: base,
      );
      final trashedDone = completedReminder(
        id: 'done-trashed',
        title: '回收站已完成事项',
        completedAt: base,
        deletedAt: base,
      );
      final learningArchived = completedReminder(
        id: 'done-learning',
        title: '学习归档已完成事项',
        completedAt: base,
        learningArchive: true,
      );

      await tester.runAsync(() async {
        final notifier = container.read(remindersProvider.notifier);
        await notifier.addReminder(doneOldest);
        await notifier.addReminder(doneMiddle);
        await notifier.addReminder(doneNewest);
        await notifier.addReminder(trashedDone);
        await notifier.addReminder(learningArchived);
      });

      await mountHost(
        tester,
        Consumer(
          builder: (context, ref, _) => TaskWorkspaceOverview(
            reminders: ref.watch(remindersProvider),
            onPlayMedia: (_) {},
          ),
        ),
      );

      // Completed chip is visible and counts ONLY workspace completed tasks (3, not 5!).
      final completedChip = find.byKey(
        const ValueKey('workspace-view-completed'),
      );
      expect(completedChip, findsOneWidget);
      expect(
        find.descendant(of: completedChip, matching: find.text('3')),
        findsOneWidget,
      );

      await tester.tap(completedChip);
      await tester.pumpAndSettle();

      // Verify newest-completed-first ordering: done-c -> done-b -> done-a.
      final yNewest = tester.getTopLeft(find.text('最新完成事项')).dy;
      final yMiddle = tester.getTopLeft(find.text('中间完成事项')).dy;
      final yOldest = tester.getTopLeft(find.text('最早完成事项')).dy;
      expect(yNewest, lessThan(yMiddle));
      expect(yMiddle, lessThan(yOldest));
      expect(find.text('回收站已完成事项'), findsNothing);
      expect(find.text('学习归档已完成事项'), findsNothing);

      // Enter batch selection mode and select 2 items.
      await tester.tap(
        find.byKey(const ValueKey('workspace-completed-select-toggle')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-completed-selection-bar')),
        findsOneWidget,
      );

      await tester.tap(find.text('最新完成事项'));
      await tester.pump();
      await tester.tap(find.text('最早完成事项'));
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);

      // Batch delete selected (2) -> atomic Trash + 5s Undo restores both!
      await tester.tap(
        find.byKey(const ValueKey('workspace-completed-delete-selected')),
      );
      await pumpUntilRealIo(
        tester,
        () => find.text('已删除 2 项事项').evaluate().isNotEmpty,
        reason: 'batch delete Undo banner appears',
      );
      expect(find.text('最新完成事项'), findsNothing);
      expect(find.text('最早完成事项'), findsNothing);
      expect(find.text('中间完成事项'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await pumpUntilRealIo(
        tester,
        () =>
            container
                .read(remindersProvider)
                .where(
                  (r) =>
                      r.isCompleted &&
                      r.isWorkspaceItem &&
                      r.details.data['learning_archive'] != true,
                )
                .length ==
            3,
        reason: 'Undo restores both batch-deleted completed tasks',
      );
      expect(find.text('最新完成事项'), findsOneWidget);
      expect(find.text('最早完成事项'), findsOneWidget);

      // Batch reopen 1 item -> auto-closes within 5s.
      await tester.tap(
        find.byKey(const ValueKey('workspace-completed-select-toggle')),
      );
      await tester.pump();
      await tester.tap(find.text('中间完成事项'));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('workspace-completed-reopen-selected')),
      );
      await pumpUntilRealIo(
        tester,
        () => find.text('已将 1 项标为未完成').evaluate().isNotEmpty,
        reason: 'batch reopen feedback appears',
      );
      await tester.pump(const Duration(seconds: 5, milliseconds: 100));
      expect(find.text('已将 1 项标为未完成'), findsNothing);

      // Clear remaining 2 completed tasks -> confirm -> auto-closes after 5s!
      await tester.tap(
        find.byKey(const ValueKey('workspace-completed-clear-completed')),
      );
      await tester.pumpAndSettle();
      expect(find.text('清理已完成事项 (2)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-clear-completed')));
      await pumpUntilRealIo(
        tester,
        () => find.text('已删除 2 项事项').evaluate().isNotEmpty,
        reason: 'clear completed Undo banner appears',
      );
      expect(find.text('当前没有已完成的事项。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5, milliseconds: 100));
      expect(find.text('已删除 2 项事项'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TaskSearchPanel completed filter and QuadrantView completed header support batch delete with 5s auto-close',
    (tester) async {
      final now = DateTime(2026, 11, 25, 16, 0);
      await tester.runAsync(() async {
        final notifier = container.read(remindersProvider.notifier);
        await notifier.addReminder(
          completedReminder(
            id: 'q1-done-1',
            title: '搜索已完成一',
            completedAt: now,
            quadrant: 1,
          ),
        );
        await notifier.addReminder(
          completedReminder(
            id: 'q1-done-2',
            title: '搜索已完成二',
            completedAt: now.subtract(const Duration(minutes: 10)),
            quadrant: 1,
          ),
        );
      });

      // 1. TaskSearchPanel completed filter select-all + batch delete + Undo.
      await mountHost(
        tester,
        TaskSearchPanel(query: '', onClearQuery: () {}, onPlayMedia: (_) {}),
      );
      await tester.tap(find.byKey(const ValueKey('search-filter-completed')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-completed-select-toggle')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('search-completed-select-toggle')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('search-completed-select-all')),
      );
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('search-completed-delete-selected')),
      );
      await pumpUntilRealIo(
        tester,
        () => find.text('已删除 2 项事项').evaluate().isNotEmpty,
        reason: 'search batch delete feedback',
      );
      await tester.tap(find.text('撤销'));
      await pumpUntilRealIo(
        tester,
        () =>
            container
                .read(remindersProvider)
                .where((r) => r.isCompleted && r.isWorkspaceItem)
                .length ==
            2,
        reason: 'search Undo restores both items',
      );

      // 2. QuadrantView quick clear completed button + 5s auto-close.
      await mountHost(
        tester,
        Consumer(
          builder: (context, ref, _) => QuadrantView(
            level: 1,
            titleIcon: const Icon(Icons.flag),
            allReminders: ref.watch(remindersProvider),
            bgColor: Colors.red,
            onPlayMedia: (_) {},
          ),
        ),
      );
      final clearQ1 = find.byKey(const ValueKey('quadrant-clear-completed-1'));
      expect(clearQ1, findsOneWidget);
      await tester.tap(clearQ1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-clear-completed')));
      await pumpUntilRealIo(
        tester,
        () => find.text('已删除 2 项事项').evaluate().isNotEmpty,
        reason: 'quadrant clear completed feedback',
      );
      await tester.pump(const Duration(seconds: 5, milliseconds: 100));
      expect(find.text('已删除 2 项事项'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'completed TaskCard and selection toolbar fit 320px/375px/1440px at 2x text across zh/en/ja without overflow',
    (tester) async {
      final task = completedReminder(
        id: 'narrow-done',
        title: '非常长的已完成事项标题用于窄屏两倍字号布局无溢出回归验证 Long Completed Task',
        completedAt: DateTime(2026, 11, 25, 20, 15),
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).addReminder(task),
      );

      for (final language in ['zh', 'en', 'ja']) {
        for (final width in [320.0, 375.0, 1440.0]) {
          await mountHost(
            tester,
            Consumer(
              builder: (context, ref, _) => TaskWorkspaceOverview(
                activeView: 'completed',
                reminders: ref.watch(remindersProvider),
                onPlayMedia: (_) {},
              ),
            ),
            language: language,
            textScale: 2.0,
            size: Size(width, 900),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'normal mode $language @ $width',
          );
          await tester.tap(
            find.byKey(const ValueKey('workspace-completed-select-toggle')),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'selection mode $language @ $width',
          );
          await tester.tap(
            find.byKey(const ValueKey('workspace-completed-exit-select')),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'exit selection $language @ $width',
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
