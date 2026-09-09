import 'dart:convert';

class TaskBitmask {
  static const int quadrant1 = 1 << 0;
  static const int quadrant2 = 1 << 1;
  static const int quadrant3 = 1 << 2;
  static const int quadrant4 = 1 << 3;
  static const int completed = 1 << 4;
  static const int overdue = 1 << 5;
  static const int recurring = 1 << 6;
  static const int emotionFiltered = 1 << 7;
  static const int hasAttachment = 1 << 8;
  static const int hasSubtasks = 1 << 9;
  static const int stagnant = 1 << 10;
  static const int spacedReview = 1 << 11;

  // Convenient aliases
  static const int q1 = quadrant1;
  static const int q2 = quadrant2;
  static const int q3 = quadrant3;
  static const int q4 = quadrant4;
  static const int reviewCard = spacedReview;
}

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
  final bool isEmotionFiltered; // '空船效应' 情绪去噪重构标识
  final String? subTasks; // JSON 格式微习惯原子项列表
  final DateTime? createdAt; // 创建时间戳，用于滞留感知
  final int spacedRepetitionLevel; // 0: 普通任务, 1..5: 艾宾浩斯复习阶梯
  final DateTime? nextReviewAt; // 下一次间隔复习时间

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
    this.isEmotionFiltered = false,
    this.subTasks,
    DateTime? createdAt,
    this.spacedRepetitionLevel = 0,
    this.nextReviewAt,
  }) : createdAt = createdAt ?? DateTime.now();

  int get bitmask {
    int mask = 0;
    if (quadrantLevel == 1) mask |= TaskBitmask.quadrant1;
    if (quadrantLevel == 2) mask |= TaskBitmask.quadrant2;
    if (quadrantLevel == 3) mask |= TaskBitmask.quadrant3;
    if (quadrantLevel == 4) mask |= TaskBitmask.quadrant4;
    if (isCompleted) mask |= TaskBitmask.completed;
    if (triggerTime != null && triggerTime!.isBefore(DateTime.now()) && !isCompleted) {
      mask |= TaskBitmask.overdue;
    }
    if (isRecurring) mask |= TaskBitmask.recurring;
    if (isEmotionFiltered) mask |= TaskBitmask.emotionFiltered;
    if (recordId != null && recordId!.isNotEmpty) mask |= TaskBitmask.hasAttachment;
    if (subTasks != null && subTasks!.trim().isNotEmpty && subTasks != '[]') {
      mask |= TaskBitmask.hasSubtasks;
    }
    if (isStagnant()) mask |= TaskBitmask.stagnant;
    if (spacedRepetitionLevel > 0) mask |= TaskBitmask.spacedReview;
    return mask;
  }

  bool get isOverdue => triggerTime != null && triggerTime!.isBefore(DateTime.now()) && !isCompleted;

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
        isEmotionFiltered: (json['is_emotion_filtered'] as int?) == 1 ||
            json['is_emotion_filtered'] == true,
        subTasks: json['sub_tasks'] as String?,
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'] as String)
            : null,
        spacedRepetitionLevel: (json['review_level'] as int?) ?? 0,
        nextReviewAt: json['next_review_at'] != null
            ? DateTime.tryParse(json['next_review_at'] as String)
            : null,
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
        'is_emotion_filtered': isEmotionFiltered ? 1 : 0,
        'sub_tasks': subTasks,
        'created_at': createdAt?.toIso8601String(),
        'review_level': spacedRepetitionLevel,
        'next_review_at': nextReviewAt?.toIso8601String(),
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
    bool? isEmotionFiltered,
    String? subTasks,
    DateTime? createdAt,
    int? spacedRepetitionLevel,
    DateTime? nextReviewAt,
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
      isEmotionFiltered: isEmotionFiltered ?? this.isEmotionFiltered,
      subTasks: subTasks ?? this.subTasks,
      createdAt: createdAt ?? this.createdAt,
      spacedRepetitionLevel: spacedRepetitionLevel ?? this.spacedRepetitionLevel,
      nextReviewAt: nextReviewAt ?? this.nextReviewAt,
    );
  }

  List<String> getSubTasksList() {
    if (subTasks == null || subTasks!.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(subTasks!);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return [];
  }

  bool isStagnant({int hours = 24}) {
    if (isCompleted || quadrantLevel != 2) return false;
    final now = DateTime.now();
    if (createdAt != null) {
      return now.difference(createdAt!).inHours >= hours;
    }
    return false;
  }
}
