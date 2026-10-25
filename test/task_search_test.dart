import 'dart:io';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/task_search_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('search covers title summary and decoded subtasks in source order', () {
    final index = TaskSearchIndex([
      Reminder(id: 'title', taskTitle: 'Plan RELEASE', quadrantLevel: 1),
      Reminder(
        id: 'summary',
        taskTitle: 'Review',
        taskSummary: 'Release notes',
        quadrantLevel: 2,
        isCompleted: true,
      ),
      Reminder(
        id: 'subtask',
        taskTitle: 'Other',
        subTasks: '["发布说明", "Prepare release"]',
        quadrantLevel: 4,
      ),
      Reminder(
        id: 'invalid',
        taskTitle: 'Malformed subtasks',
        subTasks: '{broken',
        quadrantLevel: 3,
      ),
    ]);
    expect(index.search('  ReLeAsE  ').map((task) => task.id), [
      'title',
      'summary',
      'subtask',
    ]);
    expect(index.search('发布').single.id, 'subtask');
    expect(index.search('missing'), isEmpty);
    expect(index.search('  '), isEmpty);
    expect(index.search('  Other \t发布\nrelease ').single.id, 'subtask');
  });

  test(
    'new data revision replaces stale task text and does not mutate source',
    () {
      final original = Reminder(
        id: 'one',
        taskTitle: 'Before',
        quadrantLevel: 1,
      );
      final source = [original];
      final before = TaskSearchIndex(source);
      source[0] = original.copyWith(taskTitle: 'After');
      final after = TaskSearchIndex(source);
      expect(before.search('before').single, same(original));
      expect(after.search('before'), isEmpty);
      expect(after.search('after').single, same(source.single));
    },
  );
  test(
    'incremental rebuild reuses text but refreshes status, order and identity',
    () {
      final first = _CountedReminder('one', 'Release', '["Checklist"]');
      final removed = _CountedReminder('removed', 'Release', '[]');
      final before = TaskSearchIndex([first, removed]);
      expect(first.decodes, 1);
      final updated = _CountedReminder(
        'one',
        'Release',
        '["Checklist"]',
        completed: true,
      );
      final added = _CountedReminder('added', 'Release', '[]');
      final after = TaskSearchIndex([added, updated], previous: before);
      expect(updated.decodes, 0);
      expect(added.decodes, 1);
      expect(after.search('release').map((r) => r.id), ['added', 'one']);
      expect(
        after.search('release', filter: TaskSearchFilter.completed).single,
        same(updated),
      );
      expect(
        after.search('checklist', filter: TaskSearchFilter.pending),
        isEmpty,
      );
      expect(before.search('checklist').single, same(first));
      expect(before.search('release').length, 2);
      final edited = _CountedReminder('one', 'Changed', '["Replaced"]');
      final restored = TaskSearchIndex([edited], previous: after);
      expect(edited.decodes, 1);
      expect(restored.search('checklist'), isEmpty);
      expect(restored.search('changed replaced').single, same(edited));
    },
  );

  for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
    test('today uses calendar boundaries on $day', () {
      final now = DateTime(day.year, day.month, day.day, 12);
      final tomorrow = DateTime(day.year, day.month, day.day + 1);
      if (Platform.environment['TZ'] == 'America/Los_Angeles') {
        expect(tomorrow.difference(day).inHours, day.month == 3 ? 23 : 25);
      }
      final index = TaskSearchIndex([
        _task('yesterday', due: day.subtract(const Duration(microseconds: 1))),
        _task('start', due: day.toUtc()),
        _task('now', due: now),
        _task('end', due: tomorrow.subtract(const Duration(microseconds: 1))),
        _task('tomorrow', due: tomorrow),
        _task('done', due: now, completed: true),
        _task('unscheduled'),
      ]);
      List<String> ids(TaskSearchFilter filter) => index
          .search('', includeAllWhenEmpty: true, filter: filter, now: now)
          .map((r) => r.id)
          .toList();
      expect(ids(TaskSearchFilter.today), ['start', 'now', 'end']);
      expect(ids(TaskSearchFilter.overdue), ['yesterday', 'start']);
      expect(ids(TaskSearchFilter.completed), ['done']);
      expect(ids(TaskSearchFilter.pending).length, 6);
      expect(ids(TaskSearchFilter.all).length, 7);
      expect(
        index.search('end', filter: TaskSearchFilter.overdue, now: now),
        isEmpty,
      );
      expect(
        index
            .search(
              '',
              includeAllWhenEmpty: true,
              filter: TaskSearchFilter.today,
              now: tomorrow,
            )
            .single
            .id,
        'tomorrow',
      );
    });
  }

  test('sorting keeps equal dates stable and unscheduled tasks last', () {
    final date = DateTime(2026, 10, 25);
    final data = [
      _task('none', created: date),
      _task('later', due: date.add(const Duration(days: 1)), created: date),
      _task('first', due: date, created: date.add(const Duration(days: 1))),
      _task('tie', due: date, created: date),
    ];
    final index = TaskSearchIndex(data);
    expect(
      index
          .search(
            '',
            includeAllWhenEmpty: true,
            sort: TaskSearchSort.dueSoonest,
          )
          .map((r) => r.id),
      ['first', 'tie', 'later', 'none'],
    );
    expect(
      index
          .search('', includeAllWhenEmpty: true, sort: TaskSearchSort.newest)
          .map((r) => r.id),
      ['first', 'none', 'later', 'tie'],
    );
    expect(index.search('', includeAllWhenEmpty: true).map((r) => r.id), [
      'none',
      'later',
      'first',
      'tie',
    ]);
    expect(data.first.id, 'none');
  });
}

Reminder _task(
  String id, {
  DateTime? due,
  DateTime? created,
  bool completed = false,
}) => Reminder(
  id: id,
  taskTitle: id,
  quadrantLevel: 1,
  triggerTime: due,
  createdAt: created,
  isCompleted: completed,
);

class _CountedReminder extends Reminder {
  _CountedReminder(
    String id,
    String title,
    String subtasks, {
    bool completed = false,
  }) : super(
         id: id,
         taskTitle: title,
         subTasks: subtasks,
         quadrantLevel: 1,
         isCompleted: completed,
       );
  int decodes = 0;
  @override
  List<String> getSubTasksList() {
    decodes++;
    return super.getSubTasksList();
  }
}
