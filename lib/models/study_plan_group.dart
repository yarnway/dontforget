import 'reminder.dart';

/// Existing study batches share an identity in their versioned task details.
class StudyPlanGroup {
  StudyPlanGroup(this.id, Iterable<Reminder> members)
    : members = List.unmodifiable(members);
  final String id;
  final List<Reminder> members;

  static String? identity(Reminder row) {
    final details = row.details;
    final id = details.data['study_plan_id'];
    return details.kind == 'study' &&
            details.planId == null &&
            details.data['learning_archive'] != true &&
            id is String &&
            id.trim().isNotEmpty &&
            id.length <= 160
        ? id
        : null;
  }

  List<Reminder> get retained =>
      members.where((row) => row.details.deletedAt == null).toList();
  List<Reminder> get pending =>
      retained.where((row) => row.isVisible && !row.isCompleted).toList();
  bool get canPause => pending.any((row) => !row.details.paused);
  bool get canResume => pending.any((row) => row.details.paused);
  DateTime? get createdAt {
    final dates = members.map((row) => row.createdAt).whereType<DateTime>();
    return dates.isEmpty ? null : dates.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  String get title => retained.first.taskTitle;

  static List<StudyPlanGroup> project(Iterable<Reminder> rows) {
    final groups = <String, List<Reminder>>{};
    for (final row in rows) {
      final id = identity(row);
      if (id != null) (groups[id] ??= []).add(row);
    }
    final result = <StudyPlanGroup>[];
    for (final entry in groups.entries) {
      entry.value.sort((a, b) => a.id.compareTo(b.id));
      final group = StudyPlanGroup(entry.key, entry.value);
      if (group.retained.isNotEmpty) result.add(group);
    }
    result.sort((a, b) {
      final left = a.createdAt, right = b.createdAt;
      final time = left == null
          ? (right == null ? 0 : 1)
          : right == null
          ? -1
          : right.compareTo(left);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    return result;
  }
}
