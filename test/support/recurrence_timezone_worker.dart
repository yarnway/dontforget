import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/models/reminder.dart';

// A fresh process is required: Dart caches the host's local timezone.
void main() {
  final zone = Platform.environment['TZ']!;
  final dates = switch (zone) {
    'America/New_York' => [(2026, 3, 7), (2026, 10, 31)],
    'Europe/Berlin' => [(2026, 3, 28), (2026, 10, 24)],
    'Australia/Lord_Howe' => [(2026, 10, 3), (2026, 4, 4)],
    _ => [(2026, 3, 7), (2026, 10, 31)],
  };
  Reminder recurring(DateTime anchor) => Reminder(
    id: 'timezone-synthetic',
    taskTitle: 'Synthetic calendar boundary',
    quadrantLevel: 3,
    isRecurring: true,
    recurrenceRule: 'daily',
    triggerTime: anchor,
    recurrenceAnchorTime: anchor,
  );
  final rows = dates.map((date) {
    final anchor = DateTime(date.$1, date.$2, date.$3, 9, 15, 30, 123, 456);
    final task = recurring(anchor);
    final next = task.getNextOccurrence(after: anchor)!;
    final restored = Reminder.fromJson(task.toJson());
    return {
      'anchor': anchor.toIso8601String(),
      'next': next.toIso8601String(),
      'delta_minutes': next.difference(anchor).inMinutes,
      'offset_minutes': next.timeZoneOffset.inMinutes,
      'restored_next': restored
          .getNextOccurrence(after: anchor)!
          .toIso8601String(),
    };
  }).toList();
  final utc = recurring(DateTime.utc(2026, 3, 7, 9, 15, 30, 123, 456));
  final utcRestored = Reminder.fromJson(utc.toJson());
  final gap = recurring(DateTime(2026, 3, 7, 2, 30));
  final gapNext = gap.getNextOccurrence(after: gap.triggerTime)!;
  final fold = recurring(DateTime(2026, 10, 31, 1, 30));
  stdout.writeln(
    jsonEncode({
      'zone': zone,
      'daily': rows,
      'utc_next': utcRestored
          .getNextOccurrence(after: utc.triggerTime)!
          .toIso8601String(),
      'spring_gap_next': gapNext.toIso8601String(),
      'after_gap_next': gap
          .getNextOccurrence(after: gapNext)!
          .toIso8601String(),
      'after_fold_next': fold
          .getNextOccurrence(after: DateTime.utc(2026, 11, 1, 6, 45))!
          .toIso8601String(),
    }),
  );
}
