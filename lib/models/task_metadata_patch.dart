import 'task_details.dart';

enum TagEditMode { keep, add, remove, replace }

/// Null project preserves it; an empty project explicitly clears it.
class TaskMetadataPatch {
  TaskMetadataPatch({
    String? project,
    this.tagMode = TagEditMode.keep,
    List<String> tags = const [],
  }) : project = project == null ? null : _text(project, 128, allowEmpty: true),
       tags = List.unmodifiable(tags.map((e) => _text(e, 64))) {
    if (this.tags.length > 16 ||
        this.tags.toSet().length != this.tags.length ||
        (tagMode == TagEditMode.keep && this.tags.isNotEmpty)) {
      throw const FormatException('Invalid metadata edit');
    }
  }
  final String? project;
  final TagEditMode tagMode;
  final List<String> tags;
  static String _text(String value, int max, {bool allowEmpty = false}) {
    if (value != value.trim() ||
        value.length > max ||
        (!allowEmpty && value.isEmpty) ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid project or tag');
    }
    return value;
  }

  TaskDetails apply(TaskDetails old) {
    final next = switch (tagMode) {
      TagEditMode.keep => old.tags,
      TagEditMode.add => {...old.tags, ...tags}.toList(),
      TagEditMode.remove => old.tags.where((e) => !tags.contains(e)).toList(),
      TagEditMode.replace => tags,
    };
    if (next.length > 16) throw const FormatException('Too many tags');
    return old.patch({'project': project ?? old.project, 'tags': next});
  }
}
