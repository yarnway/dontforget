import 'dart:convert';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/services/learning_workload_service.dart';
import 'package:flutter_test/flutter_test.dart';

Reminder task(
  String id,
  String word, {
  DateTime? due,
  String? progress,
  bool paused = false,
  bool completed = false,
  bool archived = false,
  bool deleted = false,
}) => Reminder(
  id: id,
  taskTitle: id,
  quadrantLevel: 2,
  taskSummary: '$word — meaning\nExample.',
  nextReviewAt: due,
  spacedRepetitionLevel: 1,
  isCompleted: completed,
  wordProgressJson: progress,
  detailsJson: TaskDetails(
    kind: 'study',
    paused: paused,
    archivedAt: archived ? DateTime(2030) : null,
    deletedAt: deleted ? DateTime(2030) : null,
  ).encode(),
);
String history(String word, DateTime due, DateTime reviewed) => jsonEncode({
  word: {
    'level': 1,
    'due': due.toIso8601String(),
    'reviewed': reviewed.toIso8601String(),
    'first': reviewed.toIso8601String(),
    'reviews': 1,
    'grade': 2,
  },
});
void main() {
  final now = DateTime(2030, 1, 31, 10);
  test(
    'known schedule counts overdue today and calendar boundaries exactly once',
    () {
      final rows = [
        task('a', 'apple', due: DateTime(2030, 1, 30)),
        task('b', 'banana', due: DateTime(2030, 2, 1)),
        task('c', 'cherry', due: DateTime(2030, 2, 6)),
        task('d', 'date', due: DateTime(2030, 2, 7)),
      ];
      final before = jsonEncode(rows.map((r) => r.toJson()).toList());
      final days = LearningWorkloadService.project(rows, now: now);
      expect(days.length, 7);
      expect(days.map((d) => d.total), [1, 1, 0, 0, 0, 0, 1]);
      expect(days.last.date, DateTime(2030, 2, 6));
      expect(jsonEncode(rows.map((r) => r.toJson()).toList()), before);
    },
  );
  test(
    'global latest history wins and duplicate new words use earliest active date',
    () {
      final rows = [
        task('a', ' Apple ', due: DateTime(2030, 2, 2)),
        task('b', 'apple', due: now),
        task(
          'c',
          'banana',
          progress: history(
            'banana',
            DateTime(2030, 2, 1),
            DateTime(2030, 1, 29),
          ),
        ),
        task(
          'archive',
          'banana',
          archived: true,
          progress: history(
            'banana',
            DateTime(2030, 2, 3),
            DateTime(2030, 1, 30),
          ),
        ),
      ];
      final a = LearningWorkloadService.project(rows, now: now);
      final b = LearningWorkloadService.project(
        rows.reversed.toList(),
        now: now,
      );
      expect(a.map((d) => d.total), b.map((d) => d.total));
      expect(a[0].newWords, 1);
      expect(a[3].reviewWords, 1);
      expect(a.fold(0, (n, d) => n + d.total), 2);
    },
  );
  test(
    'inactive batches excluded and todays reviewed word cannot recur today',
    () {
      final rows = [
        task('a', 'apple', paused: true),
        task('b', 'banana', completed: true),
        task('c', 'cherry', archived: true),
        task('d', 'date', deleted: true),
        task('e', 'elderberry', progress: history('elderberry', now, now)),
        task('f', 'fig'),
      ];
      final days = LearningWorkloadService.project(rows, now: now);
      expect(days[0].newWords, 1);
      expect(days[0].reviewWords, 0);
      expect(days[1].reviewWords, 1);
      expect(days.fold(0, (n, d) => n + d.total), 2);
    },
  );
  test('limits do not double count new word overflow', () {
    final day = LearningDayLoad(now)
      ..newWords = 12
      ..reviewWords = 15;
    expect(day.excess(20, 10), 7);
    expect(day.excess(40, 0), 12);
  });
  test(
    'damaged history is rejected instead of silently inventing a forecast',
    () {
      expect(
        () => LearningWorkloadService.project([
          task('a', 'apple', progress: 'bad'),
        ], now: now),
        throwsFormatException,
      );
    },
  );
  test('wrong history shapes are reported as format errors', () {
    for (final raw in ['{"apple": []}', '{"apple": {"level": "bad"}}']) {
      expect(
        () => LearningWorkloadService.project([
          task('a', 'apple', progress: raw),
        ], now: now),
        throwsFormatException,
      );
    }
  });
  test('today uses remaining capacity after completed archived history', () {
    final rows = [
      task(
        'done',
        'apple',
        archived: true,
        progress: history('apple', DateTime(2030, 2, 1), now),
      ),
      task('pending', 'banana'),
    ];
    final days = LearningWorkloadService.project(rows, now: now);
    expect(days.first.total, 1);
    expect(days.first.excess(1, 1), 1);
    expect(days[1].spentToday, 0);
  });
}
