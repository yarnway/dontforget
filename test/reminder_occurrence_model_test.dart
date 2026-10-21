import 'package:dont_forget/models/reminder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Reminder task() => Reminder(
    id: 'task:"id',
    taskTitle: 'Synthetic task',
    quadrantLevel: 2,
    triggerTime: DateTime.utc(2026, 10, 21, 1, 30),
    createdAt: DateTime.utc(2026),
  );

  test(
    'occurrence identity uses instant and revision across serialization',
    () {
      final original = task().copyWith(noticeRevision: 7);
      final json = original.toJson()
        ..['trigger_time'] = '2026-10-21T09:30:00+08:00';
      expect(
        Reminder.fromJson(json).occurrenceIdentity,
        original.occurrenceIdentity,
      );
      expect(
        original.copyWith(noticeRevision: 8).occurrenceIdentity,
        isNot(original.occurrenceIdentity),
      );
      expect(
        original.copyWith(triggerTime: null).occurrenceIdentity,
        isNot(original.occurrenceIdentity),
      );
    },
  );

  test('notice metadata round trips and supports explicit clearing', () {
    final instant = DateTime.utc(2026, 10, 21);
    final original = task().copyWith(
      noticeRevision: 8,
      noticeAcknowledgedAt: instant,
      upcomingDismissedAt: instant,
      snoozedAt: instant,
      recurrenceAnchorTime: instant,
    );
    final restored = Reminder.fromJson(original.toJson());
    expect(restored.toJson(), original.toJson());
    expect(restored.copyWith().toJson(), original.toJson());
    final cleared = restored.copyWith(
      noticeAcknowledgedAt: null,
      upcomingDismissedAt: null,
      snoozedAt: null,
      recurrenceAnchorTime: null,
    );
    expect(cleared.noticeRevision, 8);
    expect(cleared.noticeAcknowledgedAt, isNull);
    expect(cleared.upcomingDismissedAt, isNull);
    expect(cleared.snoozedAt, isNull);
    expect(cleared.recurrenceAnchorTime, isNull);
  });

  test('legacy rows receive empty notice metadata', () {
    final json = task().toJson()
      ..removeWhere(
        (key, _) =>
            key.startsWith('notice_') ||
            const {
              'upcoming_dismissed_at',
              'snoozed_at',
              'recurrence_anchor_time',
            }.contains(key),
      );
    final restored = Reminder.fromJson(json);
    expect(restored.noticeRevision, 0);
    expect(restored.noticeAcknowledgedAt, isNull);
    expect(restored.snoozedAt, isNull);
  });

  test(
    'all reminder timestamps preserve historical lowercase and fractional forms',
    () {
      for (final field in [
        'trigger_time',
        'created_at',
        'next_review_at',
        'notice_acknowledged_at',
        'upcoming_dismissed_at',
        'snoozed_at',
        'recurrence_anchor_time',
      ]) {
        for (final value in [
          '2032-02-29t09:30:00.123456789z',
          '2032-02-29T17:30:00.1234567+0800',
          '2032-02-29t09:30:00.1Z',
        ]) {
          final decoded = Reminder.fromJson(task().toJson()..[field] = value);
          expect(
            DateTime.parse(decoded.toJson()[field] as String),
            value.endsWith('.1Z')
                ? DateTime.utc(2032, 2, 29, 9, 30, 0, 100)
                : DateTime.utc(2032, 2, 29, 9, 30, 0, 123, 456),
          );
        }
      }
    },
  );

  test(
    'invalid revisions fail without defaulting to an earlier occurrence',
    () {
      for (final value in [-1, null, 1.5, '1', true]) {
        expect(
          () => Reminder.fromJson(task().toJson()..['notice_revision'] = value),
          throwsFormatException,
        );
      }
      expect(() => task().copyWith(noticeRevision: -1), throwsArgumentError);
    },
  );

  for (final field in [
    'trigger_time',
    'created_at',
    'next_review_at',
    'notice_acknowledged_at',
    'upcoming_dismissed_at',
    'snoozed_at',
    'recurrence_anchor_time',
  ]) {
    test('$field rejects malformed and overflowing dates', () {
      for (final value in [
        '2026-02-30T12:00:00Z',
        'invalid',
        '2026-01-01T25:00:00Z',
        '2026-01-01T12:00:00+25:00',
        '2026-02-30t12:00:00.123456789z',
        '2026-01-01t12:60:00.1234567z',
        '2026-01-01T12:00:00.1234567890Z',
        '2026-01-01t12:00:00.1+08:60',
        3,
      ]) {
        expect(
          () => Reminder.fromJson(task().toJson()..[field] = value),
          throwsFormatException,
        );
      }
    });
  }

  test(
    'snoozing keeps the daily calendar anchor across the next occurrence',
    () {
      final reminder = task().copyWith(
        isRecurring: true,
        recurrenceRule: 'daily',
        recurrenceAnchorTime: DateTime.utc(2026, 10, 21, 1, 30),
        triggerTime: DateTime.utc(2026, 10, 21, 4, 30),
      );
      expect(
        reminder.getNextOccurrence(after: DateTime.utc(2026, 10, 21, 4, 31)),
        DateTime.utc(2026, 10, 22, 1, 30),
      );
    },
  );

  test(
    'monthly anchor survives a clamped month and skips missed occurrences',
    () {
      final reminder = task().copyWith(
        isRecurring: true,
        recurrenceRule: 'monthly',
        recurrenceAnchorTime: DateTime.utc(2026, 1, 31, 9),
        triggerTime: DateTime.utc(2026, 2, 28, 10),
      );
      expect(
        reminder.getNextOccurrence(after: DateTime.utc(2026, 2, 28, 11)),
        DateTime.utc(2026, 3, 31, 9),
      );
    },
  );
}
