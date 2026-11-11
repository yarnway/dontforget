import '../models/reminder.dart';
import '../models/vocabulary_entry.dart';
import 'learning_queue_service.dart';

class LearningDayLoad {
  LearningDayLoad(this.date);
  final DateTime date;
  int newWords = 0, reviewWords = 0;
  int spentToday = 0, newToday = 0;
  int get total => newWords + reviewWords;
  int excess(int dailyLimit, int newLimit) {
    final totalExcess = (total + spentToday - dailyLimit).clamp(0, total);
    final newExcess = (newWords + newToday - newLimit).clamp(0, newWords);
    return totalExcess > newExcess ? totalExcess : newExcess;
  }
}

/// A read-only projection of known dates, without simulating future feedback.
class LearningWorkloadService {
  static List<LearningDayLoad> project(
    List<Reminder> tasks, {
    required DateTime now,
  }) {
    final local = now.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    final dates = List.generate(
      8,
      (index) => DateTime(today.year, today.month, today.day + index),
    );
    final days = List.generate(7, (i) => LearningDayLoad(dates[i]));
    final Map<String, WordProgress> progress;
    try {
      progress = LearningQueueService.progress(tasks);
    } on TypeError {
      throw const FormatException('Invalid word progress');
    }
    days.first.spentToday = progress.values
        .where((p) => LearningQueueService.sameDay(p.reviewed, today))
        .length;
    days.first.newToday = progress.values
        .where((p) => LearningQueueService.sameDay(p.firstReviewed, today))
        .length;
    final scheduled = <String, DateTime>{};
    for (final task in tasks) {
      if (!task.isVisible ||
          task.details.paused ||
          task.isCompleted ||
          task.spacedRepetitionLevel <= 0) {
        continue;
      }
      for (final word in VocabularyEntry.parseNotes(task.taskSummary ?? '')) {
        final key = LearningQueueService.wordKey(word.word);
        final p = progress[key];
        var due = (p?.due ?? task.nextReviewAt ?? today).toLocal();
        // Match today's queue: a word reviewed today cannot reappear today.
        if (p != null &&
            LearningQueueService.sameDay(p.reviewed, today) &&
            due.isBefore(dates[1])) {
          due = dates[1];
        }
        if (scheduled[key] == null || due.isBefore(scheduled[key]!)) {
          scheduled[key] = due;
        }
      }
    }
    for (final entry in scheduled.entries) {
      for (var i = 0; i < days.length; i++) {
        if (entry.value.isBefore(dates[i + 1])) {
          if (progress.containsKey(entry.key)) {
            days[i].reviewWords++;
          } else {
            days[i].newWords++;
          }
          break;
        }
      }
    }
    return List.unmodifiable(days);
  }
}
