import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/home_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/missed_reminders_bar.dart';
import 'package:dont_forget/ui/widgets/reminder_notice_panel.dart';
import 'package:dont_forget/ui/widgets/task_workspace_overview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/workspace_drafts.dart';

Widget _buildTestApp({
  required Widget child,
  required String language,
  double textScale = 1.0,
}) {
  return MaterialApp(
    locale: Locale(language),
    supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
    localizationsDelegates: const [
      AppLocalizationsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: c!,
    ),
    home: Scaffold(body: child),
  );
}

class _ObservedReminders extends RemindersNotifier {
  _ObservedReminders(super.database, NotificationService notifications)
    : super(notifications: notifications, runLoadEffects: false);

  Future<void>? lastAction;

  @override
  Future<List<ReminderActionResult>> acknowledgeOccurrences(
    List<Reminder> expected, {
    DateTime? now,
  }) {
    final operation = super.acknowledgeOccurrences(expected, now: now);
    lastAction = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Missed reminders detection & 72h boundary', () {
    final now = DateTime(2026, 10, 29, 12, 0, 0);

    test('empty when no reminders are overdue', () {
      final r = Reminder(
        id: 'future-1',
        taskTitle: 'Future Task',
        quadrantLevel: 1,
        triggerTime: now.add(const Duration(hours: 1)),
      );
      expect(r.isMissed(now), isFalse);
      expect(selectMissedReminders([r], now), isEmpty);
    });

    test('single reminder 10 minutes ago is missed', () {
      final r = Reminder(
        id: '10m',
        taskTitle: '10 Min Ago Task',
        quadrantLevel: 1,
        triggerTime: now.subtract(const Duration(minutes: 10)),
      );
      expect(r.isMissed(now), isTrue);
      expect(selectMissedReminders([r], now).length, 1);
    });

    test(
      'multiple reminders within 72h are missed and sorted by triggerTime',
      () {
        final r1 = Reminder(
          id: '2h',
          taskTitle: '2 Hours Ago',
          quadrantLevel: 1,
          triggerTime: now.subtract(const Duration(hours: 2)),
        );
        final r2 = Reminder(
          id: '10m',
          taskTitle: '10 Min Ago',
          quadrantLevel: 1,
          triggerTime: now.subtract(const Duration(minutes: 10)),
        );
        final r3 = Reminder(
          id: '24h',
          taskTitle: '24 Hours Ago',
          quadrantLevel: 1,
          triggerTime: now.subtract(const Duration(hours: 24)),
        );
        final missed = selectMissedReminders([r1, r2, r3], now);
        expect(missed.length, 3);
        expect(missed.map((m) => m.id).toList(), ['24h', '2h', '10m']);
      },
    );

    test('72h boundary: exactly 72h is included, > 72h is excluded', () {
      final exact72h = Reminder(
        id: 'exact-72h',
        taskTitle: 'Exact 72h',
        quadrantLevel: 1,
        triggerTime: now.subtract(const Duration(hours: 72)),
      );
      final past72h = Reminder(
        id: 'past-72h',
        taskTitle: 'Past 72h 1s',
        quadrantLevel: 1,
        triggerTime: now.subtract(const Duration(hours: 72, seconds: 1)),
      );
      final threeDaysAgo = Reminder(
        id: '3d',
        taskTitle: '3 Days Ago',
        quadrantLevel: 1,
        triggerTime: now.subtract(const Duration(days: 3, minutes: 1)),
      );

      expect(exact72h.isMissed(now), isTrue);
      expect(past72h.isMissed(now), isFalse);
      expect(threeDaysAgo.isMissed(now), isFalse);

      final selected = selectMissedReminders([
        exact72h,
        past72h,
        threeDaysAgo,
      ], now);
      expect(selected.length, 1);
      expect(selected.single.id, 'exact-72h');
    });

    test('already acknowledged or completed are not missed', () {
      final acknowledged = Reminder(
        id: 'ack',
        taskTitle: 'Acknowledged Task',
        quadrantLevel: 1,
        triggerTime: now.subtract(const Duration(hours: 1)),
        noticeAcknowledgedAt: now.subtract(const Duration(minutes: 30)),
      );
      final completed = Reminder(
        id: 'completed',
        taskTitle: 'Completed Task',
        quadrantLevel: 1,
        triggerTime: now.subtract(const Duration(hours: 1)),
        isCompleted: true,
      );
      expect(acknowledged.isMissed(now), isFalse);
      expect(completed.isMissed(now), isFalse);
      expect(selectMissedReminders([acknowledged, completed], now), isEmpty);
    });

    test(
      'visible occurrences are excluded without hiding a later revision',
      () {
        final task = Reminder(
          id: 'visible',
          taskTitle: 'Visible due reminder',
          quadrantLevel: 1,
          triggerTime: now.subtract(const Duration(hours: 1)),
        );
        final revised = task.copyWith(noticeRevision: task.noticeRevision + 1);
        final missed = selectMissedReminders(
          [task, revised],
          now,
          visibleNoticeOccurrences: [task.occurrenceIdentity],
        );
        expect(missed, [revised]);
      },
    );
  });

  group('MissedRemindersBar responsive rendering & tri-lingual display', () {
    final now = DateTime(2026, 10, 29, 12, 0, 0);
    final r1 = Reminder(
      id: 'm1',
      taskTitle: 'Missed Task 1',
      quadrantLevel: 1,
      triggerTime: now.subtract(const Duration(minutes: 10)),
    );
    final r2 = Reminder(
      id: 'm2',
      taskTitle: 'Missed Task 2',
      quadrantLevel: 1,
      triggerTime: now.subtract(const Duration(hours: 2)),
    );

    testWidgets('renders SizedBox.shrink when empty', (tester) async {
      await tester.pumpWidget(
        _buildTestApp(
          language: 'zh',
          child: MissedRemindersBar(
            reminders: const [],
            onOpenMissed: () {},
            onAcknowledgeAll: () {},
          ),
        ),
      );
      expect(find.byKey(const ValueKey('missed-reminders-bar')), findsNothing);
    });

    for (final width in [375.0, 768.0, 1440.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final lang in ['zh', 'en', 'ja']) {
          testWidgets(
            'renders 1 and 2 items across $width / scale $scale / $lang without overflow',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 900);
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);

              final loc = AppLocalizations(Locale(lang));
              var opened = false;
              var acknowledged = false;

              await tester.pumpWidget(
                _buildTestApp(
                  language: lang,
                  textScale: scale,
                  child: MissedRemindersBar(
                    reminders: [r1, r2],
                    onOpenMissed: () => opened = true,
                    onAcknowledgeAll: () => acknowledged = true,
                  ),
                ),
              );
              await tester.pumpAndSettle();

              // Verify bar exists
              expect(
                find.byKey(const ValueKey('missed-reminders-bar')),
                findsOneWidget,
              );

              final rect = tester.getRect(
                find.byKey(const ValueKey('missed-reminders-bar')),
              );
              final frameWidth = width > 1040 ? 1040.0 : width;
              expect(rect.width, closeTo(frameWidth - 24, .01));
              expect(rect.center.dx, closeTo(width / 2, .01));

              // Verify tri-lingual count text: <title> · 2
              final expectedTitle = '${loc.get('missedReminders')} · 2';
              expect(find.text(expectedTitle), findsOneWidget);

              // Verify tri-lingual button text
              final expectedButton = loc.get('allAcknowledged');
              expect(find.text(expectedButton), findsOneWidget);

              // Tap interactions
              await tester.tap(
                find.byKey(const ValueKey('missed-reminders-title')),
              );
              expect(opened, isTrue);

              await tester.tap(
                find.byKey(const ValueKey('missed-reminders-acknowledge-all')),
              );
              expect(acknowledged, isTrue);

              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  });

  group(
    'Full workflow: 3 reminders -> count 2 -> acknowledge -> disappears after restart',
    () {
      late Directory tempDir;
      late DatabaseHelper database;
      late NotificationService notifications;
      late ProviderContainer container;
      late _ObservedReminders reminders;
      final channels = <MethodChannel>[];

      Future<void> load() async {
        database = DatabaseHelper.forTesting(tempDir.path, databaseFactoryFfi);
        notifications = NotificationService.forTesting(
          FlutterLocalNotificationsPlugin(),
          usesNativeNotifications: false,
        );
        container = ProviderContainer(
          overrides: [
            databaseHelperProvider.overrideWithValue(database),
            notificationServiceProvider.overrideWithValue(notifications),
            contextTriggerServiceProvider.overrideWithValue(
              ContextTriggerService.forTesting(),
            ),
            remindersProvider.overrideWith(
              (ref) => reminders = _ObservedReminders(database, notifications),
            ),
          ],
        );
        await container.read(settingsProvider.notifier).ready;
        await container.read(workspaceDraftsProvider.notifier).ready;
        await container.read(mediaRecordsProvider.notifier).ready;
        await container.read(remindersProvider.notifier).ready;
      }

      Future<void> unload() async {
        container.dispose();
        await notifications.pauseForMaintenance();
        await database.close(createBackup: false);
      }

      setUp(() async {
        sqfliteFfiInit();
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        channels.addAll(const [
          MethodChannel('xyz.luan/audioplayers.global'),
          MethodChannel('xyz.luan/audioplayers.global/events'),
          MethodChannel('xyz.luan/audioplayers'),
          MethodChannel('com.llfbandit.record/messages'),
          MethodChannel('tray_manager'),
        ]);
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'create') {
              final id = (call.arguments as Map)['playerId'];
              final events = MethodChannel('xyz.luan/audioplayers/events/$id');
              channels.add(events);
              messenger.setMockMethodCallHandler(events, (_) async => null);
            }
            return null;
          });
        }
        tempDir = await Directory.systemTemp.createTemp(
          'missed-reminders-workflow-',
        );
        await load();
      });

      tearDown(() async {
        await unload();
        for (final channel in channels) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        }
        channels.clear();
        for (var i = 0; i < 10; i++) {
          try {
            if (tempDir.existsSync()) {
              tempDir.deleteSync(recursive: true);
            }
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
      });

      testWidgets(
        '20m ago, 2h ago, 3d ago -> count is 2 -> acknowledge all -> restart shows 0',
        (tester) async {
          final now = DateTime.now();

          // 1. Add 3 reminders inside runAsync:
          await tester.runAsync(() async {
            final notifier = container.read(remindersProvider.notifier);
            await notifier.addReminder(
              Reminder(
                id: 'task-20m',
                taskTitle: 'Task 20 Minutes Ago',
                quadrantLevel: 1,
                triggerTime: now.subtract(const Duration(minutes: 20)),
              ),
            );
            await notifier.addReminder(
              Reminder(
                id: 'task-2h',
                taskTitle: 'Task 2 Hours Ago',
                quadrantLevel: 2,
                triggerTime: now.subtract(const Duration(hours: 2)),
              ),
            );
            await notifier.addReminder(
              Reminder(
                id: 'task-3d',
                taskTitle: 'Task 3 Days Ago',
                quadrantLevel: 3,
                triggerTime: now.subtract(const Duration(days: 3, minutes: 5)),
              ),
            );
          });

          // 2. Launch HomeScreen
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
                home: const HomeScreen(),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));

          // Expect "错过的提醒 · 2" in the MissedRemindersBar
          expect(
            find.byKey(const ValueKey('missed-reminders-bar')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('missed-reminders-bar')),
              matching: find.text('错过的提醒 · 2'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('workspace-view-missed')),
            findsOneWidget,
          );

          // 3. Click "错过的提醒 · 2" to filter by missed
          await tester.tap(
            find.byKey(const ValueKey('missed-reminders-title')),
          );
          await tester.pump(const Duration(milliseconds: 100));

          // Should see the 2 missed tasks in list, but NOT the 3-day-old one
          expect(
            find.descendant(
              of: find.byType(TaskWorkspaceOverview),
              matching: find.text('Task 20 Minutes Ago'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byType(TaskWorkspaceOverview),
              matching: find.text('Task 2 Hours Ago'),
            ),
            findsOneWidget,
          );
          expect(find.text('Task 3 Days Ago'), findsNothing);

          // 4. Click "全部知道了"
          await tester.runAsync(() async {
            final previous = reminders.lastAction;
            await tester.tap(
              find.byKey(const ValueKey('missed-reminders-acknowledge-all')),
            );
            for (var i = 0; i < 20; i++) {
              if (reminders.lastAction != null &&
                  reminders.lastAction != previous) {
                await reminders.lastAction;
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          });
          await tester.pump(const Duration(milliseconds: 100));

          // Bar disappears immediately
          expect(
            find.byKey(const ValueKey('missed-reminders-bar')),
            findsNothing,
          );
          expect(find.text('错过的提醒 · 2'), findsNothing);

          // 5. Restart app session: unload & reload database into fresh container
          addTearDown(() => drainWorkspaceDrafts(tester, container));
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await unload();
            await load();
          });

          // Launch HomeScreen again
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
                home: const HomeScreen(),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));

          // Expect 0 missed reminders: bar does not appear anymore!
          expect(
            find.byKey(const ValueKey('missed-reminders-bar')),
            findsNothing,
          );
          expect(find.text('错过的提醒 · 2'), findsNothing);
          expect(tester.takeException(), isNull);
          expect(find.text('错过的提醒 · 2'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'due notices and missed list stay disjoint, including older queued notices',
        (tester) async {
          addTearDown(() => drainWorkspaceDrafts(tester, container));
          final now = DateTime.now();
          final recent = Reminder(
            id: 'recent-due',
            taskTitle: 'Recent due only',
            quadrantLevel: 1,
            triggerTime: now.subtract(const Duration(minutes: 10)),
          );
          final queued = Reminder(
            id: 'queued-due',
            taskTitle: 'Older active notice only',
            quadrantLevel: 1,
            triggerTime: now.subtract(const Duration(hours: 1)),
          );
          final missed = Reminder(
            id: 'missed-only',
            taskTitle: 'Historical missed only',
            quadrantLevel: 1,
            triggerTime: now.subtract(const Duration(hours: 2)),
          );
          await tester.runAsync(() async {
            for (final task in [recent, queued, missed]) {
              await reminders.addReminder(task);
            }
          });
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: _buildTestApp(
                language: 'zh',
                child: const InlineFeedback(child: HomeScreen()),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          // Model a due event retained in this session beyond the 15m window.
          await tester.runAsync(() => notifications.fireReminderNow(queued));
          await tester.pump(const Duration(milliseconds: 100));

          final panel = tester.widget<ReminderNoticePanel>(
            find.byType(ReminderNoticePanel),
          );
          expect(panel.reminders.map((r) => r.id), [queued.id, recent.id]);
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('missed-reminders-bar')),
              matching: find.text('错过的提醒 · 1'),
            ),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('missed-reminders-title')),
          );
          await tester.pump(const Duration(milliseconds: 100));
          final workspace = find.byType(TaskWorkspaceOverview);
          expect(
            find.descendant(
              of: workspace,
              matching: find.text(missed.taskTitle),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: workspace,
              matching: find.text(recent.taskTitle),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: workspace,
              matching: find.text(queued.taskTitle),
            ),
            findsNothing,
          );

          await tester.runAsync(() async {
            await tester.tap(
              find.byKey(const ValueKey('missed-reminders-acknowledge-all')),
            );
            await reminders.lastAction;
          });
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(MissedRemindersBar), findsOneWidget);
          expect(
            find.byKey(const ValueKey('missed-reminders-bar')),
            findsNothing,
          );
          final saved = container.read(remindersProvider);
          expect(
            saved.singleWhere((r) => r.id == missed.id).noticeAcknowledgedAt,
            isNotNull,
          );
          expect(
            saved.singleWhere((r) => r.id == recent.id).noticeAcknowledgedAt,
            isNull,
          );
          expect(
            saved.singleWhere((r) => r.id == queued.id).noticeAcknowledgedAt,
            isNull,
          );
          expect(
            tester
                .widget<ReminderNoticePanel>(find.byType(ReminderNoticePanel))
                .reminders,
            hasLength(2),
          );
          expect(tester.takeException(), isNull);
        },
      );
    },
  );
}
