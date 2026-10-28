import 'dart:convert';
import 'reminder.dart';

class WeeklyTaskReview {
  WeeklyTaskReview._(
    this.start,
    this.end,
    this.counts,
    this.activeDays,
    this.frequentPostponements,
  );
  final DateTime start, end;
  final Map<String, int> counts;
  final int activeDays;
  final List<({String title, int count})> frequentPostponements;

  factory WeeklyTaskReview.build(
    Iterable<Reminder> rows, {
    required DateTime weekContaining,
    required DateTime now,
    String query = '',
  }) {
    final day = weekContaining.toLocal();
    final start = DateTime(day.year, day.month, day.day - day.weekday + 1);
    final end = DateTime(start.year, start.month, start.day + 7);
    final counts = {
      for (final key in [
        'completed',
        'skipped',
        'snoozed',
        'taken',
        'not_taken',
        'pause',
        'resume',
      ])
        key: 0,
    };
    final days = <String>{}, seen = <String>{};
    final postponements = <String, ({String title, int count})>{};
    final q = query.trim().toLowerCase();
    bool inside(DateTime date) =>
        !date.toLocal().isBefore(start) &&
        date.toLocal().isBefore(end) &&
        !date.isAfter(now);
    void add(String action, DateTime at) {
      if (!inside(at)) return;
      counts[action] = counts[action]! + 1;
      final local = at.toLocal();
      days.add('${local.year}-${local.month}-${local.day}');
    }

    for (final row in rows) {
      if (row.details.data['learning_archive'] == true ||
          !'${row.taskTitle} ${row.details.project} ${row.details.tags.join(' ')}'
              .toLowerCase()
              .contains(q)) {
        continue;
      }
      for (final event in row.details.history) {
        if (!inside(event.at) ||
            !counts.containsKey(event.action) ||
            event.action == 'taken' ||
            event.action == 'not_taken' ||
            (row.details.planId != null &&
                (event.action == 'pause' || event.action == 'resume'))) {
          continue;
        }
        final key = jsonEncode([
          row.id,
          event.action,
          event.at.toIso8601String(),
          event.scheduled?.toIso8601String(),
          event.note,
        ]);
        if (!seen.add(key)) continue;
        add(event.action, event.at);
        if (event.action == 'snoozed') {
          postponements[row.id] = (
            title: row.taskTitle,
            count: (postponements[row.id]?.count ?? 0) + 1,
          );
        }
      }
      // A dose is counted once by its latest outcome, so time corrections do
      // not fabricate additional administrations. Legacy entries use log time.
      if (row.details.kind == 'medication' &&
          row.isCompleted &&
          seen.add('dose:${row.id}')) {
        final outcome = row.details.effectiveDoseOutcome;
        if (outcome == 'taken' || outcome == 'not_taken') {
          final at = outcome == 'taken'
              ? row.details.actualDoseTakenAt ?? row.details.completedAt
              : row.details.completedAt;
          final fallback = row.details.history
              .where((e) => e.action == outcome)
              .lastOrNull
              ?.at;
          if (at != null || fallback != null) add(outcome!, at ?? fallback!);
        }
      }
    }
    final frequent = postponements.values.where((e) => e.count >= 2).toList()
      ..sort(
        (a, b) => b.count != a.count
            ? b.count.compareTo(a.count)
            : a.title.compareTo(b.title),
      );
    return WeeklyTaskReview._(
      start,
      end,
      Map.unmodifiable(counts),
      days.length,
      List.unmodifiable(frequent.take(5)),
    );
  }
}
