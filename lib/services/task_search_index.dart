import '../models/reminder.dart';

enum TaskSearchFilter { all, pending, today, overdue, completed }

enum TaskSearchSort { source, dueSoonest, newest }

typedef _Entry = ({Reminder task, List<String> fields, int position});

/// An immutable search snapshot. Unchanged text shares its normalized fields
/// with the previous snapshot, while every entry uses the current task object.
class TaskSearchIndex {
  TaskSearchIndex(List<Reminder> reminders, {TaskSearchIndex? previous}) {
    for (var i = 0; i < reminders.length; i++) {
      final task = reminders[i];
      final old = previous?._byId[task.id];
      if (old != null && identical(old.task, task) && old.position == i) {
        _entries.add(old);
        _byId[task.id] = old;
        continue;
      }
      final unchanged =
          old != null &&
          old.task.taskTitle == task.taskTitle &&
          old.task.taskSummary == task.taskSummary &&
          old.task.sourceText == task.sourceText &&
          old.task.subTasks == task.subTasks;
      final entry = (
        task: task,
        position: i,
        fields: unchanged
            ? old.fields
            : [
                task.taskTitle.toLowerCase(),
                if (task.taskSummary != null) task.taskSummary!.toLowerCase(),
                if (task.sourceText != null) task.sourceText!.toLowerCase(),
                ...task.getSubTasksList().map((text) => text.toLowerCase()),
              ],
      );
      _entries.add(entry);
      _byId[task.id] = entry;
    }
  }

  final List<_Entry> _entries = [];
  final Map<String, _Entry> _byId = {};
  static final _whitespace = RegExp(r'\s+');

  List<Reminder> search(
    String query, {
    TaskSearchFilter filter = TaskSearchFilter.all,
    TaskSearchSort sort = TaskSearchSort.source,
    bool includeAllWhenEmpty = false,
    DateTime? now,
  }) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty && !includeAllWhenEmpty) return const [];
    final terms = normalized.isEmpty
        ? const <String>[]
        : normalized.split(_whitespace);
    final localNow = (now ?? DateTime.now()).toLocal();
    final today = DateTime(localNow.year, localNow.month, localNow.day);
    // Calendar boundaries remain correct on 23- and 25-hour local days.
    final tomorrow = DateTime(localNow.year, localNow.month, localNow.day + 1);
    final matches = <_Entry>[];
    for (final entry in _entries) {
      final task = entry.task;
      final due = task.triggerTime;
      final accepted = switch (filter) {
        TaskSearchFilter.all => true,
        TaskSearchFilter.pending => !task.isCompleted,
        TaskSearchFilter.completed => task.isCompleted,
        TaskSearchFilter.today =>
          !task.isCompleted &&
              due != null &&
              !due.isBefore(today) &&
              due.isBefore(tomorrow),
        TaskSearchFilter.overdue =>
          !task.isCompleted && due != null && due.isBefore(localNow),
      };
      if (accepted &&
          terms.every(
            (term) => entry.fields.any((field) => field.contains(term)),
          )) {
        matches.add(entry);
      }
    }
    if (sort != TaskSearchSort.source) {
      matches.sort((a, b) {
        final comparison = switch (sort) {
          TaskSearchSort.dueSoonest => _compareDates(
            a.task.triggerTime,
            b.task.triggerTime,
          ),
          TaskSearchSort.newest => _compareDates(
            a.task.createdAt,
            b.task.createdAt,
            descending: true,
          ),
          TaskSearchSort.source => 0,
        };
        return comparison == 0 ? a.position.compareTo(b.position) : comparison;
      });
    }
    return [for (final entry in matches) entry.task];
  }

  static int _compareDates(
    DateTime? a,
    DateTime? b, {
    bool descending = false,
  }) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return descending ? b.compareTo(a) : a.compareTo(b);
  }
}
