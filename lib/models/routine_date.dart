import 'calendar_exceptions.dart';
import 'reminder.dart';
import 'task_details.dart';

/// The original scheduled date is retained even when its alarm is snoozed.
class RoutineDate {
  const RoutineDate(this.row, this.scheduled);
  final Reminder row;
  final DateTime scheduled;
  static RoutineDate? from(Reminder row) {
    if (row.details.planId == null) return null;
    final at = row.details.data['ordinary_occurrence'] == true
        ? TaskDetails.date(row.details.data['scheduled_at'])
        : const ['departure', 'medication'].contains(row.details.kind)
        ? row.eventTime ?? row.triggerTime
        : null;
    return at == null ? null : RoutineDate(row, at);
  }

  String get dateKey => CalendarExceptions.key(scheduled.toLocal());
  String get status => !row.isVisible
      ? 'removed'
      : row.isCompleted
      ? 'handled'
      : 'pending';
  static List<RoutineDate> select(
    Iterable<Reminder> rows,
    String planId,
    DateTime now, {
    String view = 'past',
    String status = 'all',
    DateTime? from,
    DateTime? to,
    String query = '',
  }) {
    final today = CalendarExceptions.key(now.toLocal());
    final start = from == null ? null : CalendarExceptions.key(from.toLocal());
    final end = to == null ? null : CalendarExceptions.key(to.toLocal());
    final result = <RoutineDate>[];
    for (final row in rows) {
      if (row.details.planId != planId) continue;
      final entry = RoutineDate.from(row);
      if (entry == null ||
          (status != 'all' && entry.status != status) ||
          (view == 'past' && entry.dateKey.compareTo(today) > 0) ||
          (view == 'future' && entry.dateKey.compareTo(today) < 0) ||
          (start != null && entry.dateKey.compareTo(start) < 0) ||
          (end != null && entry.dateKey.compareTo(end) > 0) ||
          !'${row.taskTitle} ${entry.dateKey}'.toLowerCase().contains(
            query.trim().toLowerCase(),
          )) {
        continue;
      }
      result.add(entry);
    }
    result.sort((a, b) {
      final order = a.scheduled.compareTo(b.scheduled);
      return (order == 0 ? a.row.id.compareTo(b.row.id) : order) *
          (view == 'past' ? -1 : 1);
    });
    return result;
  }
}
