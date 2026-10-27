import 'dart:convert';
import '../models/reminder.dart';
import '../models/vocabulary_entry.dart';
import '../models/stored_datetime.dart';

class WordProgress {
  const WordProgress({
    required this.level,
    required this.due,
    required this.reviewed,
    required this.firstReviewed,
    required this.reviews,
    required this.grade,
  });
  final int level, reviews, grade;
  final DateTime due, reviewed, firstReviewed;
  Map<String, dynamic> toJson() => {
    'level': level,
    'due': due.toIso8601String(),
    'reviewed': reviewed.toIso8601String(),
    'first': firstReviewed.toIso8601String(),
    'reviews': reviews,
    'grade': grade,
  };
  factory WordProgress.fromJson(Map data) {
    final level = data['level'],
        reviews = data['reviews'],
        grade = data['grade'];
    if (level is! int ||
        level < 0 ||
        level > 5 ||
        reviews is! int ||
        reviews < 1 ||
        grade is! int ||
        grade < 0 ||
        grade > 2) {
      throw const FormatException('Invalid word progress');
    }
    final due = tryParseStoredDateTime(data['due']),
        reviewed = tryParseStoredDateTime(data['reviewed']),
        first = tryParseStoredDateTime(data['first']);
    if (due == null ||
        reviewed == null ||
        first == null ||
        first.isAfter(reviewed)) {
      throw const FormatException('Invalid learning dates');
    }
    return WordProgress(
      level: level,
      due: due,
      reviewed: reviewed,
      firstReviewed: first,
      reviews: reviews,
      grade: grade,
    );
  }
}

class LearningItem {
  const LearningItem(this.task, this.word, this.progress);
  final Reminder task;
  final VocabularyEntry word;
  final WordProgress? progress;
  String get key => LearningQueueService.wordKey(word.word);
}

class LearningSnapshot {
  const LearningSnapshot(
    this.items,
    this.dueCount,
    this.completedToday,
    this.newToday,
  );
  final List<LearningItem> items;
  final int dueCount, completedToday, newToday;
  int get deferred => dueCount - items.length;
}

class LearningQueueService {
  static String wordKey(String word) =>
      word.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  static bool sameDay(DateTime a, DateTime b) {
    final x = a.toLocal(), y = b.toLocal();
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  static Map<String, WordProgress> decode(String? source) {
    if (source == null) return {};
    if (source.length > 100000) {
      throw const FormatException('Word progress too large');
    }
    final data = jsonDecode(source);
    if (data is! Map || data.length > 20) {
      throw const FormatException('Invalid word progress');
    }
    return {
      for (final entry in data.entries)
        entry.key as String: WordProgress.fromJson(entry.value as Map),
    };
  }

  static Map<String, WordProgress> progress(Iterable<Reminder> tasks) {
    final all = <String, WordProgress>{};
    for (final task in tasks) {
      for (final entry in decode(task.wordProgressJson).entries) {
        if (all[entry.key] == null ||
            entry.value.reviewed.isAfter(all[entry.key]!.reviewed)) {
          all[entry.key] = entry.value;
        }
      }
    }
    return all;
  }

  static LearningSnapshot queue(
    List<Reminder> tasks, {
    int dailyLimit = 20,
    int newLimit = 10,
    DateTime? now,
  }) {
    if (dailyLimit < 1 ||
        dailyLimit > 100 ||
        newLimit < 0 ||
        newLimit > dailyLimit) {
      throw const FormatException('Invalid learning limits');
    }
    final current = now ?? DateTime.now();
    final local = current.toLocal();
    final tomorrow = DateTime(local.year, local.month, local.day + 1);
    final all = progress(tasks);
    final completed = all.values
        .where((p) => sameDay(p.reviewed, current))
        .length;
    final newToday = all.values
        .where((p) => sameDay(p.firstReviewed, current))
        .length;
    final due = <String, LearningItem>{};
    for (final task in tasks.where(
      (t) =>
          t.isVisible &&
          !t.details.paused &&
          !t.isCompleted &&
          t.spacedRepetitionLevel > 0,
    )) {
      for (final word in VocabularyEntry.parseNotes(task.taskSummary ?? '')) {
        final key = wordKey(word.word), p = all[wordKey(word.word)];
        final eligible = p == null
            ? task.nextReviewAt == null || task.nextReviewAt!.isBefore(tomorrow)
            : !sameDay(p.reviewed, current) && p.due.isBefore(tomorrow);
        if (eligible) due.putIfAbsent(key, () => LearningItem(task, word, p));
      }
    }
    final ordered = due.values.toList()
      ..sort((a, b) {
        if ((a.progress == null) != (b.progress == null)) {
          return a.progress == null ? 1 : -1;
        }
        final grade = (a.progress?.grade ?? 3).compareTo(
          b.progress?.grade ?? 3,
        );
        if (grade != 0) return grade;
        final time = (a.progress?.due ?? a.task.nextReviewAt ?? current)
            .compareTo(b.progress?.due ?? b.task.nextReviewAt ?? current);
        return time == 0 ? a.key.compareTo(b.key) : time;
      });
    final remaining = (dailyLimit - completed).clamp(0, dailyLimit);
    var newRemaining = (newLimit - newToday).clamp(0, newLimit);
    final selected = <LearningItem>[];
    for (final item in ordered) {
      if (selected.length >= remaining) break;
      if (item.progress == null) {
        if (newRemaining == 0) continue;
        newRemaining--;
      }
      selected.add(item);
    }
    return LearningSnapshot(selected, ordered.length, completed, newToday);
  }

  static WordProgress grade(
    WordProgress? previous,
    int grade,
    DateTime now,
    DateTime anchor,
  ) {
    if (grade < 0 || grade > 2) throw const FormatException('Invalid grade');
    final level = grade == 2
        ? ((previous?.level ?? 0) + 1).clamp(1, 5)
        : grade == 1
        ? (previous?.level ?? 0).clamp(0, 5)
        : 0;
    final days = grade < 2 ? 1 : const [1, 1, 2, 4, 7, 15][level];
    final local = now.toLocal(), clock = anchor.toLocal();
    return WordProgress(
      level: level,
      due: DateTime(
        local.year,
        local.month,
        local.day + days,
        clock.hour,
        clock.minute,
      ),
      reviewed: now,
      firstReviewed: previous?.firstReviewed ?? now,
      reviews: (previous?.reviews ?? 0) + 1,
      grade: grade,
    );
  }
}
