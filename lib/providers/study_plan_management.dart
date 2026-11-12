part of 'providers.dart';

extension StudyPlanManagement on RemindersNotifier {
  Future<ReminderBatchResult> changeStudyPlan(
    StudyPlanGroup expected,
    String action,
    DataGeneration generation, {
    DateTime? now,
  }) => _changeStudyPlans([expected], action, generation, now: now);

  /// Every selected plan is checked in the same transaction, including no-ops.
  Future<ReminderBatchResult> changeStudyPlans(
    List<StudyPlanGroup> expected,
    String action,
    DataGeneration generation, {
    DateTime? now,
  }) {
    if (!const {'pause', 'resume'}.contains(action)) {
      throw const FormatException('Unsupported cross-plan action');
    }
    return _changeStudyPlans(expected, action, generation, now: now);
  }

  Future<ReminderBatchResult> _changeStudyPlans(
    List<StudyPlanGroup> expected,
    String action,
    DataGeneration generation, {
    DateTime? now,
  }) {
    if (!const {'pause', 'resume', 'trash'}.contains(action)) {
      throw const FormatException('Invalid study plan action');
    }
    final groups = StudyPlanGroup.freezeSelection(expected);
    final rows = [for (final group in groups) ...group.members];
    final targets = rows
        .where(
          (row) => switch (action) {
            'pause' => row.isVisible && !row.isCompleted && !row.details.paused,
            'resume' => row.isVisible && !row.isCompleted && row.details.paused,
            _ => row.details.deletedAt == null,
          },
        )
        .toList();
    return _changeLifecycles(
      targets,
      action,
      generation,
      now: now,
      studyPlanBaselines: groups,
    );
  }

  Future<ReminderBatchResult> shiftStudyPlanDates(
    StudySchedulePreview preview,
    DataGeneration generation,
  ) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final saved = await _dbHelper.writeTransaction(ticket, (db) async {
        final all = (await db.query(
          'Reminders',
        )).map(Reminder.fromJson).toList();
        final StudySchedulePreview current;
        try {
          current = StudyScheduleService.preview(
            all,
            preview.groups,
            preview.days,
            now: preview.at,
          );
        } on StudyScheduleStale {
          throw const StaleReminderOccurrenceException();
        }
        if (current.progressFingerprint != preview.progressFingerprint ||
            !listEquals(
              current.changes.map((r) => jsonEncode(r.toJson())).toList(),
              preview.changes.map((r) => jsonEncode(r.toJson())).toList(),
            )) {
          throw const StaleReminderOccurrenceException();
        }
        for (final row in current.changes) {
          await db.update(
            'Reminders',
            row.toJson(),
            where: 'id = ?',
            whereArgs: [row.id],
          );
        }
        return current.changes;
      });
      _dbHelper.checkGeneration(ticket);
      _publishManaged(saved);
      var failures = 0;
      for (final row in saved) {
        if (await _synchronizeReminder(row, ticket, cancelOverdue: true)) {
          failures++;
        }
      }
      return ReminderBatchResult(
        changed: saved.length,
        nativeSyncFailures: failures,
      );
    }),
    generation: generation,
  );
}
