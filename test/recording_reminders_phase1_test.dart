import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/quick_reminder_parser.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/study_plan.dart';
import 'package:dont_forget/ui/widgets/study_plan_panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  final scheduled = <Reminder>[];
  bool fail = false;
  @override
  Future<void> scheduleReminderStrict(Reminder task) async {
    if (fail) throw StateError('Synthetic OS failure');
    scheduled.add(task);
  }

  @override
  Future<void> cancelReminderStrict(String id) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Model extends LLMService {
  final requests = <Completer<List<Reminder>>>[];
  @override
  Future<List<Reminder>> extractTasks(String text, settings) {
    final request = Completer<List<Reminder>>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Notifications notifications;
  late _Model model;
  const recorder = MethodChannel('com.llfbandit.record/messages');

  Future<void> load() async {
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = _Notifications();
    model = _Model();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        llmServiceProvider.overrideWithValue(model),
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
  }

  Future<void> unload() async {
    await container.read(workspaceDraftsProvider.notifier).flushed;
    container.dispose();
    model.dispose();
    await database.close(createBackup: false);
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    sqfliteFfiInit();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorder, (_) async => null);
    directory = await Directory.systemTemp.createTemp('dontforget-phase1-');
    await load();
  });
  tearDown(() async {
    await unload();
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorder, null);
  });

  test('offline dates, relative times and ambiguous memos', () {
    final now = DateTime(2026, 10, 27, 12);
    expect(
      QuickReminderParser.parse('10分钟后交材料', now: now),
      now.add(const Duration(minutes: 10)),
    );
    expect(
      QuickReminderParser.parse('in 2 hours call', now: now),
      now.add(const Duration(hours: 2)),
    );
    expect(
      QuickReminderParser.parse('明天下午3点半开会', now: now),
      DateTime(2026, 10, 28, 15, 30),
    );
    expect(
      QuickReminderParser.parse('tomorrow 9 am call', now: now),
      DateTime(2026, 10, 28, 9),
    );
    expect(
      QuickReminderParser.parse('明日9時に会議', now: now),
      DateTime(2026, 10, 28, 9),
    );
    for (final text in ['买牛奶', '项目需要10分钟', '明天讨论', '今天9点开会', '明天25:00开会']) {
      expect(QuickReminderParser.parse(text, now: now), isNull, reason: text);
    }
    expect(
      QuickReminderParser.tomorrowMorning(DateTime(2026, 12, 31, 23)),
      DateTime(2027, 1, 1, 9),
    );
  });

  test(
    'offline capture schedules explicit time and leaves a memo unscheduled',
    () async {
      final home = container.read(homeControllerProvider.notifier);
      expect(await home.processText('10分钟后取快递'), isTrue);
      expect(await home.processText('读一本书'), isTrue);
      expect(await home.processText('10分钟后只是记录', memoOnly: true), isTrue);
      final tasks = container.read(remindersProvider);
      expect(tasks.length, 3);
      expect(tasks.first.triggerTime, isNotNull);
      expect(tasks.skip(1).every((r) => r.triggerTime == null), isTrue);
      expect(model.requests, isEmpty);
      expect(tasks.every((r) => r.sourceText != null), isTrue);
    },
  );

  test(
    'raw capture is durable before model returns; retry does not duplicate',
    () async {
      await container
          .read(settingsProvider.notifier)
          .updateSettings(
            container
                .read(settingsProvider)
                .copyWith(apiKey: 'synthetic-fixture'),
          );
      final home = container.read(homeControllerProvider.notifier);
      expect(
        await home.processText('明天9点开会', captureId: 'stable-capture'),
        isTrue,
      );
      await until(() => model.requests.isNotEmpty);
      final raw = (await database.read(
        database.captureGeneration(),
        (db) => db.query('Reminders'),
      )).single;
      expect(raw['source_text'], '明天9点开会');
      expect(raw['capture_pending'], 1);
      model.requests.single.completeError(StateError('Synthetic timeout'));
      await until(() => !home.state.isProcessingInBackground);
      expect(container.read(remindersProvider).length, 1);
      expect(
        await home.processText('明天9点开会', captureId: 'stable-capture'),
        isTrue,
      );
      expect(container.read(remindersProvider).length, 1);
      home.retryCapture(container.read(remindersProvider).single);
      await until(() => model.requests.length == 2);
      final event = container.read(remindersProvider).single.eventTime!;
      model.requests.last.complete([
        Reminder(
          id: 'model-id',
          taskTitle: '开会',
          quadrantLevel: 2,
          eventTime: event,
          triggerTime: event.subtract(const Duration(minutes: 15)),
        ),
      ]);
      await until(() => !home.state.isProcessingInBackground);
      final saved = container.read(remindersProvider).single;
      expect(saved.id, 'stable-capture');
      expect(saved.taskTitle, '明天9点开会');
      expect(saved.triggerTime, event);
      expect(saved.eventTime, event);
      expect(saved.captureProposalJson, isNotNull);
      final proposal = (jsonDecode(saved.captureProposalJson!) as List)
          .map(
            (row) => Reminder.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList();
      await container
          .read(remindersProvider.notifier)
          .applyCaptureProposal(saved, proposal);
      final confirmed = container.read(remindersProvider).single;
      expect(confirmed.taskTitle, '开会');
      expect(
        confirmed.triggerTime,
        event.subtract(const Duration(minutes: 15)),
      );
      expect(confirmed.captureProposalJson, isNull);
      await expectLater(
        container
            .read(remindersProvider.notifier)
            .applyCaptureProposal(saved, proposal),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      expect(saved.capturePending, isFalse);
      expect(saved.sourceText, '明天9点开会');
    },
  );

  test('user edits and deletion win over late AI results', () async {
    await container
        .read(settingsProvider.notifier)
        .updateSettings(
          container
              .read(settingsProvider)
              .copyWith(apiKey: 'synthetic-fixture'),
        );
    final home = container.read(homeControllerProvider.notifier);
    await home.processText('original');
    await until(() => model.requests.isNotEmpty);
    final raw = container.read(remindersProvider).single;
    await container
        .read(remindersProvider.notifier)
        .updateReminder(raw.copyWith(taskTitle: 'User title'), baseline: raw);
    model.requests.single.complete([
      Reminder(id: 'model', taskTitle: 'Late title', quadrantLevel: 1),
    ]);
    await until(() => !home.state.isProcessingInBackground);
    expect(container.read(remindersProvider).single.taskTitle, 'User title');
    await home.processText('second');
    await until(() => model.requests.length == 2);
    final second = container.read(remindersProvider).last;
    await container.read(remindersProvider.notifier).deleteReminder(second.id);
    model.requests.last.complete([
      Reminder(id: 'model', taskTitle: 'Resurrection', quadrantLevel: 1),
    ]);
    await until(() => !home.state.isProcessingInBackground);
    expect(container.read(remindersProvider).length, 1);
  });

  test(
    'drafts survive restart and settings writes; old generation cannot write',
    () async {
      final store = container.read(workspaceDraftsProvider.notifier);
      await store.put('capture', {'text': 'unsent text', 'id': 'draft-id'});
      await store.put('homeView', 'future');
      await container
          .read(settingsProvider.notifier)
          .updateSettings(
            container.read(settingsProvider).copyWith(language: 'en'),
          );
      await unload();
      await load();
      final reloaded = container.read(workspaceDraftsProvider.notifier);
      await reloaded.ready;
      expect(
        container.read(workspaceDraftsProvider)['capture']['text'],
        'unsent text',
      );
      expect(container.read(workspaceDraftsProvider)['homeView'], 'future');
      final lease = await database.beginMaintenance();
      await expectLater(
        reloaded.put('capture', {'text': 'stale'}),
        throwsA(isA<DatabaseAccessException>()),
      );
      await lease.validateAndOpen();
      await lease.resume();
      final raw = (await database.read(
        database.captureGeneration(),
        (db) => db.query('Settings'),
      )).single;
      expect(
        jsonDecode(raw['workspace_drafts_json'] as String)['capture']['text'],
        'unsent text',
      );
    },
  );

  test(
    'pin limit, arbitrary snooze and recurring skip preserve event time',
    () async {
      final notifier = container.read(remindersProvider.notifier);
      final now = DateTime.now();
      for (var i = 0; i < 4; i++) {
        await notifier.addReminder(
          Reminder(id: 'pin-$i', taskTitle: 'Task $i', quadrantLevel: 2),
        );
      }
      for (final task in container.read(remindersProvider).take(3).toList()) {
        await notifier.updateReminder(
          task.copyWith(isPinned: true),
          baseline: task,
        );
      }
      final fourth = container.read(remindersProvider).last;
      await expectLater(
        notifier.updateReminder(
          fourth.copyWith(isPinned: true),
          baseline: fourth,
        ),
        throwsA(isA<PinLimitException>()),
      );
      final trigger = now.subtract(const Duration(minutes: 1));
      final event = now.add(const Duration(minutes: 14));
      final recurring = Reminder(
        id: 'recurring',
        taskTitle: 'Daily',
        quadrantLevel: 2,
        triggerTime: trigger,
        eventTime: event,
        isRecurring: true,
        recurrenceRule: 'daily',
      );
      await notifier.addReminder(recurring);
      final snoozed = (await notifier.snoozeOccurrence(
        recurring,
        now: now,
        duration: const Duration(hours: 1),
      )).reminder!;
      expect(snoozed.triggerTime, now.add(const Duration(hours: 1)));
      expect(snoozed.eventTime, event);
      final skipped = (await notifier.skipOccurrence(
        snoozed,
        now: now,
      )).reminder!;
      expect(skipped.isCompleted, isFalse);
      expect(skipped.triggerTime!.hour, trigger.hour);
      expect(skipped.eventTime!.hour, event.hour);
      expect(
        (await notifier.skipOccurrence(snoozed, now: now)).disposition,
        ReminderActionDisposition.stale,
      );
    },
  );

  test(
    'current backup preview retains original text, times and drafts',
    () async {
      final draft = container.read(workspaceDraftsProvider.notifier);
      await draft.put('capture', {'text': 'draft'});
      await container
          .read(homeControllerProvider.notifier)
          .processText('明天9点复习');
      await database.createMirrorBackup();
      final preview = await BackupInspector(
        databaseFactoryFfi,
      ).inspect(File('${directory.path}/ha_snapshot.json'));
      expect(preview.version, DatabaseHelper.schemaVersion);
    },
  );

  test('model leaves untimed text without a fabricated notification', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode({
                        'tasks': [
                          {
                            'title': 'Memo',
                            'quadrant': 2,
                            'event_time': null,
                            'time': '2099-01-01 20:00',
                          },
                        ],
                      }),
                    },
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final service = LLMService(client: dio);
    try {
      final result = await service.extractTasks(
        '读一本书',
        container.read(settingsProvider).copyWith(apiKey: 'synthetic-fixture'),
      );
      expect(result.single.triggerTime, isNull);
      expect(result.single.eventTime, isNull);
    } finally {
      service.dispose();
      dio.close();
    }
  });

  test('monthly event and reminder anchors survive a short month', () async {
    final notifier = container.read(remindersProvider.notifier);
    final first = Reminder(
      id: 'monthly',
      taskTitle: 'Monthly meeting',
      quadrantLevel: 2,
      isRecurring: true,
      recurrenceRule: 'monthly',
      triggerTime: DateTime(2032, 1, 31, 8, 45),
      eventTime: DateTime(2032, 1, 31, 9),
    );
    await notifier.addReminder(first);
    final february = (await notifier.completeOccurrence(
      first,
      now: first.triggerTime,
    )).reminder!;
    expect(february.triggerTime, DateTime(2032, 2, 29, 8, 45));
    expect(february.eventTime, DateTime(2032, 2, 29, 9));
    final march = (await notifier.skipOccurrence(
      february,
      now: february.triggerTime,
    )).reminder!;
    expect(march.triggerTime, DateTime(2032, 3, 31, 8, 45));
    expect(march.eventTime, DateTime(2032, 3, 31, 9));
  });

  test(
    'v13 upgrades preserve each old field and an inspectable rollback snapshot',
    () async {
      final legacyDirectory = await Directory(
        '${directory.path}/legacy',
      ).create();
      final file = File('${legacyDirectory.path}/dont_forget_v3.db');
      final db = await databaseFactoryFfi.openDatabase(file.path);
      final schema = (await File('test/fixtures/schema_v13.sql').readAsString())
          .split('\n')
          .where((line) => !line.startsWith('--'))
          .join('\n');
      for (final sql in schema.split(';')) {
        if (sql.trim().isNotEmpty) await db.execute(sql);
      }
      await db.insert(
        'Settings',
        AppSettings.defaults().toJson()..remove('workspace_drafts_json'),
      );
      await db.insert('Reminders', {
        'id': 'old',
        'task_title': 'Historical task',
        'quadrant_level': 2,
        'is_completed': 0,
        'trigger_time': '2032-01-31T09:00:00',
        'notice_revision': 8,
      });
      final before = (await db.query('Reminders')).single;
      await db.setVersion(13);
      await db.close();
      final helper = DatabaseHelper.forTesting(
        legacyDirectory.path,
        databaseFactoryFfi,
      );
      try {
        final upgraded = await helper.database;
        expect(await upgraded.getVersion(), DatabaseHelper.schemaVersion);
        final after = (await upgraded.query('Reminders')).single;
        for (final entry in before.entries) {
          expect(after[entry.key], entry.value, reason: entry.key);
        }
        expect(after['event_time'], isNull);
        expect(after['capture_pending'], 0);
        final snapshots = legacyDirectory
            .listSync()
            .whereType<Directory>()
            .where(
              (d) => d.path.contains(
                'schema-upgrade-v13-to-v${DatabaseHelper.schemaVersion}-',
              ),
            );
        final snapshot = File('${snapshots.single.path}/snapshot.json');
        final inspector = BackupInspector(databaseFactoryFfi);
        expect((await inspector.inspect(snapshot)).version, 13);
        await helper.createMirrorBackup();
        expect(
          (await inspector.inspect(
            File('${legacyDirectory.path}/ha_snapshot.json'),
          )).version,
          DatabaseHelper.schemaVersion,
        );
      } finally {
        await helper.close(createBackup: false);
      }
    },
  );

  test(
    'learning draft resumes edits with the same plan identity and fresh generation',
    () async {
      final plan = StudyPlan(
        batches: [
          const StudyBatch(title: 'Words', content: 'Vocabulary notes'),
        ],
      );
      final draft = StudyPlanDraft()
        ..plan = plan
        ..days = 1
        ..words = 5
        ..edited = [const StudyBatch(title: '', content: 'Unfinished edit')]
        ..firstReminder = DateTime(2032, 1, 1, 20);
      final store = container.read(workspaceDraftsProvider.notifier);
      await store.put('study', draft.toJson());
      await unload();
      await load();
      await container.read(workspaceDraftsProvider.notifier).ready;
      final restored = StudyPlanDraft();
      restored.restore(
        container.read(workspaceDraftsProvider)['study'] as Map,
        database.captureGeneration(),
      );
      expect(restored.plan!.id, plan.id);
      expect(restored.edited.single.title, '');
      expect(restored.edited.single.content, 'Unfinished edit');
      expect(restored.busy, isFalse);
      expect(restored.saved, isFalse);
      expect(database.isCurrent(restored.generation!), isTrue);
      draft.dispose();
      restored.dispose();
    },
  );
  Reminder vocabulary(String id, List<String> words) => Reminder(
    id: id,
    taskTitle: id,
    quadrantLevel: 2,
    spacedRepetitionLevel: 1,
    nextReviewAt: DateTime(2026, 1, 1, 20),
    taskSummary: words
        .map((word) => '$word — Meaning of $word\nAn example with $word.')
        .join('\n\n'),
  );

  test(
    'learning queue prioritizes reviews, deduplicates and caps new words',
    () {
      final now = DateTime(2026, 10, 27, 10);
      final progress = WordProgress(
        level: 0,
        due: now.subtract(const Duration(days: 1)),
        reviewed: now.subtract(const Duration(days: 2)),
        firstReviewed: now.subtract(const Duration(days: 2)),
        reviews: 1,
        grade: 0,
      );
      final tasks = [
        vocabulary('one', [
          'weak',
          'new-a',
          'new-b',
          'new-c',
          'new-d',
        ]).copyWith(wordProgressJson: jsonEncode({'weak': progress.toJson()})),
        vocabulary('two', ['weak', 'new-a']),
      ];
      final queue = LearningQueueService.queue(
        tasks,
        dailyLimit: 3,
        newLimit: 1,
        now: now,
      );
      expect(queue.items.map((item) => item.key), ['weak', 'new-a']);
      expect(queue.dueCount, 5);
      expect(queue.deferred, 3);
    },
  );

  test(
    'word grading is independent, durable and protects daily allowance',
    () async {
      final notifier = container.read(remindersProvider.notifier);
      final batch = vocabulary('words', ['alpha', 'beta', 'gamma']);
      await notifier.addReminder(batch);
      final now = DateTime(2026, 10, 27, 10);
      await notifier.gradeWord(
        batch,
        'alpha',
        2,
        now: now,
        dailyLimit: 1,
        newLimit: 1,
      );
      final saved = container.read(remindersProvider).single;
      final progress = LearningQueueService.decode(saved.wordProgressJson);
      expect(progress.keys, ['alpha']);
      expect(progress['alpha']!.level, 1);
      expect(progress['alpha']!.due, DateTime(2026, 10, 28, 20));
      expect(saved.isCompleted, isFalse);
      final queue = LearningQueueService.queue(
        [saved],
        dailyLimit: 1,
        newLimit: 1,
        now: now,
      );
      expect(queue.completedToday, 1);
      expect(queue.items, isEmpty);
      expect(queue.deferred, 2);
      await expectLater(
        notifier.gradeWord(
          saved,
          'beta',
          2,
          now: now,
          dailyLimit: 1,
          newLimit: 1,
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      await unload();
      await load();
      expect(
        LearningQueueService.decode(
          container.read(remindersProvider).single.wordProgressJson,
        )['alpha']!.level,
        1,
      );
    },
  );

  test(
    'duplicate vocabulary shares mastery and fuzzy feedback keeps other words',
    () async {
      final notifier = container.read(remindersProvider.notifier);
      await notifier.addReminder(vocabulary('first', ['alpha', 'beta']));
      await notifier.addReminder(vocabulary('second', ['alpha', 'delta']));
      final now = DateTime(2026, 10, 27, 10);
      await notifier.gradeWord(
        container.read(remindersProvider).first,
        'alpha',
        0,
        now: now,
      );
      for (final task in container.read(remindersProvider)) {
        expect(
          LearningQueueService.decode(task.wordProgressJson)['alpha']!.grade,
          0,
        );
      }
      expect(
        LearningQueueService.queue(
          container.read(remindersProvider),
          now: now,
        ).completedToday,
        1,
      );
      await expectLater(
        notifier.gradeWord(
          container.read(remindersProvider).first,
          'alpha',
          2,
          now: now,
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      await notifier.gradeWord(
        container.read(remindersProvider).first,
        'alpha',
        1,
        now: now.add(const Duration(days: 1)),
      );
      final progress = LearningQueueService.decode(
        container.read(remindersProvider).first.wordProgressJson,
      );
      expect(progress['alpha']!.reviews, 2);
      expect(progress['alpha']!.level, 0);
      expect(progress.containsKey('beta'), isFalse);
      await database.createMirrorBackup();
      expect(
        (await BackupInspector(
          databaseFactoryFfi,
        ).inspect(File('${directory.path}/ha_snapshot.json'))).version,
        DatabaseHelper.schemaVersion,
      );
    },
  );
  test(
    'disposed capture retry cannot read a rebuilt provider or send another request',
    () async {
      final home = container.read(homeControllerProvider.notifier);
      final old = Reminder(
        id: 'old',
        taskTitle: 'Old source',
        sourceText: 'Old source',
        quadrantLevel: 2,
        capturePending: true,
      );
      await unload();
      await load();
      expect(() => home.retryCapture(old), returnsNormally);
      expect(model.requests, isEmpty);
      expect(container.read(remindersProvider), isEmpty);
    },
  );

  test(
    'AI preview and word grading reject an editor ticket from before maintenance',
    () async {
      final notifier = container.read(remindersProvider.notifier);
      final candidate = Reminder(
        id: 'model',
        taskTitle: 'Proposed',
        quadrantLevel: 2,
      );
      final raw = Reminder(
        id: 'raw',
        taskTitle: 'Original',
        sourceText: 'Original',
        quadrantLevel: 2,
        captureProposalJson: jsonEncode([candidate.toJson()]),
      );
      final words = vocabulary('words', ['alpha']);
      await notifier.addReminder(raw);
      await notifier.addReminder(words);
      final oldTicket = database.captureGeneration();
      final before = await database.read(
        oldTicket,
        (db) => db.query('Reminders', orderBy: 'id'),
      );
      final lease = await database.beginMaintenance();
      await lease.validateAndOpen();
      await lease.resume();
      await expectLater(
        notifier.applyCaptureProposal(raw, [candidate], generation: oldTicket),
        throwsA(isA<DatabaseAccessException>()),
      );
      await expectLater(
        notifier.gradeWord(words, 'alpha', 2, generation: oldTicket),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(
        await database.read(
          database.captureGeneration(),
          (db) => db.query('Reminders', orderBy: 'id'),
        ),
        before,
      );
      expect(notifications.scheduled, isEmpty);
    },
  );
}
