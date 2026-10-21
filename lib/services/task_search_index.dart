import '../models/reminder.dart';

/// A snapshot of searchable fields. Decode subtasks once per data revision,
/// rather than for every keystroke or unrelated UI update.
class TaskSearchIndex {
  TaskSearchIndex(List<Reminder> reminders)
    : _entries = [
        for (final task in reminders)
          (
            task: task,
            fields: [
              task.taskTitle.toLowerCase(),
              if (task.taskSummary != null) task.taskSummary!.toLowerCase(),
              ...task.getSubTasksList().map((text) => text.toLowerCase()),
            ],
          ),
      ];

  final List<({Reminder task, List<String> fields})> _entries;

  List<Reminder> search(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    return [
      for (final entry in _entries)
        if (entry.fields.any((field) => field.contains(normalized))) entry.task,
    ];
  }
}
