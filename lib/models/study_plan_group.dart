import 'dart:convert';
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

  static List<StudyPlanGroup> freezeSelection(List<StudyPlanGroup> expected) {
    final groups = [
      for (final group in expected)
        StudyPlanGroup(
          group.id,
          group.members.map((r) => Reminder.fromJson(r.toJson())),
        ),
    ];
    final rows = [for (final group in groups) ...group.members];
    if (groups.isEmpty ||
        groups.length > 20 ||
        groups.map((g) => g.id).toSet().length != groups.length ||
        rows.length > 50 ||
        rows.map((r) => r.id).toSet().length != rows.length ||
        groups.any(
          (g) => g.members.isEmpty || g.members.any((r) => identity(r) != g.id),
        )) {
      throw const FormatException('Invalid study plan selection');
    }
    return List.unmodifiable(groups);
  }

  static bool matchesSnapshots(
    List<Reminder> all,
    List<StudyPlanGroup> groups,
  ) {
    for (final group in groups) {
      final baseline = {for (final row in group.members) row.id: row};
      final members = all.where((r) => identity(r) == group.id).toList();
      if (members.length != baseline.length ||
          members.any(
            (r) =>
                baseline[r.id] == null ||
                jsonEncode(r.toJson()) != jsonEncode(baseline[r.id]!.toJson()),
          ) ||
          all.any((r) => baseline.containsKey(r.details.planId))) {
        return false;
      }
    }
    return true;
  }

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
