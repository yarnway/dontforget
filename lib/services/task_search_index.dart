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
      if (!task.isWorkspaceItem) continue;
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
          old.task.subTasks == task.subTasks &&
          old.task.detailsJson == task.detailsJson;
      final entry = (
        task: task,
        position: i,
        fields: unchanged
            ? old.fields
            : [
                task.taskTitle.toLowerCase(),
                task.details.project.toLowerCase(),
                ...task.details.tags.map((tag) => tag.toLowerCase()),
                ...task.details.checklist.map(
                  (item) => item.label.toLowerCase(),
                ),
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

  static bool _matchesFilter(
    Reminder task,
    TaskSearchFilter filter,
    DateTime localNow,
    DateTime today,
    DateTime tomorrow,
  ) {
    final due = task.triggerTime;
    return switch (filter) {
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
  }

  /// Projects matching tasks and per-filter counts in one single pass using the
  /// exact same filter predicates, so chip counts always match displayed rows.
  ({List<Reminder> results, Map<TaskSearchFilter, int> counts}) project(
    String query, {
    TaskSearchFilter filter = TaskSearchFilter.all,
    TaskSearchSort sort = TaskSearchSort.source,
    bool includeAllWhenEmpty = false,
    DateTime? now,
  }) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty && !includeAllWhenEmpty) {
      return (
        results: const [],
        counts: const {
          TaskSearchFilter.all: 0,
          TaskSearchFilter.pending: 0,
          TaskSearchFilter.today: 0,
          TaskSearchFilter.overdue: 0,
          TaskSearchFilter.completed: 0,
        },
      );
    }
    final terms = normalized.isEmpty
        ? const <String>[]
        : normalized.split(_whitespace);
    final localNow = (now ?? DateTime.now()).toLocal();
    final today = DateTime(localNow.year, localNow.month, localNow.day);
    // Calendar boundaries remain correct on 23- and 25-hour local days.
    final tomorrow = DateTime(localNow.year, localNow.month, localNow.day + 1);
    final matches = <_Entry>[];
    var allCount = 0;
    var pendingCount = 0;
    var todayCount = 0;
    var overdueCount = 0;
    var completedCount = 0;
    for (final entry in _entries) {
      if (terms.isNotEmpty &&
          !terms.every(
            (term) => entry.fields.any((field) => field.contains(term)),
          )) {
        continue;
      }
      final task = entry.task;
      allCount++;
      if (task.isCompleted) {
        completedCount++;
      } else {
        pendingCount++;
        final due = task.triggerTime;
        if (due != null) {
          if (!due.isBefore(today) && due.isBefore(tomorrow)) {
            todayCount++;
          }
          if (due.isBefore(localNow)) {
            overdueCount++;
          }
        }
      }
      if (_matchesFilter(task, filter, localNow, today, tomorrow)) {
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
    return (
      results: [for (final entry in matches) entry.task],
      counts: {
        TaskSearchFilter.all: allCount,
        TaskSearchFilter.pending: pendingCount,
        TaskSearchFilter.today: todayCount,
        TaskSearchFilter.overdue: overdueCount,
        TaskSearchFilter.completed: completedCount,
      },
    );
  }

  List<Reminder> search(
    String query, {
    TaskSearchFilter filter = TaskSearchFilter.all,
    TaskSearchSort sort = TaskSearchSort.source,
    bool includeAllWhenEmpty = false,
    DateTime? now,
  }) => project(
    query,
    filter: filter,
    sort: sort,
    includeAllWhenEmpty: includeAllWhenEmpty,
    now: now,
  ).results;

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
