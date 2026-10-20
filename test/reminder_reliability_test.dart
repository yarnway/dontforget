import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/spaced_repetition_service.dart';

void main() {
  Reminder recurring(String rule, DateTime time) => Reminder(
    id: 'repeat',
    taskTitle: 'Repeat',
    quadrantLevel: 2,
    isRecurring: true,
    recurrenceRule: rule,
    triggerTime: time,
  );

  test('Month-end and leap-day recurrence stay in the target month', () {
    expect(
      recurring(
        'monthly',
        DateTime(2026, 1, 31, 9),
      ).getNextOccurrence(after: DateTime(2026, 1, 31, 10)),
      DateTime(2026, 2, 28, 9),
    );
    expect(
      recurring(
        'monthly',
        DateTime(2024, 1, 31, 9),
      ).getNextOccurrence(after: DateTime(2024, 1, 31, 10)),
      DateTime(2024, 2, 29, 9),
    );
    expect(
      recurring(
        'yearly',
        DateTime(2024, 2, 29, 9),
      ).getNextOccurrence(after: DateTime(2024, 3, 1)),
      DateTime(2025, 2, 28, 9),
    );
  });

  test('Completion skips missed occurrences and retains weekly phase', () {
    expect(
      recurring(
        'daily',
        DateTime(2020, 1, 1, 9),
      ).getNextOccurrence(after: DateTime(2026, 10, 20, 10)),
      DateTime(2026, 10, 21, 9),
    );
    expect(
      recurring(
        'weekly',
        DateTime(2026, 10, 5, 9),
      ).getNextOccurrence(after: DateTime(2026, 10, 20, 10)),
      DateTime(2026, 10, 26, 9),
    );
    expect(
      recurring(
        'monthly',
        DateTime(2020, 1, 31, 9),
      ).getNextOccurrence(after: DateTime(2026, 10, 20, 10)),
      DateTime(2026, 10, 31, 9),
    );
  });

  test('Workdays skip weekends; early completion still advances once', () {
    expect(
      recurring(
        'workday',
        DateTime(2026, 10, 23, 9),
      ).getNextOccurrence(after: DateTime(2026, 10, 23, 10)),
      DateTime(2026, 10, 26, 9),
    );
    expect(
      recurring(
        'daily',
        DateTime(2026, 10, 23, 9),
      ).getNextOccurrence(after: DateTime(2026, 10, 20)),
      DateTime(2026, 10, 24, 9),
    );
    expect(
      recurring('unsupported', DateTime(2026)).getNextOccurrence(),
      isNull,
    );
  });

  test('UTC recurrence preserves precision and zone', () {
    final base = DateTime.utc(2026, 12, 31, 23, 15, 30, 123, 456);
    final next = recurring('monthly', base).getNextOccurrence(after: base)!;
    expect(next, DateTime.utc(2027, 1, 31, 23, 15, 30, 123, 456));
    expect(next.isUtc, isTrue);
  });

  test('Explicit null clears nullable fields; omitted fields survive', () {
    final task = recurring('daily', DateTime(2026, 10, 20)).copyWith(
      nextReviewAt: DateTime(2026, 10, 21),
      spacedRepetitionLevel: 1,
      contextTrigger: '{"profile":"office"}',
      recurrenceDescription: 'Every day',
    );
    expect(task.copyWith(taskTitle: 'Updated').triggerTime, task.triggerTime);
    final cleared = task.copyWith(
      triggerTime: null,
      contextTrigger: null,
      recurrenceDescription: null,
    );
    expect(cleared.triggerTime, isNull);
    expect(cleared.contextTrigger, isNull);
    expect(cleared.recurrenceDescription, isNull);
    expect(
      const SpacedRepetitionService().disableCard(task).nextReviewAt,
      isNull,
    );
  });

  test('JSON accepts both SQLite integers and wire booleans', () {
    final json = recurring('daily', DateTime(2026)).toJson();
    for (final value in [true, 1, false, 0]) {
      final parsed = Reminder.fromJson({
        ...json,
        'is_completed': value,
        'is_emotion_filtered': value,
        'is_dynamically_promoted': value,
        'is_recurring': value,
      });
      final expected = value == true || value == 1;
      expect(parsed.isCompleted, expected);
      expect(parsed.isEmotionFiltered, expected);
      expect(parsed.isDynamicallyPromoted, expected);
      expect(parsed.isRecurring, expected);
    }
  });
}
