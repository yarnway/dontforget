import 'dart:convert';
import '../models/reminder.dart';
import '../models/vocabulary_entry.dart';
import 'learning_queue_service.dart';

class LearningForecastDay {
  const LearningForecastDay({
    required this.date,
    required this.newWords,
    required this.reviewWords,
    required this.deferred,
  });
  final DateTime date;
  final int newWords, reviewWords, deferred;
  int get total => newWords + reviewWords;
}

/// Seven days of hypothetical feedback, using the real queue and grade rules.
/// All changes are confined to shadow rows; no persistence or native work occurs.
class LearningForecastService {
  static List<LearningForecastDay> project(
    List<Reminder> tasks, {
    required DateTime now,
    int dailyLimit = 20,
    int newLimit = 10,
    int grade = 2,
    List<int> intervals = const [1, 2, 4, 7, 15],
  }) {
    // Validate even for an empty queue; never display a plausible empty result
    // for damaged preferences or history.
    try {
      LearningQueueService.grade(null, grade, now, now, intervals: intervals);
      return _project(tasks, now, dailyLimit, newLimit, grade, intervals);
    } on TypeError {
      throw const FormatException('Invalid learning forecast data');
    }
  }

  static List<LearningForecastDay> _project(
    List<Reminder> tasks,
    DateTime now,
    int dailyLimit,
    int newLimit,
    int grade,
    List<int> intervals,
  ) {
    final local = now.toLocal();
    final shadow = tasks.toList();
    final progress = LearningQueueService.progress(tasks);
    if (progress.values.any((word) => word.reviewed.isAfter(now))) {
      throw const FormatException('Review history is in the future');
    }
    final words = <int, Set<String>>{};
    final references = <String, List<int>>{};
    final byId = <String, int>{};
    for (var i = 0; i < shadow.length; i++) {
      final task = shadow[i];
      if (byId.containsKey(task.id)) {
        throw const FormatException('Duplicate task identity');
      }
      byId[task.id] = i;
      // Match gradeWord: shared feedback also updates paused/hidden batches,
      // while their words remain excluded from the active queue.
      if (task.isCompleted || task.spacedRepetitionLevel <= 0) continue;
      final keys = VocabularyEntry.parseNotes(
        task.taskSummary ?? '',
      ).map((word) => LearningQueueService.wordKey(word.word)).toSet();
      words[i] = keys;
      for (final key in keys) {
        (references[key] ??= []).add(i);
      }
    }
    final result = <LearningForecastDay>[];
    for (var day = 0; day < 7; day++) {
      final at = day == 0
          ? now
          : DateTime(
              local.year,
              local.month,
              local.day + day,
              local.hour,
              local.minute,
              local.second,
            );
      final queue = LearningQueueService.queue(
        shadow,
        now: at,
        dailyLimit: dailyLimit,
        newLimit: newLimit,
      );
      final fresh = queue.items.where((item) => item.progress == null).length;
      result.add(
        LearningForecastDay(
          date: DateTime(
            at.toLocal().year,
            at.toLocal().month,
            at.toLocal().day,
          ),
          newWords: fresh,
          reviewWords: queue.items.length - fresh,
          deferred: queue.deferred,
        ),
      );
      for (final item in queue.items) {
        final target = shadow[byId[item.task.id]!];
        final next = LearningQueueService.grade(
          progress[item.key],
          grade,
          at,
          target.nextReviewAt ?? target.triggerTime ?? at,
          intervals: intervals,
        );
        progress[item.key] = next;
        for (final index in references[item.key] ?? const <int>[]) {
          final row = shadow[index];
          final keys = words[index]!;
          final stored = LearningQueueService.decode(row.wordProgressJson)
            ..removeWhere((key, _) => !keys.contains(key))
            ..[item.key] = next;
          final dates = [
            for (final key in keys)
              progress[key]?.due ?? row.nextReviewAt ?? at,
          ]..sort();
          shadow[index] = row.copyWith(
            wordProgressJson: jsonEncode({
              for (final entry in stored.entries)
                entry.key: entry.value.toJson(),
            }),
            nextReviewAt: dates.first,
          );
        }
      }
    }
    return List.unmodifiable(result);
  }
}
