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
