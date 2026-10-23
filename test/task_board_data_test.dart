import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/widgets/task_board_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Reminder task(String id, int level, {bool done = false}) =>
      Reminder(id: id, taskTitle: id, quadrantLevel: level, isCompleted: done);
  test(
    'exact-sized projection preserves category order, counts and hidden folds',
    () {
      var checks = 0;
      final tasks = [
        task('active', 4),
        task('done', 4, done: true),
        task('folded', 4),
        task('urgent', 1),
        task('invalid', 8),
        task('done-urgent', 1, done: true),
      ];
      final narrow = TaskBoardData.project(
        tasks,
        visibleCategory: 0,
        isFolded: (_) {
          checks++;
          return true;
        },
      );
      expect(narrow.pending, [1, 0, 0, 2]);
      expect(narrow.sections[0].active.single.id, 'urgent');
      expect(narrow.sections[3].isEmpty, isTrue);
      expect(checks, 0);
      final wide = TaskBoardData.project(
        tasks,
        isFolded: (t) {
          checks++;
          return t.id == 'folded';
        },
      );
      expect(checks, 2); // No fold call for completed rows or other categories.
      final section = wide.sections[3];
      for (final completedExpanded in [false, true]) {
        for (final foldedExpanded in [false, true]) {
          final expected = <Object>[
            section.active.single,
            'completed',
            if (completedExpanded) section.completed.single,
            'folded',
            if (foldedExpanded) section.folded.single,
          ];
          final count = section.rowCount(
            completedExpanded: completedExpanded,
            foldedExpanded: foldedExpanded,
          );
          expect(count, expected.length);
          expect([
            for (var i = 0; i < count; i++)
              section.rowAt(
                i,
                completedExpanded: completedExpanded,
                foldedExpanded: foldedExpanded,
              ),
          ], expected);
          expect(
            () => section.rowAt(
              count,
              completedExpanded: completedExpanded,
              foldedExpanded: foldedExpanded,
            ),
            throwsRangeError,
          );
        }
      }
    },
  );

  test('10000 rows match the previous classification for all categories', () {
    final tasks = List.generate(
      10000,
      (i) => task('$i', i % 4 + 1, done: i % 7 == 0),
    );
    bool folded(Reminder r) => int.parse(r.id) % 3 == 0;
    final data = TaskBoardData.project(tasks, isFolded: folded);
    for (var i = 0; i < 4; i++) {
      final grouped = tasks.where((t) => t.quadrantLevel == i + 1).toList();
      final section = data.sections[i];
      expect(section.completed, grouped.where((t) => t.isCompleted));
      expect(
        section.folded,
        grouped.where((t) => !t.isCompleted && i == 3 && folded(t)),
      );
      expect(
        section.active,
        grouped.where((t) => !t.isCompleted && (i != 3 || !folded(t))),
      );
      expect(data.pending[i], grouped.where((t) => !t.isCompleted).length);
    }
  });
  test(
    'single-use input is traversed once and each fold decision is used once',
    () {
      var iterations = 0;
      Iterable<Reminder> input() sync* {
        iterations++;
        if (iterations > 1) throw StateError('single use');
        yield task('a', 4);
        yield task('b', 4);
        yield task('bad', 99);
      }

      var folds = 0;
      final data = TaskBoardData.project(
        input(),
        isFolded: (_) => ++folds == 1,
      );
      expect(iterations, 1);
      expect(folds, 2);
      expect(data.sections[3].folded.single.id, 'a');
      expect(data.sections[3].active.single.id, 'b');
      expect(data.pending, [0, 0, 0, 2]);
      expect(
        TaskBoardData.project(
          [],
          isFolded: (_) => true,
        ).sections.every((s) => s.isEmpty),
        isTrue,
      );
    },
  );
}
