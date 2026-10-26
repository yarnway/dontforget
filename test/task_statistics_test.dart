import 'dart:collection';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_statistics.dart';
import 'package:flutter_test/flutter_test.dart';

class _Once extends IterableBase<Reminder> {
  _Once(this.tasks);
  final List<Reminder> tasks;
  int traversals = 0;
  @override
  Iterator<Reminder> get iterator {
    if (++traversals > 1) throw StateError('Traversed twice');
    return tasks.iterator;
  }
}

void main() {
  test('statistics use one traversal and bounded Unicode title samples', () {
    final data = _Once(
      List.generate(
        10000,
        (i) => Reminder(
          id: '$i',
          taskTitle: '${'😀' * 200}-$i',
          quadrantLevel: i % 4 + 1,
          isCompleted: i.isEven,
        ),
      ),
    );
    final stats = TaskStatistics.from(data);
    expect(data.traversals, 1);
    expect(stats.total, 10000);
    expect(stats.completed, 5000);
    expect(stats.pending, 5000);
    expect(stats.categories, [2500, 2500, 2500, 2500]);
    expect(stats.completionPercent, 50);
    expect(stats.completedTitles.length, 6);
    expect(stats.pendingTitles.length, 6);
    expect(stats.pendingTitles.first, '😀' * 160);
    expect(() => stats.categories[0] = 0, throwsUnsupportedError);
    expect(() => stats.completedTitles.add('extra'), throwsUnsupportedError);
  });
  test('empty and malformed-category snapshots remain finite and separate', () {
    final empty = TaskStatistics.from([]);
    expect(empty.total, 0);
    expect(empty.completionFraction, 0);
    final next = TaskStatistics.from([
      Reminder(
        id: 'one',
        taskTitle: 'One',
        quadrantLevel: 0,
        isCompleted: true,
      ),
      Reminder(id: 'two', taskTitle: 'Two', quadrantLevel: 4),
      Reminder(id: 'three', taskTitle: 'Three', quadrantLevel: 4),
    ]);
    expect(next.categories, [0, 0, 0, 2]);
    expect(next.total, 3);
    expect(next.completionPercent, 33);
    expect(empty.total, 0);
    expect(empty.categories, [0, 0, 0, 0]);
  });
}
