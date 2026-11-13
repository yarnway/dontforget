import 'dart:convert';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/learning_forecast_service.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'learning_workload_test.dart' show task, history;
import 'support/offline_management_harness.dart';

void main() {
  final now = DateTime(2030, 1, 31, 10);
  List<LearningForecastDay> forecast(List<Reminder> rows, {int grade = 2}) =>
      LearningForecastService.project(rows, now: now, grade: grade);

  test(
    'new words generate subsequent reviews at the actual grade intervals',
    () {
      final rows = [task('a', 'apple', due: now)];
      final before = jsonEncode(rows.map((r) => r.toJson()).toList());
      final days = forecast(rows);
      expect(days.map((d) => d.total), [1, 1, 0, 1, 0, 0, 0]);
      expect(days.first.newWords, 1);
      expect(days[1].reviewWords, 1);
      expect(days.last.date, DateTime(2030, 2, 6));
      expect(jsonEncode(rows.map((r) => r.toJson()).toList()), before);
      expect(() => days.add(days.first), throwsUnsupportedError);
    },
  );

  test(
    'fuzzy and unknown scenarios repeat daily without inventing new words',
    () {
      for (final grade in [0, 1]) {
        final days = forecast([task('a', 'apple')], grade: grade);
        expect(days.map((d) => d.total), List.filled(7, 1));
        expect(days.map((d) => d.newWords), [1, 0, 0, 0, 0, 0, 0]);
        expect(days.skip(1).every((d) => d.reviewWords == 1), true);
      }
    },
  );

  test('zero new capacity carries unlearned words forward', () {
    final days = LearningForecastService.project(
      [task('a', 'apple')],
      now: now,
      dailyLimit: 1,
      newLimit: 0,
    );
    expect(days.every((d) => d.total == 0 && d.deferred == 1), true);
  });

  test(
    'today respects completed hidden history and tomorrow resets capacity',
    () {
      final days = LearningForecastService.project(
        [
          task(
            'hidden',
            'old',
            archived: true,
            progress: history('old', DateTime(2030, 2, 1), now),
          ),
          task('new', 'apple'),
        ],
        now: now,
        dailyLimit: 1,
        newLimit: 1,
      );
      expect(days.first.total, 0);
      expect(days.first.deferred, 1);
      expect(days[1].newWords, 1);
      expect(days[2].reviewWords, 1);
    },
  );

  test(
    'paused, completed, archived and deleted words stay out of the queue',
    () {
      expect(
        forecast([
          task('a', 'apple', paused: true),
          task('b', 'banana', completed: true),
          task('c', 'cherry', archived: true),
          task('d', 'date', deleted: true),
        ]).every((d) => d.total == 0 && d.deferred == 0),
        true,
      );
    },
  );

  test(
    'global latest and manually rescheduled shared history is authoritative',
    () {
      final rows = [
        task(
          'a',
          'apple',
          progress: history(
            'apple',
            now,
            now.subtract(const Duration(days: 2)),
          ),
        ),
        task('b', ' Apple '),
        task(
          'archive',
          'apple',
          archived: true,
          progress: jsonEncode({
            'apple': {
              'level': 1,
              'reviews': 1,
              'grade': 2,
              'first': now.subtract(const Duration(days: 2)).toIso8601String(),
              'reviewed': now
                  .subtract(const Duration(days: 2))
                  .toIso8601String(),
              'rescheduled': now
                  .subtract(const Duration(days: 1))
                  .toIso8601String(),
              'due': DateTime(2030, 2, 2).toIso8601String(),
            },
          }),
        ),
      ];
      final a = forecast(rows), b = forecast(rows.reversed.toList());
      expect(a.map((d) => d.total), b.map((d) => d.total));
      expect(a.map((d) => d.total), [0, 0, 1, 0, 1, 0, 0]);
      expect(a.every((d) => d.newWords == 0), true);
    },
  );

  test('custom review intervals are honored', () {
    final days = LearningForecastService.project(
      [task('a', 'apple')],
      now: now,
      intervals: [2, 3, 5, 9, 15],
    );
    expect(days.map((d) => d.total), [1, 0, 1, 0, 0, 1, 0]);
  });

  test(
    'damaged preferences and history fail instead of showing empty forecasts',
    () {
      for (final raw in ['bad', '{"apple": []}', '{"apple":{"level":"bad"}}']) {
        expect(
          () => forecast([task('a', 'apple', progress: raw)]),
          throwsFormatException,
        );
      }
      expect(
        () => LearningForecastService.project([], now: now, dailyLimit: 0),
        throwsFormatException,
      );
      expect(
        () => LearningForecastService.project(
          [],
          now: now,
          dailyLimit: 1,
          newLimit: 2,
        ),
        throwsFormatException,
      );
      expect(
        () => LearningForecastService.project([], now: now, grade: 3),
        throwsFormatException,
      );
      expect(
        () => LearningForecastService.project([], now: now, intervals: [1]),
        throwsFormatException,
      );
      expect(
        () => forecast([task('a', 'apple'), task('a', 'banana')]),
        throwsFormatException,
      );
      expect(
        () => forecast([
          task(
            'a',
            'apple',
            progress: history('apple', now, now.add(const Duration(days: 1))),
          ),
        ]),
        throwsFormatException,
      );
    },
  );

  test(
    'a thousand words obey daily and new limits while reviews take priority',
    () {
      final rows = [
        for (var batch = 0; batch < 50; batch++)
          task('$batch', 'placeholder').copyWith(
            taskSummary: [
              for (var word = 0; word < 20; word++)
                'word${batch * 20 + word} — meaning\nExample.',
            ].join('\n\n'),
          ),
      ];
      final days = LearningForecastService.project(
        rows,
        now: now,
        dailyLimit: 40,
        newLimit: 10,
        grade: 0,
      );
      expect(days.map((d) => d.total), [10, 20, 30, 40, 40, 40, 40]);
      expect(days.fold(0, (n, d) => n + d.newWords), 40);
      expect(days.every((d) => d.total <= 40 && d.newWords <= 10), true);
    },
  );

  for (final scenario in [0, 1, 2]) {
    test(
      'forecast agrees with seven days of SQLite gradeWord commits ($scenario)',
      () async {
        final h = OfflineManagementHarness();
        await h.create();
        try {
          await h.seed(task('a', 'apple', due: now));
          await h.seed(task('b', 'banana', due: now));
          await h.seed(
            task('shared', 'apple', due: now.add(const Duration(days: 3))),
          );
          await h.seed(task('paused', 'cherry', paused: true));
          final input = await h.rows();
          final before = jsonEncode(input.map((r) => r.toJson()).toList());
          final predicted = LearningForecastService.project(
            input,
            now: now,
            grade: scenario,
            dailyLimit: 2,
            newLimit: 1,
          );
          expect(
            jsonEncode((await h.rows()).map((r) => r.toJson()).toList()),
            before,
          );
          h.notifications.scheduled.clear();
          h.notifications.cancelled.clear();
          for (var day = 0; day < 7; day++) {
            final at = DateTime(now.year, now.month, now.day + day, now.hour);
            final queue = LearningQueueService.queue(
              await h.rows(),
              now: at,
              dailyLimit: 2,
              newLimit: 1,
            );
            expect(
              predicted[day].total,
              queue.items.length,
              reason: 'day $day',
            );
            expect(
              predicted[day].newWords,
              queue.items.where((w) => w.progress == null).length,
            );
            expect(predicted[day].deferred, queue.deferred);
            for (final item in queue.items) {
              await h.notifier.gradeWord(
                await h.row(item.task.id),
                item.key,
                scenario,
                now: at,
                dailyLimit: 2,
                newLimit: 1,
              );
            }
          }
        } finally {
          await h.dispose();
        }
      },
    );
  }
}
