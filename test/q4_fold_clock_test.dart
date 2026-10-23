import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/dynamic_urgency_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = DynamicUrgencyService();
  final now = DateTime.utc(2026, 10, 23, 12);

  test(
    'memo fold retains exact hour boundaries and future-time truncation',
    () {
      for (final threshold in [-1, 0, 1, 48]) {
        for (final microseconds in [
          -Duration.microsecondsPerHour - 1,
          -Duration.microsecondsPerHour + 1,
          -1,
          0,
          1,
          Duration.microsecondsPerHour - 1,
          Duration.microsecondsPerHour,
          48 * Duration.microsecondsPerHour - 1,
          48 * Duration.microsecondsPerHour,
        ]) {
          final created = now.subtract(Duration(microseconds: microseconds));
          final task = Reminder(
            id: 'boundary',
            taskTitle: 'Boundary memo',
            quadrantLevel: 4,
            createdAt: created,
          );
          expect(
            service.isQ4StagnantFolded(
              task,
              now: now,
              thresholdHours: threshold,
            ),
            now.difference(created).inHours >= threshold,
            reason: 'threshold $threshold, age $microseconds',
          );
          expect(
            service.isQ4StagnantFolded(
              task.copyWith(createdAt: created.toLocal()),
              now: now,
              thresholdHours: threshold,
            ),
            now.difference(created).inHours >= threshold,
          );
        }
      }
    },
  );

  test('completed and other-category rows never fold with a frozen clock', () {
    final task = Reminder(
      id: 'memo',
      taskTitle: 'Memo',
      quadrantLevel: 4,
      createdAt: now.subtract(const Duration(days: 3)),
    );
    expect(service.isQ4StagnantFolded(task, now: now), isTrue);
    expect(
      service.isQ4StagnantFolded(task.copyWith(isCompleted: true), now: now),
      isFalse,
    );
    expect(
      service.isQ4StagnantFolded(task.copyWith(quadrantLevel: 2), now: now),
      isFalse,
    );
  });
}
