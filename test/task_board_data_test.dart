import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/widgets/task_board_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Reminder task(String id, int level, {bool done = false}) =>
      Reminder(id: id, taskTitle: id, quadrantLevel: level, isCompleted: done);
  test(
    'automatic category follows priority for every nonempty combination',
    () {
      for (var mask = 0; mask < 16; mask++) {
        final levels = [
          for (var i = 1; i <= 4; i++)
            if ((mask & (1 << (i - 1))) != 0) i,
        ];
        var iterated = false;
        Iterable<Reminder> once() sync* {
          expect(iterated, isFalse);
          iterated = true;
          yield task('invalid', 9);
          for (final level in levels.reversed) {
            yield task('active-$level', level);
            yield task('done-$level', level, done: true);
          }
        }

        var foldChecks = 0;
        final data = TaskBoardData.project(
          once(),
          selectFirstNonEmpty: true,
          isFolded: (_) {
            foldChecks++;
            return true;
          },
        );
        final selected = levels.isEmpty ? 0 : levels.first - 1;
        expect(data.visibleCategory, selected);
        for (var i = 0; i < 4; i++) {
          expect(data.pending[i], levels.contains(i + 1) ? 1 : 0);
          expect(data.sections[i].isEmpty, levels.isEmpty || i != selected);
        }
        expect(foldChecks, selected == 3 && levels.isNotEmpty ? 1 : 0);
      }
    },
  );

  test('completed rows still count as items for the default category', () {
    final data = TaskBoardData.project(
      [task('memo', 4), task('done', 2, done: true)],
      selectFirstNonEmpty: true,
      isFolded: (_) => false,
    );
    expect(data.visibleCategory, 1);
    expect(data.sections[1].completed.single.id, 'done');
  });
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
