import '../models/reminder.dart';
import '../models/task_details.dart';

abstract final class ScheduledTaskReminder {
  static const leadMinutes = [5, 10, 15];
  static const defaultLeadMinutes = 10;
  static const _leadKey = 'reminder_lead_minutes';

  static DateTime? timeFor(
    DateTime? event,
    DateTime now, {
    int lead = defaultLeadMinutes,
  }) {
    if (event == null || !event.isAfter(now)) return null;
    for (final minutes in leadMinutes.reversed.where(
      (value) => value <= lead,
    )) {
      final reminder = event.subtract(Duration(minutes: minutes));
      if (reminder.isAfter(now)) return reminder;
    }
    return event;
  }

  static DateTime? defaultTime(DateTime? event, DateTime now) =>
      timeFor(event, now);

  static bool canSetLead(Reminder reminder) =>
      reminder.details.kind == 'task' &&
      reminder.details.planId == null &&
      reminder.details.data['ordinary_series'] == null &&
      !reminder.reviewNotificationsEnabled;

  static int? leadOf(Reminder reminder) {
    final lead = reminder.details.data[_leadKey];
    final event = reminder.eventTime;
    final alarm = reminder.triggerTime;
    if (!canSetLead(reminder) ||
        lead is! int ||
        !leadMinutes.contains(lead) ||
        event == null ||
        alarm == null ||
        reminder.timeOrigin == ReminderTimeOrigin.aiSuggested ||
        reminder.snoozedAt != null) {
      return null;
    }
    // A separate alarm change (for example a manual override elsewhere) may
    // have left the previous preference behind. Check the effective time too.
    final offset = event.difference(alarm);
    return offset == Duration.zero ||
            leadMinutes.any(
              (value) => value <= lead && offset == Duration(minutes: value),
            )
        ? lead
        : null;
  }

  static TaskDetails withLead(TaskDetails details, int? lead) {
    if (details.data[_leadKey] == lead) return details;
    final data = {...details.data}..remove(_leadKey);
    if (lead != null) data[_leadKey] = lead;
    return details.patch({'data': data});
  }
}
