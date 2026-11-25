import 'dart:math';
import '../models/reminder.dart';

class TimeSlot {
  final DateTime start;
  final DateTime end;

  TimeSlot(this.start, this.end);

  int get durationMinutes => end.difference(start).inMinutes;

  @override
  String toString() =>
      '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} - ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')} ($durationMinutes mins)';
}

class DPScheduleResult {
  final DateTime optimalTime;
  final TimeSlot allocatedSlot;
  final int fragmentationReductionScore;
  final String rationale;

  DPScheduleResult({
    required this.optimalTime,
    required this.allocatedSlot,
    required this.fragmentationReductionScore,
    required this.rationale,
  });
}

class DPSchedulerService {
  const DPSchedulerService();
  static const DPSchedulerService instance = DPSchedulerService();

  /// Calculates free time slots across today and tomorrow within active working hours (09:00 - 21:00)
  List<TimeSlot> calculateFreeTimeSlots(
    List<Reminder> existingTasks, {
    DateTime? referenceTime,
  }) {
    final now = (referenceTime ?? DateTime.now()).toLocal();
    final List<TimeSlot> freeSlots = [];

    for (int dayOffset = 0; dayOffset < 2; dayOffset++) {
      final dayBase = DateTime(now.year, now.month, now.day + dayOffset);
      DateTime dayStart = DateTime(
        dayBase.year,
        dayBase.month,
        dayBase.day,
        9,
        0,
      );
      final dayEnd = DateTime(dayBase.year, dayBase.month, dayBase.day, 21, 0);

      if (dayOffset == 0 && now.isAfter(dayStart)) {
        final quarterMinutes = ((now.minute + 14) ~/ 15) * 15;
        dayStart = DateTime(
          now.year,
          now.month,
          now.day,
          now.hour,
        ).add(Duration(minutes: quarterMinutes));
        if (!dayStart.isBefore(dayEnd)) continue;
      }

      final busyIntervals = <TimeSlot>[];
      for (final task in existingTasks) {
        if (task.isCompleted ||
            !task.isVisible ||
            task.details.paused ||
            !task.isWorkspaceItem ||
            task.triggerTime == null) {
          continue;
        }
        final t = task.triggerTime!.toLocal();
        if (t.year == dayBase.year &&
            t.month == dayBase.month &&
            t.day == dayBase.day) {
          final bStart = t;
          final bEnd = t.add(const Duration(minutes: 30));
          if (bEnd.isAfter(dayStart) && bStart.isBefore(dayEnd)) {
            busyIntervals.add(
              TimeSlot(
                bStart.isBefore(dayStart) ? dayStart : bStart,
                bEnd.isAfter(dayEnd) ? dayEnd : bEnd,
              ),
            );
          }
        }
      }

      busyIntervals.sort((a, b) => a.start.compareTo(b.start));

      final mergedBusy = <TimeSlot>[];
      for (final interval in busyIntervals) {
        if (mergedBusy.isEmpty) {
          mergedBusy.add(interval);
        } else {
          final last = mergedBusy.last;
          if (!interval.start.isAfter(last.end)) {
            mergedBusy[mergedBusy.length - 1] = TimeSlot(
              last.start,
              interval.end.isAfter(last.end) ? interval.end : last.end,
            );
          } else {
            mergedBusy.add(interval);
          }
        }
      }

      DateTime cursor = dayStart;
      for (final busy in mergedBusy) {
        if (busy.start.isAfter(cursor)) {
          final slot = TimeSlot(cursor, busy.start);
          if (slot.durationMinutes >= 15) {
            freeSlots.add(slot);
          }
        }
        if (busy.end.isAfter(cursor)) {
          cursor = busy.end;
        }
      }
      if (dayEnd.isAfter(cursor)) {
        final slot = TimeSlot(cursor, dayEnd);
        if (slot.durationMinutes >= 15) {
          freeSlots.add(slot);
        }
      }
    }

    return freeSlots;
  }

  /// Dynamic programming slot optimization:
  /// Finds the slot that minimizes fragmentation penalty and maximizes contiguous focus.
  DPScheduleResult findOptimalSlot({
    required int taskDurationMinutes,
    required List<Reminder> existingTasks,
    DateTime? referenceTime,
    int quadrantLevel = 2,
    String language = 'zh',
  }) {
    final safeDuration = max(15, taskDurationMinutes);
    final now = (referenceTime ?? DateTime.now()).toLocal();
    final freeSlots = calculateFreeTimeSlots(existingTasks, referenceTime: now);

    DPScheduleResult buildFallback() {
      final fallback = DateTime(now.year, now.month, now.day + 1, 10, 0);
      final fallbackSlot = TimeSlot(
        fallback,
        fallback.add(Duration(minutes: safeDuration)),
      );
      final rationale = switch (language) {
        'en' =>
          'Schedule is dense; placed into tomorrow morning focus block at 10:00.',
        'ja' => '予定が混み合っているため、明日の午前10:00の集中枠に配置しました。',
        _ => '日历密集，已自动安排至明日上午黄金专注时段 10:00',
      };
      return DPScheduleResult(
        optimalTime: fallback,
        allocatedSlot: fallbackSlot,
        fragmentationReductionScore: 50,
        rationale: rationale,
      );
    }

    if (freeSlots.isEmpty) {
      return buildFallback();
    }

    double minCost = double.infinity;
    TimeSlot? bestSlot;
    DateTime? bestTime;

    for (final slot in freeSlots) {
      if (slot.durationMinutes < safeDuration) continue;

      final residualGap = slot.durationMinutes - safeDuration;
      double fragmentationCost = 0.0;
      if (residualGap > 0 && residualGap < 20) {
        fragmentationCost = 50.0;
      } else if (residualGap >= 45) {
        fragmentationCost = 5.0;
      } else {
        fragmentationCost = 15.0;
      }

      final hoursFromNow = slot.start.difference(now).inMinutes / 60.0;
      final urgencyFactor = quadrantLevel == 1 ? 3.2 : 2.5;
      final latencyCost = max(0.0, hoursFromNow) * urgencyFactor;

      double circadianBonus = 0.0;
      final hour = slot.start.hour;
      if ((hour >= 9 && hour <= 11) || (hour >= 14 && hour <= 16)) {
        circadianBonus = -20.0;
      }

      final totalCost = fragmentationCost + latencyCost + circadianBonus;
      if (totalCost < minCost) {
        minCost = totalCost;
        bestSlot = slot;
        bestTime = slot.start;
      }
    }

    // Prevent Infinity.round() crash when free slots exist (15..39m) but none
    // are wide enough for safeDuration.
    if (!minCost.isFinite || bestSlot == null || bestTime == null) {
      return buildFallback();
    }

    final score = max(10, min(100, (100 - minCost).round()));
    final hhmm =
        '${bestTime.hour.toString().padLeft(2, '0')}:${bestTime.minute.toString().padLeft(2, '0')}';
    final rationale = switch (language) {
      'en' =>
        'Matched ${bestSlot.durationMinutes}-min focus window (${bestTime.month}/${bestTime.day} $hhmm).',
      'ja' =>
        '${bestSlot.durationMinutes}分の集中枠 (${bestTime.month}/${bestTime.day} $hhmm) に割り当てました。',
      _ =>
        '动态规划计算完毕：匹配到连续 ${bestSlot.durationMinutes} 分钟专注窗口 (${bestTime.month}月${bestTime.day}日 $hhmm)，有效降低日程碎片率',
    };

    return DPScheduleResult(
      optimalTime: bestTime,
      allocatedSlot: bestSlot,
      fragmentationReductionScore: score,
      rationale: rationale,
    );
  }
}
