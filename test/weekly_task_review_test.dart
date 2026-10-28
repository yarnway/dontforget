import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/models/weekly_task_review.dart';
import 'package:flutter_test/flutter_test.dart';

Reminder row(
  String id,
  List<TaskEvent> history, {
  String kind = 'task',
  String? planId,
  bool completed = false,
  String? outcome,
  DateTime? completedAt,
  Map<String, dynamic> data = const {},
  DateTime? deletedAt,
}) => Reminder(
  id: id,
  taskTitle: id,
  quadrantLevel: 2,
  isCompleted: completed,
  detailsJson: TaskDetails(
    kind: kind,
    planId: planId,
    history: history,
    doseOutcome: outcome,
    completedAt: completedAt,
    data: data,
    deletedAt: deletedAt,
    tags: const ['home'],
    project: 'Personal',
  ).encode(),
);

void main() {
  final monday = DateTime(2030, 1, 7), sunday = DateTime(2030, 1, 13, 23, 59);
  WeeklyTaskReview review(
    List<Reminder> rows, {
    DateTime? day,
    String query = '',
  }) => WeeklyTaskReview.build(
    rows,
    weekContaining: day ?? sunday,
    now: DateTime(2030, 1, 14),
    query: query,
  );
  test(
    'calendar week includes Monday and Sunday but excludes following Monday and future entries',
    () {
      final result = review([
        row('one', [
          TaskEvent('completed', monday),
          TaskEvent('completed', sunday),
          TaskEvent('completed', DateTime(2030, 1, 14)),
          TaskEvent('completed', DateTime(2031)),
        ]),
      ]);
      expect(result.start, monday);
      expect(result.end, DateTime(2030, 1, 14));
      expect(result.counts['completed'], 2);
      expect(result.activeDays, 2);
      final yearBoundary = review([], day: DateTime(2030, 1, 1));
      expect(yearBoundary.start, DateTime(2029, 12, 31));
      expect(yearBoundary.end, DateTime(2030, 1, 7));
    },
  );
  test(
    'duplicate events and learning archives do not inflate history counts',
    () {
      final event = TaskEvent('completed', monday, scheduled: monday);
      final task = row('one', [event, event], deletedAt: sunday);
      final result = review([
        task,
        task,
        row(
          'archive',
          [event],
          kind: 'study',
          data: {'learning_archive': true},
        ),
      ]);
      expect(result.counts['completed'], 1);
    },
  );
  test(
    'recurring completions and repeated postponements remain separate occurrences',
    () {
      final result = review([
        row('one', [
          TaskEvent('completed', monday),
          TaskEvent('completed', DateTime(2030, 1, 8)),
          TaskEvent('snoozed', monday, scheduled: monday),
          TaskEvent('snoozed', DateTime(2030, 1, 8), scheduled: monday),
        ]),
      ]);
      expect(result.counts['completed'], 2);
      expect(result.counts['snoozed'], 2);
      expect(result.frequentPostponements.single, (title: 'one', count: 2));
    },
  );
  test('dose correction counts the latest outcome once at actual time', () {
    final dose = row(
      'dose',
      [
        TaskEvent('not_taken', monday),
        TaskEvent('taken', sunday),
        TaskEvent('dose_time_corrected', sunday),
      ],
      kind: 'medication',
      completed: true,
      outcome: 'taken',
      completedAt: sunday,
      data: {'dose_taken_at': monday.toIso8601String()},
    );
    final result = review([dose, dose]);
    expect(result.counts['taken'], 1);
    expect(result.counts['not_taken'], 0);
    expect(result.activeDays, 1);
    final previousWeek = row(
      'previous',
      [TaskEvent('taken', sunday)],
      kind: 'medication',
      completed: true,
      outcome: 'taken',
      completedAt: sunday,
      data: {'dose_taken_at': DateTime(2030, 1, 6, 20).toIso8601String()},
    );
    expect(review([previousWeek]).counts['taken'], 0);
  });
  test(
    'legacy dose logs use recorded time without fabricating actual time',
    () {
      final dose = row(
        'legacy',
        [TaskEvent('taken', monday)],
        kind: 'medication',
        completed: true,
        outcome: 'taken',
      );
      expect(dose.details.actualDoseTakenAt, isNull);
      expect(review([dose]).counts['taken'], 1);
      expect(
        review([
          row(
            'missed',
            [TaskEvent('not_taken', sunday)],
            kind: 'medication',
            completed: true,
            outcome: 'not_taken',
            completedAt: sunday,
          ),
        ]).counts['not_taken'],
        1,
      );
      expect(
        review([
          row('open', [TaskEvent('taken', monday)], kind: 'medication'),
        ]).counts['taken'],
        0,
      );
    },
  );
  test(
    'group pause counts the parent operation rather than every generated dose',
    () {
      final event = TaskEvent('pause', monday);
      final result = review([
        row('owner', [event], kind: 'medicationPlan'),
        row('dose', [event], kind: 'medication', planId: 'owner'),
      ]);
      expect(result.counts['pause'], 1);
    },
  );
  test('query matches title project or tags and empty weeks stay empty', () {
    final source = [
      row('Alpha', [TaskEvent('completed', monday)]),
    ];
    for (final query in ['alpha', ' PERSONAL ', 'HOME']) {
      expect(review(source, query: query).counts['completed'], 1);
    }
    expect(review(source, query: 'absent').activeDays, 0);
    expect(review([], day: monday).counts.values.every((e) => e == 0), isTrue);
  });
}
