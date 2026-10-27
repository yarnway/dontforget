import 'dart:convert';
import 'stored_datetime.dart';

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
  static const int dynamicallyPromoted = 1 << 12;
  static const int hasLinks = 1 << 13;
  static const int hasContextTrigger = 1 << 14;

  // Convenient aliases
  static const int q1 = quadrant1;
  static const int q2 = quadrant2;
  static const int q3 = quadrant3;
  static const int q4 = quadrant4;
  static const int reviewCard = spacedReview;
}

class Reminder {
  static const _unchanged = Object();
  final String id;
  final String? recordId;
  final String taskTitle;
  final String? taskSummary;
  final int quadrantLevel; // 1, 2, 3, 4
  final int originalQuadrantLevel; // 记录初始象限，用于动态跃迁溯源
  final bool isDynamicallyPromoted; // 是否被动态权重跃迁升级至 Q1
  final String? urgencyLevel; // 'urgent', 'general', 'not_urgent'
  final String? importanceLevel; // 'important', 'general', 'not_important'
  final DateTime? triggerTime;
  final bool isCompleted;
  final bool isRecurring;
  final String?
  recurrenceRule; // 'none', 'daily', 'workday', 'weekly', 'monthly', 'yearly'
  final String? recurrenceDescription;
  final bool isEmotionFiltered; // '空船效应' 情绪去噪重构标识
  final String? subTasks; // JSON 格式微习惯原子项列表
  final DateTime? createdAt; // 创建时间戳，用于滞留感知与衰减计算
  final int spacedRepetitionLevel; // 0: 普通任务, 1..5: 艾宾浩斯复习阶梯
  final DateTime? nextReviewAt; // 下一次间隔复习时间
  final bool reviewNotificationsEnabled;
  final List<String> linkedTaskIds; // 双向关联的任务 ID 列表
  final String? contextTrigger; // 情境感知触发规则 JSON
  final int noticeRevision;
  final DateTime? noticeAcknowledgedAt;
  final DateTime? upcomingDismissedAt;
  final DateTime? snoozedAt;
  final DateTime? recurrenceAnchorTime;

  Reminder({
    required this.id,
    this.recordId,
    required this.taskTitle,
    this.taskSummary,
    required this.quadrantLevel,
    int? originalQuadrantLevel,
    this.isDynamicallyPromoted = false,
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
    this.reviewNotificationsEnabled = false,
    this.linkedTaskIds = const [],
    this.contextTrigger,
    this.noticeRevision = 0,
    this.noticeAcknowledgedAt,
    this.upcomingDismissedAt,
    this.snoozedAt,
    this.recurrenceAnchorTime,
  }) : originalQuadrantLevel = originalQuadrantLevel ?? quadrantLevel,
       createdAt = createdAt ?? DateTime.now() {
    if (noticeRevision < 0) {
      throw ArgumentError.value(noticeRevision, 'noticeRevision');
    }
  }

  /// One occurrence remains stable across timezone serialization and restart.
  String get occurrenceIdentity => jsonEncode([
    id,
    triggerTime?.toUtc().microsecondsSinceEpoch,
    noticeRevision,
  ]);

  /// Keep vocabulary batches readable in an OS banner; full notes stay in-app.
  String? get notificationSummary {
    final summary = taskSummary;
    if (!reviewNotificationsEnabled || summary == null) return summary;
    final points = summary.runes.take(161).toList();
    return points.length <= 160
        ? summary
        : '${String.fromCharCodes(points.take(160))}…';
  }

  int get bitmask {
    int mask = 0;
    if (quadrantLevel == 1) mask |= TaskBitmask.quadrant1;
    if (quadrantLevel == 2) mask |= TaskBitmask.quadrant2;
    if (quadrantLevel == 3) mask |= TaskBitmask.quadrant3;
    if (quadrantLevel == 4) mask |= TaskBitmask.quadrant4;
    if (isCompleted) mask |= TaskBitmask.completed;
    if (triggerTime != null &&
        triggerTime!.isBefore(DateTime.now()) &&
        !isCompleted) {
      mask |= TaskBitmask.overdue;
    }
    if (isRecurring) mask |= TaskBitmask.recurring;
    if (isEmotionFiltered) mask |= TaskBitmask.emotionFiltered;
    if (recordId != null && recordId!.isNotEmpty) {
      mask |= TaskBitmask.hasAttachment;
    }
    if (subTasks != null && subTasks!.trim().isNotEmpty && subTasks != '[]') {
      mask |= TaskBitmask.hasSubtasks;
    }
    if (isStagnant()) mask |= TaskBitmask.stagnant;
    if (spacedRepetitionLevel > 0) mask |= TaskBitmask.spacedReview;
    if (isDynamicallyPromoted) mask |= TaskBitmask.dynamicallyPromoted;
    if (linkedTaskIds.isNotEmpty) mask |= TaskBitmask.hasLinks;
    if (contextTrigger != null && contextTrigger!.trim().isNotEmpty) {
      mask |= TaskBitmask.hasContextTrigger;
    }
    return mask;
  }

  bool get isOverdue =>
      triggerTime != null &&
      triggerTime!.isBefore(DateTime.now()) &&
      !isCompleted;

  factory Reminder.fromJson(Map<String, dynamic> json) {
    final rawLinked = json['linked_task_ids'];
    List<String> linkedIds = [];
    if (rawLinked != null && rawLinked is String && rawLinked.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawLinked);
        if (decoded is List) {
          linkedIds = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    } else if (rawLinked is List) {
      linkedIds = rawLinked.map((e) => e.toString()).toList();
    }

    final qLevel = json['quadrant_level'] as int;
    final origQLevel = (json['original_quadrant_level'] as int?) ?? qLevel;
    final revision = json.containsKey('notice_revision')
        ? json['notice_revision']
        : 0;
    if (revision is! int || revision < 0) {
      throw const FormatException('Invalid notice revision');
    }

    return Reminder(
      id: json['id'] as String,
      recordId: json['record_id'] as String?,
      taskTitle: json['task_title'] as String,
      taskSummary: json['task_summary'] as String?,
      quadrantLevel: qLevel,
      originalQuadrantLevel: origQLevel,
      isDynamicallyPromoted:
          json['is_dynamically_promoted'] == 1 ||
          json['is_dynamically_promoted'] == true,
      urgencyLevel: json['urgency_level'] as String?,
      importanceLevel: json['importance_level'] as String?,
      triggerTime: _storedDate(json['trigger_time']),
      isCompleted: json['is_completed'] == 1 || json['is_completed'] == true,
      isRecurring: (json['is_recurring'] is int)
          ? (json['is_recurring'] as int) == 1
          : (json['is_recurring'] is bool
                ? (json['is_recurring'] as bool)
                : false),
      recurrenceRule: json['recurrence_rule'] as String? ?? 'none',
      recurrenceDescription: json['recurrence_description'] as String?,
      isEmotionFiltered:
          json['is_emotion_filtered'] == 1 ||
          json['is_emotion_filtered'] == true,
      subTasks: json['sub_tasks'] as String?,
      createdAt: _storedDate(json['created_at']),
      spacedRepetitionLevel: (json['review_level'] as int?) ?? 0,
      nextReviewAt: _storedDate(json['next_review_at']),
      reviewNotificationsEnabled: json['review_notifications_enabled'] == 1,
      linkedTaskIds: linkedIds,
      contextTrigger: json['context_trigger'] as String?,
      noticeRevision: revision,
      noticeAcknowledgedAt: _storedDate(json['notice_acknowledged_at']),
      upcomingDismissedAt: _storedDate(json['upcoming_dismissed_at']),
      snoozedAt: _storedDate(json['snoozed_at']),
      recurrenceAnchorTime: _storedDate(json['recurrence_anchor_time']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'record_id': recordId,
    'task_title': taskTitle,
    'task_summary': taskSummary,
    'quadrant_level': quadrantLevel,
    'original_quadrant_level': originalQuadrantLevel,
    'is_dynamically_promoted': isDynamicallyPromoted ? 1 : 0,
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
    'review_notifications_enabled': reviewNotificationsEnabled ? 1 : 0,
    'linked_task_ids': jsonEncode(linkedTaskIds),
    'context_trigger': contextTrigger,
    'notice_revision': noticeRevision,
    'notice_acknowledged_at': noticeAcknowledgedAt?.toIso8601String(),
    'upcoming_dismissed_at': upcomingDismissedAt?.toIso8601String(),
    'snoozed_at': snoozedAt?.toIso8601String(),
    'recurrence_anchor_time': recurrenceAnchorTime?.toIso8601String(),
  };

  /// Advance at least one occurrence and skip missed occurrences. Calendar
  /// construction preserves wall-clock time across daylight-saving changes.
  /// Monthly/yearly dates are clamped to the last valid day of the target month.
  DateTime? getNextOccurrence({DateTime? after}) {
    if (!isRecurring ||
        !const {
          'daily',
          'workday',
          'weekly',
          'monthly',
          'yearly',
        }.contains(recurrenceRule)) {
      return null;
    }
    final cutoff = after ?? DateTime.now();
    final base = recurrenceAnchorTime ?? triggerTime ?? cutoff;
    final localCutoff = base.isUtc ? cutoff.toUtc() : cutoff.toLocal();
    DateTime calendar(int year, int month, int day) => base.isUtc
        ? DateTime.utc(
            year,
            month,
            day,
            base.hour,
            base.minute,
            base.second,
            base.millisecond,
            base.microsecond,
          )
        : DateTime(
            year,
            month,
            day,
            base.hour,
            base.minute,
            base.second,
            base.millisecond,
            base.microsecond,
          );
    DateTime clamped(int year, int month) {
      final lastDay = DateTime.utc(year, month + 1, 0).day;
      return calendar(year, month, base.day > lastDay ? lastDay : base.day);
    }

    if (recurrenceRule == 'monthly' || recurrenceRule == 'yearly') {
      var step = recurrenceRule == 'monthly'
          ? (localCutoff.year - base.year) * 12 + localCutoff.month - base.month
          : localCutoff.year - base.year;
      if (step < 1) step = 1;
      DateTime candidate() => recurrenceRule == 'monthly'
          ? clamped(base.year, base.month + step)
          : clamped(base.year + step, base.month);
      var next = candidate();
      if (!next.isAfter(cutoff)) {
        step++;
        next = candidate();
      }
      return next;
    }

    final days = DateTime.utc(
      localCutoff.year,
      localCutoff.month,
      localCutoff.day,
    ).difference(DateTime.utc(base.year, base.month, base.day)).inDays;
    final interval = recurrenceRule == 'weekly' ? 7 : 1;
    var step = days > 0 ? days ~/ interval : 1;
    if (step < 1) step = 1;
    var next = calendar(base.year, base.month, base.day + step * interval);
    if (!next.isAfter(cutoff)) {
      next = calendar(base.year, base.month, base.day + (++step) * interval);
    }
    if (recurrenceRule == 'workday') {
      while (next.weekday == DateTime.saturday ||
          next.weekday == DateTime.sunday) {
        next = calendar(next.year, next.month, next.day + 1);
      }
    }
    return next;
  }

  Reminder copyWith({
    Object? recordId = _unchanged,
    String? taskTitle,
    Object? taskSummary = _unchanged,
    int? quadrantLevel,
    int? originalQuadrantLevel,
    bool? isDynamicallyPromoted,
    Object? urgencyLevel = _unchanged,
    Object? importanceLevel = _unchanged,
    Object? triggerTime = _unchanged,
    bool? isCompleted,
    bool? isRecurring,
    Object? recurrenceRule = _unchanged,
    Object? recurrenceDescription = _unchanged,
    bool? isEmotionFiltered,
    Object? subTasks = _unchanged,
    DateTime? createdAt,
    int? spacedRepetitionLevel,
    Object? nextReviewAt = _unchanged,
    bool? reviewNotificationsEnabled,
    List<String>? linkedTaskIds,
    Object? contextTrigger = _unchanged,
    int? noticeRevision,
    Object? noticeAcknowledgedAt = _unchanged,
    Object? upcomingDismissedAt = _unchanged,
    Object? snoozedAt = _unchanged,
    Object? recurrenceAnchorTime = _unchanged,
  }) {
    return Reminder(
      id: id,
      recordId: identical(recordId, _unchanged)
          ? this.recordId
          : recordId as String?,
      taskTitle: taskTitle ?? this.taskTitle,
      taskSummary: identical(taskSummary, _unchanged)
          ? this.taskSummary
          : taskSummary as String?,
      quadrantLevel: quadrantLevel ?? this.quadrantLevel,
      originalQuadrantLevel:
          originalQuadrantLevel ?? this.originalQuadrantLevel,
      isDynamicallyPromoted:
          isDynamicallyPromoted ?? this.isDynamicallyPromoted,
      urgencyLevel: identical(urgencyLevel, _unchanged)
          ? this.urgencyLevel
          : urgencyLevel as String?,
      importanceLevel: identical(importanceLevel, _unchanged)
          ? this.importanceLevel
          : importanceLevel as String?,
      triggerTime: identical(triggerTime, _unchanged)
          ? this.triggerTime
          : triggerTime as DateTime?,
      isCompleted: isCompleted ?? this.isCompleted,
      isRecurring: isRecurring ?? this.isRecurring,
      recurrenceRule: identical(recurrenceRule, _unchanged)
          ? this.recurrenceRule
          : recurrenceRule as String?,
      recurrenceDescription: identical(recurrenceDescription, _unchanged)
          ? this.recurrenceDescription
          : recurrenceDescription as String?,
      isEmotionFiltered: isEmotionFiltered ?? this.isEmotionFiltered,
      subTasks: identical(subTasks, _unchanged)
          ? this.subTasks
          : subTasks as String?,
      createdAt: createdAt ?? this.createdAt,
      spacedRepetitionLevel:
          spacedRepetitionLevel ?? this.spacedRepetitionLevel,
      nextReviewAt: identical(nextReviewAt, _unchanged)
          ? this.nextReviewAt
          : nextReviewAt as DateTime?,
      reviewNotificationsEnabled:
          reviewNotificationsEnabled ?? this.reviewNotificationsEnabled,
      linkedTaskIds: linkedTaskIds ?? this.linkedTaskIds,
      contextTrigger: identical(contextTrigger, _unchanged)
          ? this.contextTrigger
          : contextTrigger as String?,
      noticeRevision: noticeRevision ?? this.noticeRevision,
      noticeAcknowledgedAt: identical(noticeAcknowledgedAt, _unchanged)
          ? this.noticeAcknowledgedAt
          : noticeAcknowledgedAt as DateTime?,
      upcomingDismissedAt: identical(upcomingDismissedAt, _unchanged)
          ? this.upcomingDismissedAt
          : upcomingDismissedAt as DateTime?,
      snoozedAt: identical(snoozedAt, _unchanged)
          ? this.snoozedAt
          : snoozedAt as DateTime?,
      recurrenceAnchorTime: identical(recurrenceAnchorTime, _unchanged)
          ? this.recurrenceAnchorTime
          : recurrenceAnchorTime as DateTime?,
    );
  }

  List<String>? _subTasksView;

  /// Reuse parsed text during card rebuilds. Cache belongs to this immutable
  /// reminder, never to a global map; copyWith naturally starts a fresh cache.
  /// Keep getSubTasksList's historical mutable-copy contract for other callers.
  List<String> get subTasksView =>
      _subTasksView ??= List<String>.unmodifiable(getSubTasksList());

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

DateTime? _storedDate(Object? value) {
  if (value == null) return null;
  return parseStoredDateTime(value);
}
