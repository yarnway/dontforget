import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/quick_reminder_parser.dart';
import 'inline_feedback.dart';

/// Shared snooze / postpone time resolver used by [ReminderNoticePanel] and
/// [TaskCard] so custom date/time selection always defaults to a future time
/// and surfaces a clear warning instead of silently dropping past picks.
Future<DateTime?> pickSnoozeUntil(
  BuildContext context,
  String choice, {
  DateTime? now,
  DateTime? base,
}) async {
  final current = now ?? DateTime.now();
  final anchor = base ?? current;
  DateTime? until = switch (choice) {
    '15' => anchor.add(const Duration(minutes: 15)),
    '60' => anchor.add(const Duration(hours: 1)),
    'evening' => QuickReminderParser.tonight(current),
    'morning' => QuickReminderParser.tomorrowMorning(current),
    _ => null,
  };
  if (choice == 'custom') {
    final initial = anchor.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(current.year, current.month, current.day),
      lastDate: DateTime(current.year + 10),
    );
    if (!context.mounted || date == null) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!context.mounted || time == null) return null;
    until = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
  if (!context.mounted || until == null) return null;
  if (!until.isAfter(DateTime.now())) {
    InlineFeedback.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).get('chooseFutureTime')),
      ),
      tone: FeedbackTone.warning,
    );
    return null;
  }
  return until;
}
