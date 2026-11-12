import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/study_plan_group.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'package:dont_forget/services/learning_workload_service.dart';
import 'package:dont_forget/services/portable_backup_service.dart';
import 'package:dont_forget/services/study_schedule_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'study_plan_management_test.dart' show batch;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  final at = DateTime(2026, 11, 12, 12);
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  Future<StudySchedulePreview> preview(int days, {List<String>? plans}) async {
    final all = await h.rows();
    return StudyScheduleService.preview(
      all,
      StudyPlanGroup.project(
        all,
      ).where((g) => plans == null || plans.contains(g.id)).toList(),
      days,
      now: at,
    );
  }

  Future<String> saved() async =>
      jsonEncode((await h.rows()).map((r) => r.toJson()).toList());
  Future<void> commit(StudySchedulePreview p) async {
    await h.notifier.shiftStudyPlanDates(p, h.database.captureGeneration());
  }

  Future<void> seed() async {
    await h.seed(batch('p-0'));
    await h.seed(batch('p-1', paused: true));
    await h.seed(batch('q-0', plan: 'q'));
    h.notifications.cancelled.clear();
    h.notifications.scheduled.clear();
  }

  test(
    'preview is read-only; shared progress shifts once and survives reopen, with media and mastery intact',
    () async {
      await seed();
      for (final row in [
        batch('done', completed: true),
        batch('archive', archived: at),
        batch('trash', deleted: at),
        batch(
          'control',
          plan: 'control',
        ).copyWith(taskSummary: 'banana', wordProgressJson: null),
      ]) {
        await h.seed(row);
      }
      final file = await File(
        '${h.directory.path}/original.wav',
      ).writeAsBytes([1, 5, 9]);
      final media = MediaRecord(
        id: 'audio',
        type: 'audio',
        contentOrPath: file.path,
        createdAt: at,
      );
      await h.database.writeTransaction(h.database.captureGeneration(), (
        db,
      ) async {
        await db.insert('MediaRecords', media.toJson());
        await db.update(
          'Reminders',
          {'record_id': 'audio'},
          where: 'id = ?',
          whereArgs: ['p-0'],
        );
      });
      final originals = {for (final r in await h.rows()) r.id: r};
      final before = await saved();
      final p = await preview(7, plans: ['p', 'q']);
      expect(await saved(), before);
      expect(p.changes.length, 3);
      await commit(p);
      await h.close();
      await h.open();
      for (final id in ['p-0', 'p-1', 'q-0']) {
        final r = await h.row(id), old = originals[id]!;
        expect(r.nextReviewAt, DateTime(2030, 1, 15, 8));
        expect(r.triggerTime, DateTime(2030, 1, 15, 8));
        expect(r.details.paused, old.details.paused);
        expect(r.reviewNotificationsEnabled, old.reviewNotificationsEnabled);
        expect(r.recordId, old.recordId);
        expect(r.noticeRevision, old.noticeRevision + 1);
        final progress = LearningQueueService.decode(
          r.wordProgressJson,
        )['apple']!;
        final original = LearningQueueService.decode(
          old.wordProgressJson,
        )['apple']!;
        expect(progress.due, DateTime(2030, 1, 15, 8));
        expect(progress.rescheduledAt, at);
        expect(
          {...progress.toJson()}
            ..remove('due')
            ..remove('rescheduled'),
          {...original.toJson()}..remove('due'),
        );
      }
      for (final id in ['done', 'archive', 'trash', 'control']) {
        expect((await h.row(id)).toJson(), originals[id]!.toJson());
      }
      expect(await file.readAsBytes(), [1, 5, 9]);
      expect(
        await h.database.read(
          h.database.captureGeneration(),
          (db) => db.query('MediaRecords'),
        ),
        [media.toJson()],
      );
      expect(
        LearningQueueService.progress((await h.rows()).reversed)['apple']!.due,
        DateTime(2030, 1, 15, 8),
      );
      final bundle = await const PortableBackupService().create(
        h.database,
        h.database.captureGeneration(),
      );
      final exported = await File(
        '${h.directory.path}/bundle.json',
      ).writeAsBytes(bundle.bytes);
      final inspected = await const PortableBackupService().inspect(exported);
      final restored = await const PortableBackupService().prepareRestore(
        exported,
        Directory('${h.directory.path}/restored'),
        expectedDigest: inspected.digest,
        isCurrent: () => true,
      );
      final value = jsonDecode(await restored.readAsString());
      final rows = (value['reminders'] as List)
          .map((r) => Reminder.fromJson(Map<String, dynamic>.from(r)))
          .toList();
      expect(
        LearningQueueService.progress(rows)['apple']!.toJson(),
        LearningQueueService.progress(await h.rows())['apple']!.toJson(),
      );
    },
  );

  test(
    'unselected shared live word, including paused batches, blocks the entire edit',
    () async {
      await seed();
      final before = await saved();
      await expectLater(
        preview(1, plans: ['q']),
        throwsA(isA<StudyScheduleConflict>()),
      );
      expect(await saved(), before);
      expect(h.notifications.scheduled, isEmpty);
    },
  );

  test(
    'unreviewed duplicate words may shift independently; completed history stays immutable',
    () async {
      await h.seed(batch('p-0').copyWith(wordProgressJson: null));
      await h.seed(batch('q-0', plan: 'q').copyWith(wordProgressJson: null));
      final control = (await h.row('q-0')).toJson();
      await commit(await preview(-1, plans: ['p']));
      expect((await h.row('p-0')).nextReviewAt, DateTime(2030, 1, 7, 8));
      expect((await h.row('p-0')).wordProgressJson, isNull);
      expect((await h.row('q-0')).toJson(), control);
    },
  );

  test(
    'a second date edit can move earlier despite the device clock moving backwards',
    () async {
      await seed();
      await commit(await preview(7));
      final rows = await h.rows();
      final p = StudyScheduleService.preview(
        rows,
        StudyPlanGroup.project(rows),
        -7,
        now: at.subtract(const Duration(days: 1)),
      );
      await commit(p);
      final progress = LearningQueueService.progress(await h.rows())['apple']!;
      expect(progress.due, DateTime(2030, 1, 8, 8));
      expect(progress.rescheduledAt, at.add(const Duration(microseconds: 1)));
      final graded = LearningQueueService.grade(
        progress,
        2,
        at.add(const Duration(days: 2)),
        progress.due,
      );
      expect(graded.reviews, progress.reviews + 1);
      expect(graded.rescheduledAt, isNull);
      expect(LearningQueueService.isNewerProgress(graded, progress), true);
    },
  );

  for (final change in [
    'edit',
    'insert',
    'move',
    'remove',
    'history',
    'new-shared',
  ]) {
    test(
      'concurrent $change invalidates preview with no partial writes',
      () async {
        await seed();
        await h.seed(batch('history', completed: true));
        final p = await preview(7);
        await h.database.writeTransaction(h.database.captureGeneration(), (
          db,
        ) async {
          switch (change) {
            case 'edit':
              await db.update(
                'Reminders',
                {'task_title': 'Changed'},
                where: 'id = ?',
                whereArgs: ['p-1'],
              );
            case 'insert':
              await db.insert('Reminders', batch('p-2').toJson());
            case 'move':
              await db.update(
                'Reminders',
                {'details_json': batch('p-1', plan: 'other').detailsJson},
                where: 'id = ?',
                whereArgs: ['p-1'],
              );
            case 'remove':
              await db.delete('Reminders', where: 'id = ?', whereArgs: ['p-1']);
            case 'history':
              final updated = LearningQueueService.grade(
                null,
                2,
                at,
                DateTime(2030, 1, 8, 8),
              );
              await db.update(
                'Reminders',
                {
                  'word_progress_json': jsonEncode({'apple': updated.toJson()}),
                },
                where: 'id = ?',
                whereArgs: ['history'],
              );
            case 'new-shared':
              await db.insert(
                'Reminders',
                batch('other-0', plan: 'other').toJson(),
              );
          }
        });
        final before = await saved();
        await expectLater(
          commit(p),
          throwsA(
            anyOf(
              isA<StaleReminderOccurrenceException>(),
              isA<StudyScheduleConflict>(),
            ),
          ),
        );
        expect(await saved(), before);
      },
    );
  }

  test(
    'failed second SQL write rolls everything back without native side effects',
    () async {
      await seed();
      final p = await preview(7), before = await saved();
      await (await h.database.database).execute(
        "CREATE TRIGGER fail_shift BEFORE UPDATE ON Reminders WHEN NEW.id = 'p-1' BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END",
      );
      await expectLater(commit(p), throwsA(isA<Exception>()));
      expect(await saved(), before);
      expect(h.notifications.cancelled, isEmpty);
      expect(h.notifications.scheduled, isEmpty);
      expect(
        h.notifier.state.every(
          (r) => r.nextReviewAt == DateTime(2030, 1, 8, 8),
        ),
        true,
      );
    },
  );

  test(
    'native reconciliation fails after durable commit and reports each affected row',
    () async {
      await seed();
      h.notifications.fail = true;
      final result = await h.notifier.shiftStudyPlanDates(
        await preview(7),
        h.database.captureGeneration(),
      );
      expect(result.changed, 3);
      expect(result.nativeSyncFailures, 3);
      expect((await h.row('p-0')).nextReviewAt, DateTime(2030, 1, 15, 8));
    },
  );

  test('recovery invalidates a previously prepared date edit', () async {
    await seed();
    final p = await preview(1), gen = h.database.captureGeneration();
    final before = await saved();
    await (await h.database.beginMaintenance()).resume();
    await expectLater(
      h.notifier.shiftStudyPlanDates(p, gen),
      throwsA(isA<DatabaseAccessException>()),
    );
    expect(await saved(), before);
  });

  test(
    'manual due dates drive the queue and seven-day workload without duplicating shared words',
    () async {
      await seed();
      final today = DateTime(2030, 1, 8, 12);
      expect(
        LearningQueueService.queue(await h.rows(), now: today).items.length,
        1,
      );
      await commit(await preview(7));
      final rows = await h.rows();
      expect(LearningQueueService.queue(rows, now: today).items, isEmpty);
      expect(
        LearningWorkloadService.project(
          rows,
          now: today,
        ).fold(0, (n, d) => n + d.total),
        0,
      );
      expect(
        LearningWorkloadService.project(
          rows,
          now: DateTime(2030, 1, 9),
        ).last.reviewWords,
        1,
      );
      expect(
        LearningQueueService.queue(
          rows,
          now: DateTime(2030, 1, 15),
        ).items.length,
        1,
      );
    },
  );

  test(
    'deleting older completed batches cannot roll back a newer manual date in word history',
    () async {
      await h.seed(batch('p-0'));
      await h.seed(batch('done', plan: 'q', completed: true));
      await commit(await preview(7, plans: ['p']));
      await h.notifier.deleteReminderForGeneration(
        'p-0',
        h.database.captureGeneration(),
      );
      final first = LearningQueueService.progress(
        await h.rows(),
      )['apple']!.toJson();
      await h.notifier.deleteReminderForGeneration(
        'done',
        h.database.captureGeneration(),
      );
      expect(
        LearningQueueService.progress(await h.rows())['apple']!.toJson(),
        first,
      );
      await h.close();
      await h.open();
      expect(
        LearningQueueService.progress(await h.rows())['apple']!.toJson(),
        first,
      );
    },
  );

  test(
    'moving into the past cancels old notifications and clears obsolete acknowledgements',
    () async {
      final oldTime = DateTime.now().subtract(const Duration(days: 10));
      final row = batch('p-0').copyWith(
        nextReviewAt: oldTime,
        triggerTime: oldTime,
        eventTime: oldTime,
        noticeAcknowledgedAt: oldTime,
        upcomingDismissedAt: oldTime,
        snoozedAt: oldTime,
      );
      await h.seed(row);
      h.notifications.cancelled.clear();
      h.notifications.scheduled.clear();
      final rows = await h.rows();
      final p = StudyScheduleService.preview(
        rows,
        StudyPlanGroup.project(rows),
        -1,
        now: at,
      );
      await commit(p);
      final changed = await h.row('p-0');
      expect(changed.noticeAcknowledgedAt, isNull);
      expect(changed.upcomingDismissedAt, isNull);
      expect(changed.snoozedAt, isNull);
      expect(changed.eventTime, p.changes.single.eventTime);
      expect(changed.timeOrigin, ReminderTimeOrigin.manual);
      expect(h.notifications.cancelled, ['p-0']);
      expect(h.notifications.scheduled, isEmpty);
    },
  );

  test(
    'calendar date math crosses month, leap day and year without changing wall clock',
    () {
      for (final dates in [
        [DateTime(2028, 2, 28, 8, 30), DateTime(2028, 2, 29, 8, 30)],
        [DateTime(2026, 12, 31, 23, 59), DateTime(2027, 1, 1, 23, 59)],
        [DateTime(2026, 4, 30, 8), DateTime(2026, 5, 1, 8)],
      ]) {
        expect(StudyScheduleService.shiftCalendar(dates[0], 1), dates[1]);
        expect(StudyScheduleService.shiftCalendar(dates[1], -1), dates[0]);
        expect(
          StudyScheduleService.shiftCalendar(dates[0].toUtc(), 1),
          dates[1].toUtc(),
        );
      }
    },
  );

  test(
    'malformed shared progress produces a safe preview error without any write',
    () async {
      await h.seed(batch('p-0'));
      final rows = await h.rows(), before = await saved();
      for (final source in ['{"apple":3}', '{"apple":{"rescheduled":false}}']) {
        final corrupt = [rows.single.copyWith(wordProgressJson: source)];
        expect(
          () => StudyScheduleService.preview(
            corrupt,
            StudyPlanGroup.project(corrupt),
            1,
          ),
          throwsFormatException,
        );
      }
      expect(await saved(), before);
    },
  );

  test(
    'date editing cannot save progress beyond the decoder size limit',
    () async {
      final progress =
          jsonDecode(batch('p-0').wordProgressJson!) as Map<String, dynamic>;
      final value = progress['apple'];
      var source = jsonEncode({...progress, 'orphan': value});
      final key = List.filled(
        99999 - source.length + 'orphan'.length,
        'x',
      ).join();
      source = jsonEncode({...progress, key: value});
      expect(source.length, 99999);
      expect(LearningQueueService.decode(source).length, 2);
      await h.seed(batch('p-0').copyWith(wordProgressJson: source));
      final before = await saved();
      await expectLater(preview(1), throwsFormatException);
      expect(await saved(), before);
    },
  );

  test(
    'invalid offsets, missing dates, recurring batches and partial snapshots are rejected',
    () async {
      await seed();
      for (final days in [0, 366, -366]) {
        await expectLater(preview(days), throwsFormatException);
      }
      final row = batch('single').copyWith(isRecurring: true);
      expect(
        () => StudyScheduleService.preview(
          [row],
          [
            StudyPlanGroup('p', [row]),
          ],
          1,
        ),
        throwsA(isA<StudyScheduleRecurring>()),
      );
      final noDate = row.copyWith(
        isRecurring: false,
        triggerTime: null,
        nextReviewAt: null,
      );
      expect(
        () => StudyScheduleService.preview(
          [noDate],
          [
            StudyPlanGroup('p', [noDate]),
          ],
          1,
        ),
        throwsFormatException,
      );
      expect(
        () => StudyScheduleService.preview(
          [batch('p-0'), batch('p-1')],
          [
            StudyPlanGroup('p', [batch('p-0')]),
          ],
          1,
        ),
        throwsA(isA<StudyScheduleStale>()),
      );
    },
  );
}
