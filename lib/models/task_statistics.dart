import 'reminder.dart';

/// One traversal per task revision; bounded title samples also feed reviews.
class TaskStatistics {
  TaskStatistics._(
    this.total,
    this.completed,
    this.categories,
    this.completedTitles,
    this.pendingTitles,
  );

  factory TaskStatistics.from(Iterable<Reminder> reminders) {
    var total = 0;
    var completed = 0;
    final categories = List.filled(4, 0);
    final doneTitles = <String>[];
    final todoTitles = <String>[];
    for (final task in reminders) {
      total++;
      if (task.isCompleted) completed++;
      if (task.quadrantLevel >= 1 && task.quadrantLevel <= 4) {
        categories[task.quadrantLevel - 1]++;
      }
      final sample = task.isCompleted ? doneTitles : todoTitles;
      if (sample.length < 6) {
        sample.add(String.fromCharCodes(task.taskTitle.runes.take(160)));
      }
    }
    return TaskStatistics._(
      total,
      completed,
      List.unmodifiable(categories),
      List.unmodifiable(doneTitles),
      List.unmodifiable(todoTitles),
    );
  }

  final int total;
  final int completed;
  final List<int> categories;
  final List<String> completedTitles;
  final List<String> pendingTitles;
  int get pending => total - completed;
  double get completionFraction => total == 0 ? 0 : completed / total;
  int get completionPercent => (completionFraction * 100).round();
}
