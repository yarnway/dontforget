import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'reminder.dart';
import 'vocabulary_entry.dart';

enum StudyExam { cet4, cet6, postgraduate, ielts, toefl }

/// Short, reviewable batches. Model output never controls IDs or executable data.
class StudyRequest {
  const StudyRequest({
    this.exam = StudyExam.cet4,
    this.days = 3,
    this.wordsPerDay = 10,
    this.notes = '',
    this.language = 'zh',
  });
  final StudyExam exam;
  final int days, wordsPerDay;
  final String notes, language;

  void validate() {
    if (!const [1, 3, 7].contains(days) ||
        !const [5, 10, 15, 20].contains(wordsPerDay) ||
        notes.length > 1000 ||
        !const ['zh', 'en', 'ja'].contains(language)) {
      throw const FormatException('Invalid study preferences');
    }
  }
}

class StudyBatch {
  const StudyBatch({required this.title, required this.content});
  final String title, content;
  StudyBatch copyWith({String? title, String? content}) =>
      StudyBatch(title: title ?? this.title, content: content ?? this.content);
  bool get isValid =>
      title.trim().isNotEmpty &&
      title.length <= 120 &&
      content.trim().isNotEmpty &&
      content.length <= 24000;
}

class StudyPlan {
  StudyPlan({
    required this.batches,
    this.modelLabel,
    this.usedFallback = false,
    this.suggestedMinute = 20 * 60,
  }) : id = const Uuid().v4(),
       createdAt = DateTime.now();
  final String id;
  final DateTime createdAt;
  final List<StudyBatch> batches;
  final String? modelLabel;
  final bool usedFallback;
  final int suggestedMinute;

  static int parseSuggestedMinute(String source) {
    if (source.length > 120000) {
      throw const FormatException('Study plan too large');
    }
    final data = jsonDecode(source);
    final value = data is Map ? data['daily_time'] : null;
    if (value is! String ||
        !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) {
      throw const FormatException('Invalid study time');
    }
    final parts = value.split(':').map(int.parse).toList();
    return parts[0] * 60 + parts[1];
  }

  static List<StudyBatch> parse(String source, StudyRequest request) {
    request.validate();
    if (source.length > 120000) {
      throw const FormatException('Study plan too large');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['days'] is! List) {
      throw const FormatException('Missing study days');
    }
    final days = decoded['days'] as List;
    if (days.length != request.days) {
      throw const FormatException('Incorrect day count');
    }
    final seen = <String>{};
    String field(Object? value, int max) {
      if (value is! String || value.trim().isEmpty || value.length > max) {
        throw const FormatException('Invalid vocabulary field');
      }
      return value.trim();
    }

    return List.unmodifiable([
      for (final day in days)
        (() {
          if (day is! Map ||
              day['words'] is! List ||
              (day['words'] as List).length != request.wordsPerDay) {
            throw const FormatException('Incorrect vocabulary count');
          }
          final title = field(day['title'], 120);
          final lines = <String>[];
          for (final word in day['words']) {
            if (word is! Map) throw const FormatException('Invalid vocabulary');
            final entry = VocabularyEntry.fromModel(word);
            final term = entry.word;
            if (!seen.add(term.toLowerCase())) {
              throw const FormatException('Duplicate vocabulary');
            }
            lines.add(entry.toNotes());
          }
          final batch = StudyBatch(title: title, content: lines.join('\n\n'));
          if (!batch.isValid) {
            throw const FormatException('Invalid study batch');
          }
          return batch;
        })(),
    ]);
  }

  List<Reminder> reminders({
    required List<StudyBatch> edited,
    required DateTime firstReminder,
    DateTime? now,
  }) {
    if (edited.length != batches.length ||
        edited.isEmpty ||
        edited.length > 7 ||
        edited.any((b) => !b.isValid) ||
        !firstReminder.isAfter(now ?? DateTime.now())) {
      throw const FormatException(
        'Review the plan and its first reminder time',
      );
    }
    // Calendar construction keeps the selected local hour across DST.
    return [
      for (var i = 0; i < edited.length; i++)
        (() {
          final date = firstReminder.isUtc
              ? DateTime.utc(
                  firstReminder.year,
                  firstReminder.month,
                  firstReminder.day + i,
                  firstReminder.hour,
                  firstReminder.minute,
                )
              : DateTime(
                  firstReminder.year,
                  firstReminder.month,
                  firstReminder.day + i,
                  firstReminder.hour,
                  firstReminder.minute,
                );
          return Reminder(
            id: '$id-$i',
            taskTitle: edited[i].title.trim(),
            taskSummary: edited[i].content.trim(),
            quadrantLevel: 2,
            triggerTime: date,
            nextReviewAt: date,
            spacedRepetitionLevel: 1,
            reviewNotificationsEnabled: true,
            createdAt: createdAt,
          );
        })(),
    ];
  }
}
