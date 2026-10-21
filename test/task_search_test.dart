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
    expect(index.search('Other 发布'), isEmpty);
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
}
