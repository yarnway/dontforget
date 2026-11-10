import 'dart:io';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'dart:convert';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/study_plan_group.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';

Reminder batch(
  String id, {
  String plan = 'p',
  bool paused = false,
  bool completed = false,
  DateTime? archived,
  DateTime? deleted,
}) => Reminder(
  id: id,
  taskTitle: 'Batch $id',
  quadrantLevel: 2,
  taskSummary: 'apple — fruit\nAn apple a day.',
  triggerTime: DateTime(2030, 1, 8, 8),
  nextReviewAt: DateTime(2030, 1, 8, 8),
  spacedRepetitionLevel: 1,
  reviewNotificationsEnabled: true,
  isCompleted: completed,
  wordProgressJson: jsonEncode({
    'apple': {
      'level': 1,
      'due': '2030-01-08T08:00:00.000',
      'reviewed': '2026-11-01T08:00:00.000',
      'first': '2026-11-01T08:00:00.000',
      'reviews': 1,
      'grade': 1,
    },
  }),
  detailsJson: TaskDetails(
    kind: 'study',
    paused: paused,
    archivedAt: archived,
    deletedAt: deleted,
    data: {'study_plan_id': plan, 'batch': 0},
  ).encode(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  Future<StudyPlanGroup> group() async =>
      StudyPlanGroup.project(await h.rows()).singleWhere((g) => g.id == 'p');
  Future<String> saved() async =>
      jsonEncode((await h.rows()).map((r) => r.toJson()).toList());
  Future<void> seed() async {
    await h.seed(batch('p-0'));
    await h.seed(batch('p-1'));
    await h.seed(batch('q-0', plan: 'q'));
    h.notifications.scheduled.clear();
    h.notifications.cancelled.clear();
  }

  test(
    'pause and resume a whole plan preserve progress, dates and other plans across reopen',
    () async {
      await seed();
      await h.seed(batch('p-done', completed: true));
      await h.seed(batch('p-archived', archived: DateTime(2026, 11, 1)));
      await h.seed(batch('p-deleted', deleted: DateTime(2026, 11, 1)));
      final originals = {for (final r in await h.rows()) r.id: r};
      final gen = h.database.captureGeneration();
      h.notifications.cancelled.clear();
      h.notifications.scheduled.clear();
      final pause = await h.notifier.changeStudyPlan(
        await group(),
        'pause',
        gen,
      );
      expect(pause.changed, 2);
      expect(pause.nativeSyncFailures, 0);
      expect(h.notifications.cancelled, unorderedEquals(['p-0', 'p-1']));
      for (final id in ['p-0', 'p-1']) {
        final row = await h.row(id);
        expect(row.details.paused, true);
        expect(row.wordProgressJson, originals[id]!.wordProgressJson);
        expect(row.nextReviewAt, originals[id]!.nextReviewAt);
      }
      for (final id in ['q-0', 'p-done', 'p-archived', 'p-deleted']) {
        expect((await h.row(id)).toJson(), originals[id]!.toJson());
      }
      final again = await h.notifier.changeStudyPlan(
        await group(),
        'pause',
        gen,
      );
      expect(again.changed, 0);
      await h.close();
      await h.open();
      expect((await group()).canResume, true);
      final resume = await h.notifier.changeStudyPlan(
        await group(),
        'resume',
        h.database.captureGeneration(),
      );
      expect(resume.changed, 2);
      expect(h.notifications.scheduled, unorderedEquals(['p-0', 'p-1']));
      expect((await h.row('p-0')).details.paused, false);
      expect(
        (await h.row('p-0')).wordProgressJson,
        originals['p-0']!.wordProgressJson,
      );
    },
  );

  test(
    'trash includes completed and archived batches but retains prior trash, media refs and word history',
    () async {
      await seed();
      await h.seed(batch('p-done', completed: true));
      await h.seed(batch('p-archived', archived: DateTime(2026, 11, 1)));
      await h.seed(batch('p-deleted', deleted: DateTime(2026, 11, 1)));
      final oldDeleted = (await h.row('p-deleted')).toJson();
      final progress = (await h.row('p-0')).wordProgressJson;
      final at = DateTime(2026, 11, 10);
      final result = await h.notifier.changeStudyPlan(
        await group(),
        'trash',
        h.database.captureGeneration(),
        now: at,
      );
      expect(result.changed, 4);
      for (final id in ['p-0', 'p-1', 'p-done', 'p-archived']) {
        expect((await h.row(id)).details.deletedAt, at);
        expect((await h.row(id)).wordProgressJson, progress);
      }
      expect((await h.row('p-deleted')).toJson(), oldDeleted);
      expect((await h.row('q-0')).details.deletedAt, isNull);
      expect(StudyPlanGroup.project(await h.rows()).map((g) => g.id), ['q']);
      expect((await h.rows()).length, 6);
    },
  );

  for (final change in ['add', 'edit', 'move', 'remove']) {
    test(
      'concurrent $change invalidates the entire plan snapshot without partial writes',
      () async {
        await seed();
        final expected = await group();
        final gen = h.database.captureGeneration();
        await h.database.writeTransaction(gen, (db) async {
          if (change == 'add') {
            await db.insert('Reminders', batch('p-2').toJson());
          }
          if (change == 'edit') {
            await db.update(
              'Reminders',
              {'task_title': 'Changed elsewhere'},
              where: 'id = ?',
              whereArgs: ['p-1'],
            );
          }
          if (change == 'move') {
            await db.update(
              'Reminders',
              {'details_json': batch('p-1', plan: 'q').detailsJson},
              where: 'id = ?',
              whereArgs: ['p-1'],
            );
          }
          if (change == 'remove') {
            await db.delete('Reminders', where: 'id = ?', whereArgs: ['p-1']);
          }
        });
        final before = await saved();
        await expectLater(
          h.notifier.changeStudyPlan(expected, 'pause', gen),
          throwsA(isA<StaleReminderOccurrenceException>()),
        );
        expect(await saved(), before);
        expect(h.notifications.cancelled, isEmpty);
      },
    );
  }

  test(
    'a failed second write rolls back the first and sends no native changes',
    () async {
      await seed();
      final before = await saved();
      await (await h.database.database).execute(
        "CREATE TRIGGER fail_study BEFORE UPDATE ON Reminders WHEN NEW.id = 'p-1' BEGIN SELECT RAISE(ABORT, 'Synthetic write failure'); END",
      );
      await expectLater(
        h.notifier.changeStudyPlan(
          await group(),
          'pause',
          h.database.captureGeneration(),
        ),
        throwsA(isA<Exception>()),
      );
      expect(await saved(), before);
      expect(h.notifications.cancelled, isEmpty);
      expect(h.notifier.state.any((r) => r.details.paused), false);
    },
  );

  test(
    'native failure reports a committed plan instead of losing its state',
    () async {
      await seed();
      h.notifications.fail = true;
      final result = await h.notifier.changeStudyPlan(
        await group(),
        'pause',
        h.database.captureGeneration(),
      );
      expect(result.changed, 2);
      expect(result.nativeSyncFailures, 2);
      expect((await h.row('p-0')).details.paused, true);
      expect((await h.row('p-1')).details.paused, true);
    },
  );

  test('recovery invalidates prior plan selections', () async {
    await seed();
    final expected = await group();
    final gen = h.database.captureGeneration();
    final before = await saved();
    final lease = await h.database.beginMaintenance();
    await lease.resume();
    await expectLater(
      h.notifier.changeStudyPlan(expected, 'trash', gen),
      throwsA(isA<DatabaseAccessException>()),
    );
    expect(await saved(), before);
  });

  test(
    'partial or mixed plan snapshots cannot become whole-plan actions',
    () async {
      await seed();
      final gen = h.database.captureGeneration();
      final before = await saved();
      await expectLater(
        h.notifier.changeStudyPlan(
          StudyPlanGroup('p', [await h.row('p-0')]),
          'trash',
          gen,
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      expect(
        () => h.notifier.changeStudyPlan(
          StudyPlanGroup('p', [batch('wrong', plan: 'q')]),
          'trash',
          gen,
        ),
        throwsFormatException,
      );
      expect(await saved(), before);
    },
  );

  test(
    'trash preserves attached original bytes and their media records',
    () async {
      await seed();
      final gen = h.database.captureGeneration();
      final file = await File(
        '${h.directory.path}/original-audio.wav',
      ).writeAsBytes([1, 2, 3, 4]);
      final media = MediaRecord(
        id: 'audio',
        type: 'audio',
        contentOrPath: file.path,
        createdAt: DateTime(2026, 11, 1),
      );
      final old = await h.row('p-0');
      final attached = old.copyWith(
        recordId: 'audio',
        detailsJson: old.details.patch({
          'attachment_ids': ['audio'],
        }).encode(),
      );
      await h.database.writeTransaction(gen, (db) async {
        await db.insert('MediaRecords', media.toJson());
        await db.update(
          'Reminders',
          attached.toJson(),
          where: 'id = ?',
          whereArgs: [old.id],
        );
      });
      await h.notifier.changeStudyPlan(await group(), 'trash', gen);
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      final records = await h.database.read(
        gen,
        (db) => db.query('MediaRecords'),
      );
      expect(records.single, media.toJson());
      expect((await h.row('p-0')).recordId, 'audio');
      expect((await h.row('p-0')).details.attachmentIds, ['audio']);
    },
  );

  test(
    'resuming a manually recurring study batch preserves its original review dates',
    () async {
      final old = DateTime(2026, 1, 8, 8);
      await h.seed(
        batch('p-0').copyWith(
          isRecurring: true,
          recurrenceRule: 'daily',
          triggerTime: old,
          nextReviewAt: old,
        ),
      );
      final gen = h.database.captureGeneration();
      await h.notifier.changeStudyPlan(await group(), 'pause', gen);
      h.notifications.scheduled.clear();
      h.notifications.cancelled.clear();
      await h.notifier.changeStudyPlan(await group(), 'resume', gen);
      final row = await h.row('p-0');
      expect(row.triggerTime, old);
      expect(row.nextReviewAt, old);
      expect(row.isCompleted, false);
      expect(h.notifications.scheduled, isEmpty);
      expect(h.notifications.cancelled, ['p-0']);
    },
  );

  test(
    'paused plans leave the learning queue without resetting shared word history',
    () async {
      await h.seed(batch('p-0'));
      await h.seed(batch('p-1'));
      final at = DateTime(2030, 1, 8, 12);
      expect(
        LearningQueueService.queue(h.notifier.state, now: at).items,
        isNotEmpty,
      );
      final progress = (await h.row('p-0')).wordProgressJson;
      await h.notifier.changeStudyPlan(
        await group(),
        'pause',
        h.database.captureGeneration(),
      );
      expect(
        LearningQueueService.queue(h.notifier.state, now: at).items,
        isEmpty,
      );
      expect((await h.row('p-0')).wordProgressJson, progress);
      await h.notifier.changeStudyPlan(
        await group(),
        'resume',
        h.database.captureGeneration(),
      );
      expect(
        LearningQueueService.queue(h.notifier.state, now: at).items,
        isNotEmpty,
      );
      expect((await h.row('p-0')).nextReviewAt, DateTime(2030, 1, 8, 8));
    },
  );

  test(
    'unexpected children cannot be cascaded through a study group action',
    () async {
      await seed();
      await h.seed(
        Reminder(
          id: 'child',
          taskTitle: 'Unrelated child',
          quadrantLevel: 2,
          detailsJson: const TaskDetails(planId: 'p-0').encode(),
        ),
      );
      final before = await saved();
      await expectLater(
        h.notifier.changeStudyPlan(
          await group(),
          'trash',
          h.database.captureGeneration(),
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      expect(await saved(), before);
    },
  );
}
