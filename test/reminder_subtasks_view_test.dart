import 'package:dont_forget/models/reminder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Reminder task(String? value) => Reminder(
    id: 'synthetic',
    taskTitle: 'Synthetic',
    quadrantLevel: 2,
    subTasks: value,
  );

  test(
    'read-only parsed view is stable and legacy mutable copies stay independent',
    () {
      final value = task('["准备发布",42,true]');
      final view = value.subTasksView;
      expect(view, ['准备发布', '42', 'true']);
      expect(identical(value.subTasksView, view), isTrue);
      expect(() => view.add('changed'), throwsUnsupportedError);
      final copy = value.getSubTasksList()..clear();
      expect(copy, isEmpty);
      expect(value.subTasksView, ['准备发布', '42', 'true']);
    },
  );

  test('invalid and absent input preserve empty-list parsing semantics', () {
    for (final raw in [null, '', '  ', '{}', 'broken', '[]']) {
      final value = task(raw);
      expect(value.subTasksView, isEmpty);
      expect(identical(value.subTasksView, value.subTasksView), isTrue);
      expect(() => value.subTasksView.add('changed'), throwsUnsupportedError);
    }
  });

  test(
    'copyWith invalidates parsed view and caching does not change backup rows',
    () {
      final value = task('["before"]');
      final before = value.toJson();
      expect(value.subTasksView, ['before']);
      expect(value.toJson(), before);
      expect(value.copyWith(subTasks: '["after"]').subTasksView, ['after']);
      expect(value.copyWith(subTasks: null).subTasksView, isEmpty);
      expect(value.subTasksView, ['before']);
    },
  );
}
