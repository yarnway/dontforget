import '../models/reminder.dart';

/// 艾宾浩斯间隔重复 (Spaced Repetition / Ebbinghaus) 调度服务
///
/// 阶梯间隔设计（根据经典记忆遗忘曲线优化）：
/// - Level 1: 1 天后复习
/// - Level 2: 2 天后复习
/// - Level 3: 4 天后复习
/// - Level 4: 7 天后复习
/// - Level 5: 15 天后复习 (熟练掌握 Mastered)
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
    return task.spacedRepetitionLevel > 0;
  }

  /// 检查复习卡片是否今日到期需要复习
  bool isDue(Reminder task, [DateTime? referenceTime]) {
    if (task.spacedRepetitionLevel <= 0) return false;
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
      nextReviewAt: now, // 立即进入首轮复习
    );
  }

  /// 取消间隔重复卡片
  Reminder disableCard(Reminder task) {
    return task.copyWith(
      spacedRepetitionLevel: 0,
      nextReviewAt: null,
    );
  }

  /// 执行一次复习判定
  /// [remembered] 为 true 表示熟练记住，阶梯递增；
  /// 为 false 表示遗忘重置，重置回 Level 1并在 1 天后复习。
  Reminder reviewCard(Reminder task, bool remembered) {
    final currentLevel = task.spacedRepetitionLevel;
    final now = DateTime.now();

    if (!remembered) {
      // 遗忘：降级为 Level 1，1 天后再次复习
      return task.copyWith(
        spacedRepetitionLevel: 1,
        nextReviewAt: now.add(const Duration(days: 1)),
      );
    }

    // 熟练记住：阶梯递增，最高到 Level 5
    final nextLevel = (currentLevel < 5) ? (currentLevel <= 0 ? 1 : currentLevel + 1) : 5;
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
        return '永久记忆 (15天间隔)';
      default:
        return '未开启复习';
    }
  }
}
