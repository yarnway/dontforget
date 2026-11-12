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
    final groups = [
      for (final group in expected)
        StudyPlanGroup(
          group.id,
          group.members.map((r) => Reminder.fromJson(r.toJson())),
        ),
    ];
    final rows = [for (final group in groups) ...group.members];
    if (!const {'pause', 'resume', 'trash'}.contains(action) ||
        groups.isEmpty ||
        groups.length > 20 ||
        groups.map((g) => g.id).toSet().length != groups.length ||
        rows.length > 50 ||
        rows.map((r) => r.id).toSet().length != rows.length ||
        groups.any(
          (g) =>
              g.members.isEmpty ||
              g.members.any((r) => StudyPlanGroup.identity(r) != g.id),
        )) {
      throw const FormatException('Invalid study plan selection');
    }
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
}
