import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/services/ai/priority_router.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/quick_reminder_parser.dart';
import 'package:dont_forget/services/task_search_index.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/command_palette_dialog.dart';
import 'package:dont_forget/ui/widgets/content_management_panel.dart';
import 'package:dont_forget/ui/widgets/task_metadata_editor.dart';
import 'package:dont_forget/ui/widgets/task_workspace_overview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

double _relativeLuminance(Color c) {
  double linear(double channel) => channel <= 0.03928
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
}

double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

Widget _wrapApp(Widget child, {Locale locale = const Locale('zh')}) {
  return ProviderScope(
    child: MaterialApp(
      locale: locale,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
      home: Scaffold(body: child),
    ),
  );
}

class _StubHttpAdapter implements HttpClientAdapter {
  _StubHttpAdapter(this.responder);

  final ResponseBody Function(RequestOptions options) responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => responder(options);

  @override
  void close({bool force = false}) {}
}

void main() {
  group('v1.8.23 Batch 1 — LLM extraction hardening & ContextTrigger pre-check', () {
    test('extractTasks clamps invalid quadrant levels and bounds lead minutes', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StubHttpAdapter(
        (_) => ResponseBody.fromString(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'tasks': [
                      {
                        'task_title': 'Overflow quadrant',
                        'quadrant_level': 99,
                        'reminder_lead_minutes': 999999,
                      },
                      {
                        'task_title': 'Negative quadrant',
                        'quadrant_level': -2,
                        'reminder_lead_minutes': -5,
                      },
                    ],
                  }),
                },
              },
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final service = LLMService(client: dio);
      final settings = AppSettings(
        id: 'test-1',
        language: 'en',
        apiKey: 'test-key',
        baseUrl: 'https://example.invalid/v1',
        modelName: 'test-model',
      );
      final tasks = await service.extractTasks('check bounds', settings);
      expect(tasks, hasLength(2));
      expect(tasks[0].quadrantLevel, inInclusiveRange(1, 4));
      expect(tasks[0].quadrantLevel, 4);
      expect(tasks[1].quadrantLevel, inInclusiveRange(1, 4));
      expect(tasks[1].quadrantLevel, 4);
      expect(tasks[0].details.data['reminder_lead_minutes'], isNull);
      expect(tasks[1].details.data['reminder_lead_minutes'], isNull);
    });

    test('structuredProposal converts malformed choices payload into AiRouteFailure (not TypeError/RangeError)', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StubHttpAdapter(
        (_) => ResponseBody.fromString(
          jsonEncode({'choices': []}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final service = LLMService(client: dio);
      final settings = AppSettings(
        id: 'test-1',
        language: 'en',
        apiKey: 'test-key',
        baseUrl: 'https://example.invalid/v1',
        modelName: 'test-model',
      );
      await expectLater(
        () => service.structuredProposal('sys', 'user', settings),
        throwsA(isA<AiRouteFailure>()),
      );
    });

    test('ContextTriggerService.hasPendingWifiTrigger skips completed, hidden, paused, and already-triggered tasks', () {
      final service = ContextTriggerService();
      final wifiRule = const ContextTriggerRule(
        type: 'wifi',
        value: 'OfficeWiFi',
      ).toJsonString();
      final profileRule = const ContextTriggerRule(
        type: 'profile',
        value: 'office',
      ).toJsonString();

      final completed = Reminder(
        id: 'w-done',
        taskTitle: 'Done',
        quadrantLevel: 3,
        isCompleted: true,
        contextTrigger: wifiRule,
      );
      final paused = Reminder(
        id: 'w-paused',
        taskTitle: 'Paused',
        quadrantLevel: 3,
        contextTrigger: wifiRule,
        detailsJson: const TaskDetails(paused: true).encode(),
      );
      final profileOnly = Reminder(
        id: 'p-only',
        taskTitle: 'Profile only',
        quadrantLevel: 3,
        contextTrigger: profileRule,
      );
      final activeWifi = Reminder(
        id: 'w-active',
        taskTitle: 'Active WiFi',
        quadrantLevel: 2,
        contextTrigger: wifiRule,
      );

      expect(
        service.hasPendingWifiTrigger([completed, paused, profileOnly]),
        isFalse,
      );
      expect(
        service.hasPendingWifiTrigger([completed, paused, activeWifi]),
        isTrue,
      );

      // Once evaluated & triggered in this session, it should no longer trigger a probe.
      final triggered = service.evaluateContextTriggers(
        [activeWifi],
        ssid: 'OfficeWiFi',
      );
      expect(triggered.map((r) => r.id), ['w-active']);
      expect(service.hasPendingWifiTrigger([activeWifi]), isFalse);
    });
  });

  group('v1.8.23 Batch 2 — QuickReminderParser improvements', () {
    final now = DateTime(2026, 11, 22, 8, 0);

    test('parses CJK 零X分 accurately', () {
      expect(
        QuickReminderParser.parse('明天下午三点零五分买牛奶', now: now),
        DateTime(2026, 11, 23, 15, 5),
      );
      expect(
        QuickReminderParser.parse('明天3点零5分开会', now: now),
        DateTime(2026, 11, 23, 3, 5),
      );
    });

    test('parses compound relative durations and skips bare duration before relative trigger', () {
      expect(
        QuickReminderParser.parse('1小时30分钟后提醒我喝水', now: now),
        DateTime(2026, 11, 22, 9, 30),
      );
      expect(
        QuickReminderParser.parse('开会30分钟，10分钟后提醒', now: now),
        DateTime(2026, 11, 22, 8, 10),
      );
    });

    test('parses 明晚, 今早, and standalone English am/pm times', () {
      expect(
        QuickReminderParser.parse('明晚8点开会', now: now),
        DateTime(2026, 11, 23, 20, 0),
      );
      expect(
        QuickReminderParser.parse('今早9点买菜', now: now),
        DateTime(2026, 11, 22, 9, 0),
      );
      expect(QuickReminderParser.parse('明晚开会', now: now), isNull);
      expect(
        QuickReminderParser.parse('3pm call Alex', now: now),
        DateTime(2026, 11, 22, 15, 0),
      );
      expect(
        QuickReminderParser.parse('3:30 pm sync', now: now),
        DateTime(2026, 11, 22, 15, 30),
      );
    });

    test('caps input length at maxParseLength without throwing', () {
      final huge = '${'a' * 10000} 明天9点';
      expect(QuickReminderParser.parse(huge, now: now), isNull);
    });
  });

  group('v1.8.23 Batch 4 — Theme AA contrast, Search parity, Workspace & Palette', () {
    test('Light Q2 quadrantColor meets WCAG AA (>= 4.5:1) on white and 12%-tinted chip', () {
      final q2 = AppTheme.quadrantColor(Brightness.light, 2);
      final chipBg = Color.alphaBlend(q2.withValues(alpha: 0.12), Colors.white);
      expect(_contrastRatio(q2, Colors.white), greaterThanOrEqualTo(4.5));
      expect(_contrastRatio(q2, chipBg), greaterThanOrEqualTo(4.5));
    });

    test('TaskSearchIndex.project counts match search() lengths for every filter', () {
      final now = DateTime(2026, 11, 22, 14, 0);
      final reminders = [
        Reminder(
          id: 't-overdue',
          taskTitle: 'Alpha overdue',
          quadrantLevel: 2,
          triggerTime: DateTime(2026, 11, 22, 10, 0),
        ),
        Reminder(
          id: 't-today-future',
          taskTitle: 'Alpha today later',
          quadrantLevel: 3,
          triggerTime: DateTime(2026, 11, 22, 18, 0),
        ),
        Reminder(
          id: 't-pinned-no-time',
          taskTitle: 'Alpha pinned only',
          quadrantLevel: 1,
          isPinned: true,
        ),
        Reminder(
          id: 't-yesterday',
          taskTitle: 'Alpha yesterday overdue',
          quadrantLevel: 2,
          triggerTime: DateTime(2026, 11, 21, 9, 0),
        ),
        Reminder(
          id: 't-done',
          taskTitle: 'Alpha finished',
          quadrantLevel: 4,
          isCompleted: true,
          triggerTime: DateTime(2026, 11, 22, 11, 0),
        ),
      ];
      final index = TaskSearchIndex(reminders);
      for (final query in const ['', 'alpha']) {
        final projected = index.project(
          query,
          filter: TaskSearchFilter.all,
          includeAllWhenEmpty: true,
          now: now,
        );
        for (final filter in TaskSearchFilter.values) {
          final results = index.search(
            query,
            filter: filter,
            includeAllWhenEmpty: true,
            now: now,
          );
          expect(
            projected.counts[filter],
            results.length,
            reason: 'Filter $filter count must match search() results for "$query"',
          );
        }
      }
    });

    testWidgets(
      'TaskWorkspaceOverview routes trigger-only overdue tasks to todayOverdue, groups Future view, and calls onViewChanged',
      (tester) async {
        final now = DateTime.now();
        final todayStart = DateTime(now.year, now.month, now.day);
        final overdueTriggerOnly = Reminder(
          id: 'overdue-trigger-only',
          taskTitle: 'Call bank now',
          quadrantLevel: 3,
          triggerTime: now.subtract(const Duration(minutes: 20)),
        );
        final tomorrowTask = Reminder(
          id: 'tomorrow-task',
          taskTitle: 'Tomorrow presentation',
          quadrantLevel: 2,
          triggerTime: todayStart.add(const Duration(days: 1, hours: 10)),
        );
        final nextMonthTask = Reminder(
          id: 'later-task',
          taskTitle: 'Annual physical',
          quadrantLevel: 2,
          triggerTime: todayStart.add(const Duration(days: 20, hours: 10)),
        );
        final reportedViews = <String>[];

        await tester.pumpWidget(
          _wrapApp(
            TaskWorkspaceOverview(
              reminders: [overdueTriggerOnly, tomorrowTask, nextMonthTask],
              onPlayMedia: (_) {},
              onViewChanged: reportedViews.add,
            ),
            locale: const Locale('en'),
          ),
        );
        await tester.pumpAndSettle();

        // Trigger-only overdue task should render under "Overdue", not "Today's tasks".
        expect(find.text('Overdue'), findsOneWidget);
        expect(find.text('Call bank now'), findsOneWidget);

        // Switch to Upcoming (future) view and verify callback + Tomorrow/Later headers.
        await tester.tap(find.byKey(const ValueKey('workspace-view-future')));
        await tester.pumpAndSettle();
        expect(reportedViews, ['future']);
        expect(find.text('Tomorrow'), findsOneWidget);
        expect(find.text('Later'), findsOneWidget);
        expect(find.text('Tomorrow presentation'), findsOneWidget);
        expect(find.text('Annual physical'), findsOneWidget);
      },
    );

    testWidgets(
      'CommandPaletteDialog matches shortcuts and multi-word queries and ranks prefix matches first',
      (tester) async {
        String? executed;
        final actions = [
          CommandPaletteAction(
            id: 'secondary',
            title: 'Open study overview',
            subtitle: 'Review history',
            icon: Icons.history,
            onExecute: () => executed = 'secondary',
          ),
          CommandPaletteAction(
            id: 'study',
            title: 'Study queue',
            subtitle: 'Spaced repetition',
            icon: Icons.school_outlined,
            shortcut: '/study',
            onExecute: () => executed = 'study',
          ),
        ];

        await tester.pumpWidget(
          _wrapApp(CommandPaletteDialog(actions: actions), locale: const Locale('en')),
        );
        await tester.pumpAndSettle();

        // Typing shortcut "/study" should match the study action.
        await tester.enterText(find.byType(TextField), '/study');
        await tester.pumpAndSettle();
        expect(find.text('Study queue'), findsOneWidget);
        expect(find.text('Open study overview'), findsNothing);
        expect(find.byKey(const ValueKey('command-palette-count')), findsOneWidget);

        // Typing "study" should rank prefix match "Study queue" ahead of "Open study overview".
        await tester.enterText(find.byType(TextField), 'study');
        await tester.pumpAndSettle();
        final studyY = tester.getTopLeft(find.text('Study queue')).dy;
        final overviewY = tester.getTopLeft(find.text('Open study overview')).dy;
        expect(studyY, lessThan(overviewY));

        // Multi-word query across title + subtitle.
        await tester.enterText(find.byType(TextField), 'study repetition');
        await tester.pumpAndSettle();
        expect(find.text('Study queue'), findsOneWidget);
        expect(find.text('Open study overview'), findsNothing);
        expect(executed, isNull);
      },
    );

    testWidgets(
      'TaskMetadataEditor submits new checklist item on TextInputAction.done',
      (tester) async {
        var current = const TaskDetails();
        await tester.pumpWidget(
          _wrapApp(
            StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: TaskMetadataEditor(
                  details: current,
                  onChanged: (next) => setState(() => current = next),
                  onValidityChanged: (_) {},
                ),
              ),
            ),
            locale: const Locale('en'),
          ),
        );
        await tester.pumpAndSettle();

        final input = find.byKey(const ValueKey('detail-new-checklist-item'));
        expect(
          tester.widget<TextField>(input).textInputAction,
          TextInputAction.done,
        );
        await tester.enterText(input, 'Verify deployment');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(current.checklist.map((e) => e.label), ['Verify deployment']);
      },
    );
  });

  group('v1.8.23 Batch 5 — ContentManagementPanel unscanned state & query clear', () {
    testWidgets('shows unscanned prompt before first scan and clear button on search query', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapApp(const ContentManagementPanel(), locale: const Locale('en')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('content-unscanned-hint')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('content-query-clear')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('content-query')),
        'invoice',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('content-query-clear')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('content-query-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('content-query-clear')), findsNothing);
    });
  });
}
