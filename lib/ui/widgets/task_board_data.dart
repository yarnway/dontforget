import 'dart:typed_data';

import '../../models/reminder.dart';

/// Classify once, then fill exact-sized buckets without growing/copying large
/// reference arrays. Hidden categories retain only counts. Input order and fold
/// decisions are preserved, including for a single-use Iterable.
class TaskBoardData {
  TaskBoardData._(this.sections, this.pending);

  final List<TaskSectionData> sections;
  final List<int> pending;

  factory TaskBoardData.project(
    Iterable<Reminder> reminders, {
    int? visibleCategory,
    required bool Function(Reminder) isFolded,
  }) {
    final tasks = reminders is List<Reminder> ? reminders : reminders.toList();
    final buckets = Uint8List(tasks.length);
    final sizes = List.filled(12, 0);
    final pending = List.filled(4, 0);
    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      final index = task.quadrantLevel - 1;
      buckets[i] = 255;
      if (index < 0 || index >= 4) continue;
      if (!task.isCompleted) pending[index]++;
      if (visibleCategory != null && visibleCategory != index) continue;
      final kind = task.isCompleted
          ? 1
          : (index == 3 && isFolded(task) ? 2 : 0);
      final bucket = index * 3 + kind;
      buckets[i] = bucket;
      sizes[bucket]++;
    }
    final rows = List.generate(
      12,
      (i) => sizes[i] == 0
          ? <Reminder>[]
          : List<Reminder>.filled(sizes[i], tasks.first, growable: false),
    );
    final offsets = List.filled(12, 0);
    for (var i = 0; i < tasks.length; i++) {
      final bucket = buckets[i];
      if (bucket != 255) rows[bucket][offsets[bucket]++] = tasks[i];
    }
    final sections = List.generate(
      4,
      (i) => TaskSectionData._(rows[i * 3], rows[i * 3 + 1], rows[i * 3 + 2]),
    );
    return TaskBoardData._(sections, pending);
  }
}

class TaskSectionData {
  TaskSectionData() : this._([], [], []);
  TaskSectionData._(this.active, this.completed, this.folded);
  final List<Reminder> active;
  final List<Reminder> completed;
  final List<Reminder> folded;
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
