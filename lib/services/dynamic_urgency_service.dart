import 'package:flutter/foundation.dart';
import '../models/reminder.dart';

/// 任务状态动态跃迁与视觉衰减调度服务 (Dynamic Urgency Routing)
/// 1. 基于时间轴的动态权重机制：Q2 (重要不紧急) 在临近触发时（默认 <= 24h）自动跃迁至 Q1 (紧急且重要)
/// 2. Q4 (不重要不紧急) 长期停滞任务的平滑透明度衰减与折叠收纳判定
class DynamicUrgencyService {
  const DynamicUrgencyService();

  /// 扫描待办列表，检测是否有需从 Q2 跃迁升级到 Q1 的任务
  /// 返回被跃迁更新后的任务列表，以及触发了跃迁的任务列表
  List<Reminder> evaluatePromotions(
    List<Reminder> reminders, {
    Duration promotionThreshold = const Duration(hours: 24),
  }) {
    final now = DateTime.now();
    bool changed = false;

    final result = reminders.map((reminder) {
      if (reminder.isCompleted || reminder.triggerTime == null) {
        return reminder;
      }

      // 若任务处于 Q2 象限（重要不紧急）
      if (reminder.quadrantLevel == 2) {
        final diff = reminder.triggerTime!.difference(now);
        // 如果在未来 24 小时之内（且尚未过去太久）
        if (diff.inSeconds > 0 && diff <= promotionThreshold) {
          changed = true;
          debugPrint('⚡ [DynamicUrgency] 任务自动动态跃迁: [${reminder.taskTitle}] Q2 -> Q1 (剩余 ${diff.inHours} 小时)');
          return reminder.copyWith(
            quadrantLevel: 1,
            originalQuadrantLevel: 2,
            isDynamicallyPromoted: true,
          );
        }
      }

      return reminder;
    }).toList();

    return changed ? result : reminders;
  }

  /// 计算 Q4 (不重要不紧急) 任务的视觉衰减透明度
  /// 停滞超 48 小时后开始按时间渐进衰减，最低降至 0.35
  double calculateQ4VisualOpacity(Reminder reminder, {int thresholdHours = 48}) {
    if (reminder.quadrantLevel != 4 || reminder.isCompleted || reminder.createdAt == null) {
      return 1.0;
    }

    final ageHours = DateTime.now().difference(reminder.createdAt!).inHours;
    if (ageHours < thresholdHours) {
      return 1.0;
    }

    // 从 48 小时到 96 小时，透明度从 1.0 平滑衰减至 0.35
    const decaySpan = 48.0;
    final progress = ((ageHours - thresholdHours) / decaySpan).clamp(0.0, 1.0);
    return (1.0 - progress * 0.65).clamp(0.35, 1.0);
  }

  /// 判定 Q4 任务是否处于可折叠的冗余停滞状态
  bool isQ4StagnantFolded(Reminder reminder, {int thresholdHours = 48}) {
    if (reminder.quadrantLevel != 4 || reminder.isCompleted || reminder.createdAt == null) {
      return false;
    }
    final ageHours = DateTime.now().difference(reminder.createdAt!).inHours;
    return ageHours >= thresholdHours;
  }
}
