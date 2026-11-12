import 'dart:convert';
import '../models/reminder.dart';
import '../models/study_plan_group.dart';
import '../models/vocabulary_entry.dart';
import 'learning_queue_service.dart';

class StudyScheduleConflict implements Exception {}

class StudyScheduleStale implements Exception {}

class StudyScheduleRecurring implements Exception {}

class StudySchedulePreview {
  StudySchedulePreview._(
    this.groups,
    this.days,
    this.at,
    this.changes,
    this.progressFingerprint,
  );
  final List<StudyPlanGroup> groups;
  final int days;
  final DateTime at;
  final List<Reminder> changes;
  final String progressFingerprint;
}

/// Builds a bounded, read-only preview; the notifier rechecks it in SQLite.
class StudyScheduleService {
  static DateTime shiftCalendar(DateTime date, int days) {
    final local = date.toLocal();
    final day = DateTime.utc(local.year, local.month, local.day + days);
    if (day.year < 1900 || day.year > 2200) {
      throw const FormatException('Date outside supported range');
    }
    final next = DateTime(
      day.year,
      day.month,
      day.day,
      local.hour,
      local.minute,
      local.second,
      local.millisecond,
      local.microsecond,
    );
    // DST gaps must not silently change the user's clock time.
    if (next.year != day.year ||
        next.month != day.month ||
        next.day != day.day ||
        next.hour != local.hour ||
        next.minute != local.minute) {
      throw const FormatException('Local clock time does not exist');
    }
    return date.isUtc ? next.toUtc() : next;
  }

  static StudySchedulePreview preview(
    List<Reminder> all,
    List<StudyPlanGroup> expected,
    int days, {
    DateTime? now,
  }) {
    if (days == 0 || days.abs() > 365) {
      throw const FormatException('Shift must be between -365 and 365 days');
    }
    final groups = StudyPlanGroup.freezeSelection(expected);
    if (!StudyPlanGroup.matchesSnapshots(all, groups)) {
      throw StudyScheduleStale();
    }
    final targets = [for (final g in groups) ...g.pending];
    if (targets.isEmpty) throw const FormatException('No pending batches');
    if (targets.any((r) => r.isRecurring || r.details.repeat != null)) {
      throw StudyScheduleRecurring();
    }
    final ids = targets.map((r) => r.id).toSet();
    final keys = <String>{
      for (final r in targets)
        for (final word in VocabularyEntry.parseNotes(r.taskSummary ?? ''))
          LearningQueueService.wordKey(word.word),
    };
    final Map<String, WordProgress> progress;
    try {
      progress = LearningQueueService.progress(all);
    } on TypeError {
      throw const FormatException('Invalid word progress');
    }
    final affected = keys.where(progress.containsKey).toSet();
    // A learned word has shared progress. Its other live batches must be part
    // of the same explicit selection, even when those batches are paused.
    for (final row in all.where(
      (r) =>
          !ids.contains(r.id) &&
          r.isVisible &&
          !r.isCompleted &&
          r.spacedRepetitionLevel > 0,
    )) {
      if (VocabularyEntry.parseNotes(
        row.taskSummary ?? '',
      ).any((w) => affected.contains(LearningQueueService.wordKey(w.word)))) {
        throw StudyScheduleConflict();
      }
    }
    final ordered = affected.toList()..sort();
    final fingerprint = jsonEncode({
      for (final key in ordered) key: progress[key]!.toJson(),
    });
    final at = now ?? DateTime.now();
    final shifted = <String, WordProgress>{};
    for (final key in ordered) {
      final p = progress[key]!;
      final lastEdit = p.rescheduledAt ?? p.reviewed;
      shifted[key] = WordProgress(
        level: p.level,
        due: shiftCalendar(p.due, days),
        reviewed: p.reviewed,
        firstReviewed: p.firstReviewed,
        reviews: p.reviews,
        grade: p.grade,
        rescheduledAt: at.isAfter(lastEdit)
            ? at
            : lastEdit.add(const Duration(microseconds: 1)),
      );
    }
    final changes = <Reminder>[];
    for (final row in targets) {
      final local = LearningQueueService.decode(row.wordProgressJson);
      var progressChanged = false;
      for (final word in VocabularyEntry.parseNotes(row.taskSummary ?? '')) {
        final key = LearningQueueService.wordKey(word.word);
        if (shifted.containsKey(key)) {
          local[key] = shifted[key]!;
          progressChanged = true;
        }
      }
      if (local.length > 20) {
        throw const FormatException('Too much word progress');
      }
      if (row.nextReviewAt == null && row.triggerTime == null) {
        throw const FormatException('Batch has no date');
      }
      changes.add(
        row.copyWith(
          nextReviewAt: row.nextReviewAt == null
              ? null
              : shiftCalendar(row.nextReviewAt!, days),
          triggerTime: row.triggerTime == null
              ? null
              : shiftCalendar(row.triggerTime!, days),
          eventTime: row.eventTime == null
              ? null
              : shiftCalendar(row.eventTime!, days),
          timeOrigin: row.triggerTime == null
              ? row.timeOrigin
              : ReminderTimeOrigin.manual,
          wordProgressJson: progressChanged
              ? jsonEncode({
                  for (final e in local.entries) e.key: e.value.toJson(),
                })
              : row.wordProgressJson,
          noticeRevision: row.noticeRevision + 1,
          noticeAcknowledgedAt: null,
          upcomingDismissedAt: null,
          snoozedAt: null,
          detailsJson: row.details
              .record(
                'study_dates_shifted',
                at,
                scheduled: row.nextReviewAt ?? row.triggerTime,
                note: 'days:$days',
              )
              .encode(),
        ),
      );
    }
    return StudySchedulePreview._(
      groups,
      days,
      at,
      List.unmodifiable(changes),
      fingerprint,
    );
  }
}
