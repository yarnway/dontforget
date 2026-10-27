import '../models/reminder.dart';

/// 间隔复习调度。默认阶梯是可解释的产品策略，不代表个人最优记忆曲线。
///
/// 阶梯间隔设计：
/// - Level 1: 1 天后复习
/// - Level 2: 2 天后复习
/// - Level 3: 4 天后复习
/// - Level 4: 7 天后复习
/// - Level 5: 15 天后继续巩固
class SpacedRepetitionService {
  const SpacedRepetitionService();

  static const Map<int, int> levelIntervalDays = {
    1: 1,
    2: 2,
    3: 4,
    4: 7,
    5: 15,
  };

  /// 检查任务是否为已启用的复习卡片
  bool isReviewCard(Reminder task) {
    return task.isVisible &&
        !task.details.paused &&
        task.spacedRepetitionLevel > 0 &&
        !(task.reviewNotificationsEnabled && task.isCompleted);
  }

  /// 检查复习卡片是否今日到期需要复习
  bool isDue(Reminder task, [DateTime? referenceTime]) {
    if (!isReviewCard(task)) return false;
    if (task.nextReviewAt == null) return true; // 开启了但无时间，立即可复习
    final now = referenceTime ?? DateTime.now();
    return task.nextReviewAt!.isBefore(now) ||
        (task.nextReviewAt!.year == now.year &&
            task.nextReviewAt!.month == now.month &&
            task.nextReviewAt!.day == now.day);
  }

  /// 从任务列表中筛选所有已到期、等待复习的卡片
  List<Reminder> getDueCards(List<Reminder> tasks, [DateTime? referenceTime]) {
    final now = referenceTime ?? DateTime.now();
    return tasks.where((t) => isDue(t, now)).toList();
  }

  /// 筛选所有激活了间隔重复的卡片
  List<Reminder> getAllReviewCards(List<Reminder> tasks) {
    return tasks.where((t) => isReviewCard(t)).toList();
  }

  /// 将普通任务开启为间隔重复卡片
  Reminder enableCard(Reminder task) {
    final now = DateTime.now();
    return task.copyWith(
      spacedRepetitionLevel: 1,
      isPinned: false,
      nextReviewAt: now, // 立即进入首轮复习
    );
  }

  /// 取消间隔重复卡片
  Reminder disableCard(Reminder task) {
    return task.copyWith(
      spacedRepetitionLevel: 0,
      nextReviewAt: null,
      reviewNotificationsEnabled: false,
      triggerTime: task.reviewNotificationsEnabled ? null : task.triggerTime,
    );
  }

  /// 执行一次复习判定
  /// [remembered] 为 true 表示熟练记住，阶梯递增；
  /// 为 false 表示遗忘重置，重置回 Level 1并在 1 天后复习。
  Reminder reviewCard(
    Reminder task,
    bool remembered, {
    DateTime? referenceTime,
  }) {
    final currentLevel = task.spacedRepetitionLevel;
    final now = referenceTime ?? DateTime.now();

    if (task.reviewNotificationsEnabled) {
      final interval = remembered
          ? levelIntervalDays[currentLevel.clamp(1, 5)]!
          : 1;
      final anchor = (task.nextReviewAt ?? task.triggerTime ?? now).toLocal();
      final local = now.toLocal();
      final next = DateTime(
        local.year,
        local.month,
        local.day + interval,
        anchor.hour,
        anchor.minute,
      );
      return task.copyWith(
        spacedRepetitionLevel: remembered ? (currentLevel + 1).clamp(1, 5) : 1,
        nextReviewAt: next,
        triggerTime: next,
      );
    }

    if (!remembered) {
      // 遗忘：降级为 Level 1，1 天后再次复习
      return task.copyWith(
        spacedRepetitionLevel: 1,
        nextReviewAt: now.add(const Duration(days: 1)),
      );
    }

    // 熟练记住：阶梯递增，最高到 Level 5
    final nextLevel = (currentLevel < 5)
        ? (currentLevel <= 0 ? 1 : currentLevel + 1)
        : 5;
    final intervalDays = levelIntervalDays[nextLevel] ?? 15;
    final nextDate = now.add(Duration(days: intervalDays));

    return task.copyWith(
      spacedRepetitionLevel: nextLevel,
      nextReviewAt: nextDate,
    );
  }

  /// 获取记忆熟练度描述
  String getMasteryDescription(int level) {
    switch (level) {
      case 1:
        return '初记阶段 (1天间隔)';
      case 2:
        return '巩固阶段 (2天间隔)';
      case 3:
        return '加深阶段 (4天间隔)';
      case 4:
        return '强化阶段 (7天间隔)';
      case 5:
        return '长期巩固 (15天间隔)';
      default:
        return '未开启复习';
    }
  }
}

/// Per-view cache: UI-only state changes do not rescan the task collection.
/// Due eligibility is calendar-day based, so midnight/resume or a new list
/// invalidates the result without a polling timer per card.
class ReviewQueueCache {
  List<Reminder>? _source;
  SpacedRepetitionService? _service;
  DateTime? _day;
  ({List<Reminder> due, int total}) _result = (due: const [], total: 0);

  void invalidate() => _day = null;

  ({List<Reminder> due, int total}) read(
    List<Reminder> tasks,
    SpacedRepetitionService service, {
    DateTime? now,
  }) {
    final instant = now ?? DateTime.now();
    final day = DateTime(instant.year, instant.month, instant.day);
    if (identical(tasks, _source) &&
        identical(service, _service) &&
        day == _day) {
      return _result;
    }
    _source = tasks;
    _service = service;
    _day = day;
    final due = <Reminder>[];
    var total = 0;
    for (final task in tasks) {
      if (service.isReviewCard(task)) {
        total++;
        if (service.isDue(task, instant)) due.add(task);
      }
    }
    return _result = (due: List.unmodifiable(due), total: total);
  }
}
