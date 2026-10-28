import 'calendar_exceptions.dart';
import 'holiday_calendar.dart';
import 'reminder.dart';
import 'task_details.dart';

/// Explicit opt-in; legacy recurrence remains readable and is never silently migrated.
class OrdinarySeries {
  static const days = 60;
  static bool isOwner(Reminder r) => r.details.data['ordinary_series'] != null;
  static bool isOccurrence(Reminder r) =>
      r.details.data['ordinary_occurrence'] == true;
  static Reminder template(Reminder owner) {
    final raw = owner.details.data['ordinary_series'];
    if (raw is! Map || raw['version'] != 1 || raw['rule'] is! String) {
      throw const FormatException('Invalid ordinary series');
    }
    final due = TaskDetails.date(raw['trigger_anchor']);
    if (due == null) throw const FormatException('Missing recurrence anchor');
    final data = {...owner.details.data}..remove('ordinary_series');
    return owner.copyWith(
      triggerTime: due,
      eventTime: TaskDetails.date(raw['event_anchor']),
      isRecurring: true,
      recurrenceRule: raw['rule'],
      recurrenceAnchorTime: due,
      detailsJson: owner.details.patch({'data': data}).encode(),
    );
  }

  static ({Reminder owner, List<Reminder> occurrences}) schedule(
    Reminder template,
    DateTime now,
  ) {
    if (template.details.kind != 'task' ||
        template.details.planId != null ||
        !template.isRecurring ||
        template.triggerTime == null ||
        template.snoozedAt != null ||
        template.capturePending ||
        template.isCompleted ||
        !template.isVisible) {
      throw const FormatException(
        'Resolve the current task before enabling independent dates',
      );
    }
    final rule = template.recurrenceRule;
    if (!const [
      'daily',
      'workday',
      'weekly',
      'monthly',
      'yearly',
    ].contains(rule)) {
      throw const FormatException('Unsupported recurrence');
    }
    final policy = HolidayPolicy.fromJson(
      template.details.data['holiday_policy'],
    );
    final window = template.details.repeat ?? const RepeatWindow();
    final anchor =
        window.anchor ?? template.recurrenceAnchorTime ?? template.triggerTime!;
    final eventAnchor =
        template.recurrenceEventAnchorTime ??
        template.eventTime?.subtract(template.triggerTime!.difference(anchor));
    if (policy.mode == 'workdays' &&
        (rule != 'workday' || window.interval != 1)) {
      throw const FormatException(
        'Workday calendar requires a daily workday rule',
      );
    }
    final owner = template.copyWith(
      triggerTime: null,
      eventTime: null,
      isRecurring: false,
      recurrenceRule: 'none',
      recurrenceAnchorTime: null,
      recurrenceEventAnchorTime: null,
      snoozedAt: null,
      isPinned: false,
      detailsJson: template.details.patch({
        'data': {
          ...template.details.data,
          'ordinary_series': {
            'version': 1,
            'rule': rule,
            'trigger_anchor': anchor.toIso8601String(),
            'event_anchor': eventAnchor?.toIso8601String(),
          },
        },
      }).encode(),
    );
    final occurrences = <Reminder>[];
    final calculation = template.copyWith(
      triggerTime: anchor,
      recurrenceAnchorTime: anchor,
      detailsJson: template.details.patch({'paused': false}).encode(),
    );
    final localNow = anchor.isUtc ? now.toUtc() : now.toLocal();
    for (var index = 0; index <= days; index++) {
      final day = anchor.isUtc
          ? DateTime.utc(
              localNow.year,
              localNow.month,
              localNow.day + index,
              anchor.hour,
              anchor.minute,
              anchor.second,
              anchor.millisecond,
              anchor.microsecond,
            )
          : DateTime(
              localNow.year,
              localNow.month,
              localNow.day + index,
              anchor.hour,
              anchor.minute,
              anchor.second,
              anchor.millisecond,
              anchor.microsecond,
            );
      if (!day.isAfter(now) || day.isBefore(anchor)) continue;
      if (window.start != null && day.isBefore(window.start!)) continue;
      final previous = day.subtract(const Duration(microseconds: 1));
      final next = calculation.getNextOccurrence(after: previous);
      final first =
          day.isAtSameMomentAs(anchor) &&
          (window.start == null || !day.isBefore(window.start!)) &&
          (window.end == null || !day.isAfter(window.end!));
      var baseline =
          (first &&
              (rule != 'workday' || day.weekday <= 5) &&
              (window.weekdays.isEmpty ||
                  window.weekdays.contains(day.weekday))) ||
          (next != null && next.isAtSameMomentAs(day));
      // A make-up workday replaces the weekday filter, not the daily interval/range.
      if (policy.mode == 'workdays' &&
          rule == 'workday' &&
          policy.calendar!.workdays.contains(CalendarExceptions.key(day))) {
        baseline =
            (window.start == null || !day.isBefore(window.start!)) &&
            (window.end == null || !day.isAfter(window.end!));
      }
      if (!policy.permits(day, baseline, window.exceptions)) continue;
      if (window.end != null && day.isAfter(window.end!)) continue;
      final id = '${template.id}:ordinary:${CalendarExceptions.key(day)}';
      // Keep the event's local wall time and calendar-day offset across DST.
      final eventAt = eventAnchor == null
          ? null
          : (anchor.isUtc ? eventAnchor.toUtc() : eventAnchor.toLocal());
      final offset = eventAt == null
          ? 0
          : DateTime.utc(eventAt.year, eventAt.month, eventAt.day)
                .difference(DateTime.utc(anchor.year, anchor.month, anchor.day))
                .inDays;
      final event = eventAt == null
          ? null
          : day.isUtc
          ? DateTime.utc(
              day.year,
              day.month,
              day.day + offset,
              eventAt.hour,
              eventAt.minute,
              eventAt.second,
              eventAt.millisecond,
              eventAt.microsecond,
            )
          : DateTime(
              day.year,
              day.month,
              day.day + offset,
              eventAt.hour,
              eventAt.minute,
              eventAt.second,
              eventAt.millisecond,
              eventAt.microsecond,
            );
      final data = {...template.details.data}..remove('ordinary_series');
      occurrences.add(
        Reminder.fromJson({...template.toJson(), 'id': id}).copyWith(
          triggerTime: day,
          eventTime: event,
          isRecurring: false,
          recurrenceRule: 'none',
          recurrenceAnchorTime: null,
          recurrenceEventAnchorTime: null,
          noticeRevision: 0,
          noticeAcknowledgedAt: null,
          upcomingDismissedAt: null,
          snoozedAt: null,
          isPinned: false,
          detailsJson: template.details.patch({
            'plan_id': template.id,
            'repeat': null,
            'history': [],
            'data': {
              ...data,
              'ordinary_occurrence': true,
              'scheduled_at': day.toIso8601String(),
            },
            'checklist': template.details.checklist
                .map((e) => (e.once ? e : e.copyWith(done: false)).toJson())
                .toList(),
          }).encode(),
        ),
      );
    }
    return (owner: owner, occurrences: occurrences);
  }
}
