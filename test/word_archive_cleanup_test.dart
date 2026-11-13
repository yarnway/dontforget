import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'package:dont_forget/services/word_archive_cleanup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';

Reminder retainedWord(String word, {DateTime? reviewed, DateTime? first}) {
  final key = LearningQueueService.wordKey(word);
  final at = reviewed ?? DateTime(2030, 1, 10);
  return Reminder(
    id: 'word-history:${sha256.convert(utf8.encode(key))}',
    taskTitle: word,
    taskSummary: '$word — synthetic meaning\nAn example.',
    quadrantLevel: 2,
    isCompleted: true,
    createdAt: at,
    wordProgressJson: jsonEncode({
      key: WordProgress(
        level: 2,
        due: at.add(const Duration(days: 4)),
        reviewed: at,
        firstReviewed: first ?? at,
        reviews: 3,
        grade: 2,
      ).toJson(),
    }),
    detailsJson: TaskDetails(
      kind: 'study',
      archivedAt: at,
      data: const {'learning_archive': true},
    ).encode(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2030, 1, 20, 12);
  test(
    'only canonical unused past histories qualify; references include hidden tasks',
    () {
      final apple = retainedWord('apple'), pear = retainedWord('pear');
      final rows = [
        apple,
        pear,
        retainedWord('today', reviewed: now),
        retainedWord('future', reviewed: now.add(const Duration(days: 1))),
        retainedWord('linked'),
        retainedWord('media').copyWith(recordId: 'original'),
        retainedWord('custom').copyWith(
          detailsJson: TaskDetails(
            kind: 'study',
            archivedAt: now,
            tags: const ['keep'],
            data: const {'learning_archive': true},
          ).encode(),
        ),
        Reminder(
          id: 'source',
          taskTitle: 'Archived source',
          quadrantLevel: 4,
          taskSummary: 'APPLE — fruit\nAn example.',
          detailsJson: TaskDetails(deletedAt: now).encode(),
          linkedTaskIds: [retainedWord('linked').id],
        ),
      ];
      final p = WordArchiveCleanupService.preview(rows, now: now);
      expect(p.candidates.map((r) => r.id), [pear.id]);
      expect(p.eligibleCount, 1);
      expect(() => p.candidates.clear(), throwsUnsupportedError);
      expect(WordArchiveCleanupService.snapshot(rows.reversed), p.snapshot);
    },
  );
  test(
    'progress without vocabulary still protects its identity and today allowance',
    () {
      final source = Reminder.fromJson({
        ...retainedWord('apple').toJson(),
        'id': 'ordinary',
        'task_summary': 'Edited notes',
        'details_json': null,
      });
      final reviewedToday = retainedWord('today', reviewed: now);
      // A corrupt first date is rejected rather than treated as empty history.
      expect(
        WordArchiveCleanupService.preview([
          source,
          retainedWord('apple'),
          reviewedToday,
        ], now: now).candidates,
        isEmpty,
      );
      expect(
        () => WordArchiveCleanupService.preview([
          retainedWord('broken').copyWith(wordProgressJson: '{"bad": 4}'),
        ], now: now),
        throwsFormatException,
      );
    },
  );
  test(
    'a nonstandard archive marker cannot hide an active vocabulary reference',
    () {
      final source = Reminder(
        id: 'nonstandard-active',
        taskTitle: 'Imported study item',
        quadrantLevel: 2,
        spacedRepetitionLevel: 1,
        taskSummary: 'pear — fruit\nAn example.',
        detailsJson: const TaskDetails(
          kind: 'study',
          data: {'learning_archive': true},
        ).encode(),
      );
      final rows = [source, retainedWord('pear')];
      expect(
        LearningQueueService.queue(rows, now: now).items.single.progress,
        isNotNull,
      );
      expect(
        WordArchiveCleanupService.preview(rows, now: now).candidates,
        isEmpty,
      );
    },
  );
  test(
    'canonical history without a definition can be cleared; edited mixed notes stay protected',
    () {
      final orphan = retainedWord('orphan').copyWith(taskSummary: null);
      final edited = retainedWord(
        'apple',
      ).copyWith(taskSummary: 'pear — fruit\nAn example.');
      final p = WordArchiveCleanupService.preview([
        orphan,
        edited,
        retainedWord('pear'),
      ], now: now);
      expect(p.candidates.map((r) => r.id), [orphan.id]);
    },
  );
  test(
    'bounded preview exposes only the records that this batch will remove',
    () {
      final rows = [for (var i = 0; i < 201; i++) retainedWord('word $i')];
      final p = WordArchiveCleanupService.preview(rows, now: now);
      expect(p.eligibleCount, 201);
      expect(p.candidates.length, WordArchiveCleanupService.maxBatchSize);
      expect(p.snapshot, WordArchiveCleanupService.snapshot(rows));
    },
  );

  group('transactional cleanup', () {
    late OfflineManagementHarness h;
    setUp(() async {
      h = OfflineManagementHarness();
      await h.create();
    });
    tearDown(() => h.dispose());
    Future<String> saved() async => jsonEncode(
      (await h.rows())..sort((a, b) => a.id.compareTo(b.id)),
      toEncodable: (o) => (o as Reminder).toJson(),
    );
    Future<WordArchiveCleanupPreview> preview() async =>
        WordArchiveCleanupService.preview(await h.rows(), now: now);
    Future<void> seed() async {
      for (final word in ['pear', 'plum', 'apple']) {
        await h.seed(retainedWord(word));
      }
      await h.seed(retainedWord('today', reviewed: now));
      await h.seed(
        Reminder(
          id: 'active',
          taskTitle: 'Study',
          quadrantLevel: 2,
          taskSummary: 'apple — fruit\nAn apple.\n\nbanana — fruit\nA banana.',
          spacedRepetitionLevel: 1,
        ),
      );
      await h.seed(
        Reminder(id: 'control', taskTitle: 'Unrelated', quadrantLevel: 4),
      );
      h.notifications.cancelled.clear();
      h.notifications.scheduled.clear();
    }

    test(
      'retention produced by actual source deletion can be explicitly cleared',
      () async {
        final source = Reminder.fromJson({
          ...retainedWord('pear').toJson(),
          'id': 'original-source',
          'details_json': null,
        });
        await h.seed(source);
        await h.notifier.deleteReminder(source.id);
        expect((await h.rows()).single.id, retainedWord('pear').id);
        h.notifications.cancelled.clear();
        final p = await preview();
        expect(p.candidates.length, 1);
        expect(
          await h.notifier.clearWordArchives(
            p,
            h.database.captureGeneration(),
            now: now,
          ),
          1,
        );
        expect(await h.rows(), isEmpty);
        expect(h.notifications.cancelled, isEmpty);
      },
    );

    test(
      'clears only previewed retention rows; queue, tables, native calls and cold readback remain valid',
      () async {
        await seed();
        final before = {for (final row in await h.rows()) row.id: row.toJson()};
        final queue = LearningQueueService.queue(await h.rows(), now: now);
        final settings = await h.database.read(
          h.database.captureGeneration(),
          (db) async => jsonEncode([
            await db.query('Settings'),
            await db.query('MediaRecords'),
          ]),
        );
        final p = await preview();
        expect(p.candidates.length, 2);
        expect(
          await h.notifier.clearWordArchives(
            p,
            h.database.captureGeneration(),
            now: now,
          ),
          2,
        );
        final ids = p.candidates.map((r) => r.id).toSet();
        for (final row in await h.rows()) {
          expect(row.toJson(), before[row.id]);
          expect(ids.contains(row.id), false);
        }
        expect(h.notifier.state.length, before.length - 2);
        final after = LearningQueueService.queue(await h.rows(), now: now);
        expect(after.items.map((i) => i.key), queue.items.map((i) => i.key));
        expect(after.completedToday, queue.completedToday);
        expect(after.newToday, queue.newToday);
        expect(
          await h.database.read(
            h.database.captureGeneration(),
            (db) async => jsonEncode([
              await db.query('Settings'),
              await db.query('MediaRecords'),
            ]),
          ),
          settings,
        );
        expect(h.notifications.cancelled, isEmpty);
        expect(h.notifications.scheduled, isEmpty);
        final remaining = await saved();
        expect(
          await h.notifier.clearWordArchives(
            await preview(),
            h.database.captureGeneration(),
            now: now,
          ),
          0,
        );
        expect(await saved(), remaining);
        await h.close();
        await h.open();
        expect(await saved(), remaining);
      },
    );
    for (final mutation in ['new reference', 'changed source', 'missing row']) {
      test('$mutation invalidates the whole preview', () async {
        await seed();
        final p = await preview();
        await h.database.writeTransaction(h.database.captureGeneration(), (
          db,
        ) async {
          if (mutation == 'new reference') {
            await db.insert(
              'Reminders',
              Reminder(
                id: 'new',
                taskTitle: 'New',
                quadrantLevel: 4,
                taskSummary: 'pear — fruit\nAn example.',
              ).toJson(),
            );
          } else if (mutation == 'changed source') {
            await db.update(
              'Reminders',
              {'task_summary': 'pear — fruit\nAn example.'},
              where: 'id = ?',
              whereArgs: ['control'],
            );
          } else {
            await db.delete(
              'Reminders',
              where: 'id = ?',
              whereArgs: ['control'],
            );
          }
        });
        final before = await saved();
        await expectLater(
          h.notifier.clearWordArchives(
            p,
            h.database.captureGeneration(),
            now: now,
          ),
          throwsA(isA<WordArchiveCleanupStale>()),
        );
        expect(await saved(), before);
        expect(h.notifications.cancelled, isEmpty);
      });
    }
    test('a later delete failure rolls the entire batch back', () async {
      await seed();
      final p = await preview();
      final before = await saved();
      await h.database.writeTransaction(
        h.database.captureGeneration(),
        (db) => db.execute(
          "CREATE TRIGGER reject_archive_clear BEFORE DELETE ON Reminders WHEN OLD.id = '${p.candidates.last.id}' BEGIN SELECT RAISE(ABORT, 'synthetic delete failure'); END",
        ),
      );
      await expectLater(
        h.notifier.clearWordArchives(
          p,
          h.database.captureGeneration(),
          now: now,
        ),
        throwsA(anything),
      );
      expect(await saved(), before);
      expect(h.notifications.cancelled, isEmpty);
      expect(h.notifier.state.length, (await h.rows()).length);
    });
    test(
      'day rollover and recovery reject old previews without deleting records',
      () async {
        await seed();
        final p = await preview(), gen = h.database.captureGeneration();
        final before = await saved();
        await expectLater(
          h.notifier.clearWordArchives(
            p,
            gen,
            now: now.add(const Duration(days: 1)),
          ),
          throwsA(isA<WordArchiveCleanupStale>()),
        );
        await (await h.database.beginMaintenance()).resume();
        await expectLater(
          h.notifier.clearWordArchives(p, gen, now: now),
          throwsA(isA<DatabaseAccessException>()),
        );
        expect(await saved(), before);
      },
    );
  });
}
