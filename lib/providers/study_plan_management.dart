part of 'providers.dart';

extension StudyPlanManagement on RemindersNotifier {
  /// Validate the entire previewed group in the same transaction as the write.
  /// Completed/archived batches and learning history survive pause/resume.
  Future<ReminderBatchResult> changeStudyPlan(
    StudyPlanGroup expected,
    String action,
    DataGeneration generation, {
    DateTime? now,
  }) {
    final rows = List<Reminder>.unmodifiable(
      expected.members.map((row) => Reminder.fromJson(row.toJson())),
    );
    if (!const {'pause', 'resume', 'trash'}.contains(action) ||
        rows.isEmpty ||
        rows.length > 50 ||
        rows.map((row) => row.id).toSet().length != rows.length ||
        rows.any((row) => StudyPlanGroup.identity(row) != expected.id)) {
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
      studyPlanBaseline: StudyPlanGroup(expected.id, rows),
    );
  }
}
