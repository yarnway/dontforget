import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:dont_forget/ui/screens/dashboard_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/lan_sync_conflicts_dialog.dart';
import 'package:dont_forget/ui/widgets/quadrant_view.dart';
import 'package:dont_forget/ui/widgets/task_workspace_overview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/offline_management_harness.dart';

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

Widget _themedApp({
  required ThemeData theme,
  required Widget home,
  ProviderContainer? container,
  double textScale = 1.0,
}) {
  final app = MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
    localizationsDelegates: const [
      AppLocalizationsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: InlineFeedback(child: child!),
    ),
    home: home,
  );
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  return ProviderScope(child: app);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppTheme defines unified dialog, popup, chip, snackbar tokens with AA contrast', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final colors = theme.colorScheme;
      expect(theme.dialogTheme.backgroundColor, colors.surfaceContainerHigh);
      expect(theme.popupMenuTheme.color, colors.surfaceContainer);
      expect(theme.chipTheme.selectedColor, colors.secondaryContainer);
      expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);

      expect(
        _contrastRatio(colors.onSurface, colors.surface),
        greaterThanOrEqualTo(7.0),
      );
      expect(
        _contrastRatio(colors.onSurface, colors.surfaceContainerHigh),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(colors.onSurfaceVariant, colors.surfaceContainerLow),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(colors.onSecondaryContainer, colors.secondaryContainer),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  testWidgets('DashboardScreen colors each quadrant bar with distinct semantic colors', (
    tester,
  ) async {
    final h = OfflineManagementHarness();
    await tester.runAsync(() async {
      await h.create();
      for (var q = 1; q <= 4; q++) {
        await h.seed(
          Reminder(id: 'q$q', taskTitle: 'Task Q$q', quadrantLevel: q),
        );
      }
    });
    addTearDown(h.dispose);

    await tester.pumpWidget(
      _themedApp(
        theme: AppTheme.light,
        container: h.container,
        home: const DashboardScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final barColors = <Color?>{};
    for (var q = 1; q <= 4; q++) {
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byKey(ValueKey('dashboard-cat-bar-$q')),
      );
      expect(indicator.color, isNotNull);
      barColors.add(indicator.color);
    }
    expect(barColors.length, 4);
  });

  testWidgets('LanSyncConflictsDialog renders diff summary and tinted comparison boxes cleanly', (
    tester,
  ) async {
    const conflict = LanSyncConflict(
      taskId: 't1',
      local: (title: '本地标题', note: '本地备注', inTrash: false),
      peer: (title: '对端标题', note: '对端备注', inTrash: false),
    );

    for (final theme in [AppTheme.light, AppTheme.dark]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _themedApp(
          theme: theme,
          textScale: 1.5,
          home: const Scaffold(
            body: LanSyncConflictsDialog(
              conflicts: [conflict],
              openableTaskIds: {'t1'},
              adoptableTaskIds: {'t1'},
              trashActionTaskIds: {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本地标题'), findsOneWidget);
      expect(find.text('标题 · 备注'), findsOneWidget);

      await tester.tap(find.text('本地标题'));
      await tester.pumpAndSettle();

      expect(find.text('对端标题'), findsOneWidget);
      expect(find.text('本地备注'), findsOneWidget);
      expect(find.text('对端备注'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('QuadrantView renders tinted count pill and empty state cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(
      _themedApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: QuadrantView(
              level: 1,
              titleIcon: const Icon(Icons.notifications_active_outlined),
              allReminders: [
                Reminder(id: 'a1', taskTitle: '紧急任务', quadrantLevel: 1),
              ],
              bgColor: AppTheme.dark.colorScheme.error,
              onPlayMedia: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quadrant-count-1')), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TaskWorkspaceOverview renders semantic Today headers with counts and calm empty state', (
    tester,
  ) async {
    final h = OfflineManagementHarness();
    await tester.runAsync(h.create);
    addTearDown(h.dispose);

    final now = DateTime.now();
    final todayTask = Reminder(
      id: 'today-1',
      taskTitle: '今天要完成',
      quadrantLevel: 1,
      isPinned: true,
      triggerTime: DateTime(now.year, now.month, now.day, 23, 50),
    );

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      _themedApp(
        theme: AppTheme.light,
        container: h.container,
        textScale: 1.5,
        home: Scaffold(
          body: TaskWorkspaceOverview(
            reminders: [todayTask],
            activeView: 'today',
            onPlayMedia: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今天要完成'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(tester.takeException(), isNull);

    // Empty state
    await tester.pumpWidget(
      _themedApp(
        theme: AppTheme.dark,
        container: h.container,
        home: Scaffold(
          body: TaskWorkspaceOverview(
            reminders: const [],
            activeView: 'today',
            onPlayMedia: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.wb_sunny_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
