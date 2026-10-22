import '../../models/reminder.dart';

/// Project the visible sections in one pass, preserving source order. Narrow
/// boards only retain rows for the selected category; all four counts remain
/// available. A section exposes list rows by offset without flattening copies.
class TaskBoardData {
  TaskBoardData._(this.sections, this.pending);

  final List<TaskSectionData> sections;
  final List<int> pending;

  factory TaskBoardData.project(
    Iterable<Reminder> reminders, {
    int? visibleCategory,
    required bool Function(Reminder) isFolded,
  }) {
    final sections = List.generate(4, (_) => TaskSectionData());
    final pending = List.filled(4, 0);
    for (final task in reminders) {
      final index = task.quadrantLevel - 1;
      if (index < 0 || index >= sections.length) continue;
      if (!task.isCompleted) pending[index]++;
      if (visibleCategory != null && visibleCategory != index) continue;
      final section = sections[index];
      if (task.isCompleted) {
        section.completed.add(task);
      } else if (index == 3 && isFolded(task)) {
        section.folded.add(task);
      } else {
        section.active.add(task);
      }
    }
    return TaskBoardData._(sections, pending);
  }
}

class TaskSectionData {
  final active = <Reminder>[];
  final completed = <Reminder>[];
  final folded = <Reminder>[];
  bool get isEmpty => active.isEmpty && completed.isEmpty && folded.isEmpty;

  int rowCount({
    required bool completedExpanded,
    required bool foldedExpanded,
  }) =>
      active.length +
      (completed.isEmpty ? 0 : 1 + (completedExpanded ? completed.length : 0)) +
      (folded.isEmpty ? 0 : 1 + (foldedExpanded ? folded.length : 0));

  Object rowAt(
    int index, {
    required bool completedExpanded,
    required bool foldedExpanded,
  }) {
    RangeError.checkValidIndex(
      index,
      this,
      'index',
      rowCount(
        completedExpanded: completedExpanded,
        foldedExpanded: foldedExpanded,
      ),
    );
    if (index < active.length) return active[index];
    index -= active.length;
    if (completed.isNotEmpty) {
      if (index == 0) return 'completed';
      index--;
      if (completedExpanded) {
        if (index < completed.length) return completed[index];
        index -= completed.length;
      }
    }
    if (index == 0) return 'folded';
    return folded[index - 1];
  }
}
