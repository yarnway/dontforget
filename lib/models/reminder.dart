class Reminder {
  final String id;
  final String? recordId;
  final String taskTitle;
  final String? taskSummary;
  final int quadrantLevel; // 1, 2, 3, 4
  final String? urgencyLevel; // 'urgent', 'general', 'not_urgent'
  final String? importanceLevel; // 'important', 'general', 'not_important'
  final DateTime? triggerTime;
  final bool isCompleted;
  final bool isRecurring;
  final String? recurrenceRule; // 'none', 'daily', 'workday', 'weekly', 'monthly', 'yearly'
  final String? recurrenceDescription;

  Reminder({
    required this.id,
    this.recordId,
    required this.taskTitle,
    this.taskSummary,
    required this.quadrantLevel,
    this.urgencyLevel,
    this.importanceLevel,
    this.triggerTime,
    this.isCompleted = false,
    this.isRecurring = false,
    this.recurrenceRule = 'none',
    this.recurrenceDescription,
  });

  factory Reminder.fromJson(Map<String, dynamic> json) => Reminder(
        id: json['id'] as String,
        recordId: json['record_id'] as String?,
        taskTitle: json['task_title'] as String,
        taskSummary: json['task_summary'] as String?,
        quadrantLevel: json['quadrant_level'] as int,
        urgencyLevel: json['urgency_level'] as String?,
        importanceLevel: json['importance_level'] as String?,
        triggerTime: json['trigger_time'] != null
            ? DateTime.parse(json['trigger_time'] as String)
            : null,
        isCompleted: (json['is_completed'] as int?) == 1,
        isRecurring: (json['is_recurring'] is int)
            ? (json['is_recurring'] as int) == 1
            : (json['is_recurring'] is bool ? (json['is_recurring'] as bool) : false),
        recurrenceRule: json['recurrence_rule'] as String? ?? 'none',
        recurrenceDescription: json['recurrence_description'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'record_id': recordId,
        'task_title': taskTitle,
        'task_summary': taskSummary,
        'quadrant_level': quadrantLevel,
        'urgency_level': urgencyLevel,
        'importance_level': importanceLevel,
        'trigger_time': triggerTime?.toIso8601String(),
        'is_completed': isCompleted ? 1 : 0,
        'is_recurring': isRecurring ? 1 : 0,
        'recurrence_rule': recurrenceRule ?? 'none',
        'recurrence_description': recurrenceDescription,
      };

  DateTime? getNextOccurrence() {
    if (!isRecurring || recurrenceRule == null || recurrenceRule == 'none') {
      return null;
    }
    final base = triggerTime ?? DateTime.now();
    switch (recurrenceRule) {
      case 'daily':
        return base.add(const Duration(days: 1));
      case 'workday':
        DateTime next = base.add(const Duration(days: 1));
        while (next.weekday == DateTime.saturday || next.weekday == DateTime.sunday) {
          next = next.add(const Duration(days: 1));
        }
        return next;
      case 'weekly':
        return base.add(const Duration(days: 7));
      case 'monthly':
        return DateTime(base.year, base.month + 1, base.day, base.hour, base.minute);
      case 'yearly':
        return DateTime(base.year + 1, base.month, base.day, base.hour, base.minute);
      default:
        return base.add(const Duration(days: 1));
    }
  }

  Reminder copyWith({
    String? recordId,
    String? taskTitle,
    String? taskSummary,
    int? quadrantLevel,
    String? urgencyLevel,
    String? importanceLevel,
    DateTime? triggerTime,
    bool? isCompleted,
    bool? isRecurring,
    String? recurrenceRule,
    String? recurrenceDescription,
  }) {
    return Reminder(
      id: id,
      recordId: recordId ?? this.recordId,
      taskTitle: taskTitle ?? this.taskTitle,
      taskSummary: taskSummary ?? this.taskSummary,
      quadrantLevel: quadrantLevel ?? this.quadrantLevel,
      urgencyLevel: urgencyLevel ?? this.urgencyLevel,
      importanceLevel: importanceLevel ?? this.importanceLevel,
      triggerTime: triggerTime ?? this.triggerTime,
      isCompleted: isCompleted ?? this.isCompleted,
      isRecurring: isRecurring ?? this.isRecurring,
      recurrenceRule: recurrenceRule ?? this.recurrenceRule,
      recurrenceDescription: recurrenceDescription ?? this.recurrenceDescription,
    );
  }
}
