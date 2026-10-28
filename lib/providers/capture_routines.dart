part of 'providers.dart';

extension CaptureRoutines on RemindersNotifier {
  List<Reminder> _independentCaptures(List<Reminder> rows, DateTime now) {
    final expanded = <Reminder>[];
    for (final row in rows) {
      if (!row.isRecurring ||
          row.details.kind != 'task' ||
          row.details.planId != null ||
          row.spacedRepetitionLevel > 0 ||
          row.reviewNotificationsEnabled ||
          row.wordProgressJson != null ||
          row.contextTrigger != null ||
          row.linkedTaskIds.isNotEmpty) {
        expanded.add(row);
        continue;
      }
      final template = _captureTemplate(row);
      final schedule = OrdinarySeries.schedule(template, now);
      expanded.addAll([schedule.owner, ...schedule.occurrences]);
    }
    if (expanded.length > 2000) {
      throw const FormatException('Too many captured dates');
    }
    return expanded;
  }

  Reminder _captureTemplate(Reminder row) {
    final event = row.eventTime, alarm = row.triggerTime;
    if (row.recurrenceRule != 'workday' || event == null || alarm == null) {
      return row;
    }
    final basis = alarm.isUtc ? event.toUtc() : event.toLocal();
    final offset = DateTime.utc(
      basis.year,
      basis.month,
      basis.day,
    ).difference(DateTime.utc(alarm.year, alarm.month, alarm.day)).inDays;
    if (offset == 0) return row;
    final old = row.details.repeat ?? const RepeatWindow();
    if (old.interval != 1 || old.weekdays.isNotEmpty) {
      throw const FormatException(
        'Review cross-day workday intervals in the plan',
      );
    }
    return row.copyWith(
      recurrenceRule: 'weekly',
      detailsJson: row.details.patch({
        'repeat': RepeatWindow(
          weekdays: [
            for (var day = 1; day <= 5; day++) (day - 1 - offset) % 7 + 1,
          ],
          start: old.start,
          end: old.end,
          anchor: old.anchor,
          exceptions: old.exceptions,
        ).toJson(),
      }).encode(),
    );
  }

  Future<ReminderActionResult> addCapturedReminderForGeneration(
    Reminder row,
    DataGeneration generation, {
    DateTime? now,
  }) async {
    if (!row.isRecurring) return addReminderForGeneration(row, generation);
    final result = await saveOrdinarySeries(
      _captureTemplate(row),
      generation,
      now: now,
    );
    return ReminderActionResult(
      ReminderActionDisposition.applied,
      reminder: _managedReminders.where((e) => e.id == row.id).firstOrNull,
      nativeSyncFailed: result.nativeSyncFailures > 0,
    );
  }
}
