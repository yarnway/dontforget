import '../../l10n/app_localizations.dart';
import 'package:intl/intl.dart';

/// Render an instant in the device timezone without changing its stored value.
String formatLocalDateTime(
  DateTime value, {
  String pattern = 'yyyy-MM-dd HH:mm',
}) => DateFormat(pattern).format(value.toLocal());

/// Calendar construction preserves the requested wall clock through DST.
DateTime nextReminderClockTime(
  DateTime now,
  int hour, {
  bool tomorrow = false,
}) {
  final today = DateTime(now.year, now.month, now.day, hour);
  return tomorrow || !today.isAfter(now)
      ? DateTime(now.year, now.month, now.day + 1, hour)
      : today;
}

/// A positive sub-minute interval must not be shown as zero or already due.
String formatReminderTimeRemaining(
  AppLocalizations l10n,
  DateTime due,
  DateTime now,
) {
  final diff = due.difference(now);
  if (diff <= Duration.zero) return l10n.get('overdue');
  if (diff.inDays > 0) {
    return l10n
        .get('remainingDaysHours')
        .replaceAll('{days}', '${diff.inDays}')
        .replaceAll('{hours}', '${diff.inHours % 24}');
  }
  if (diff.inHours > 0) {
    return l10n
        .get('remainingHoursMinutes')
        .replaceAll('{hours}', '${diff.inHours}')
        .replaceAll('{minutes}', '${diff.inMinutes % 60}');
  }
  if (diff.inMinutes > 0) {
    return l10n
        .get('remainingMinutes')
        .replaceAll('{minutes}', '${diff.inMinutes}');
  }
  return l10n.get('remainingLessThanMinute');
}
