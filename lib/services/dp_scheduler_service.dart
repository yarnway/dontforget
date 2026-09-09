import 'dart:math';
import '../models/reminder.dart';

class TimeSlot {
  final DateTime start;
  final DateTime end;

  TimeSlot(this.start, this.end);

  int get durationMinutes => end.difference(start).inMinutes;

  @override
  String toString() => '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} - ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')} ($durationMinutes mins)';
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
  List<TimeSlot> calculateFreeTimeSlots(List<Reminder> existingTasks, {DateTime? referenceTime}) {
    final now = referenceTime ?? DateTime.now();
    final List<TimeSlot> freeSlots = [];

    // Analyze next 2 days
    for (int dayOffset = 0; dayOffset < 2; dayOffset++) {
      final dayBase = now.add(Duration(days: dayOffset));
      DateTime dayStart = DateTime(dayBase.year, dayBase.month, dayBase.day, 9, 0);
      final dayEnd = DateTime(dayBase.year, dayBase.month, dayBase.day, 21, 0);

      // If today and already past 09:00, advance dayStart
      if (dayOffset == 0 && now.isAfter(dayStart)) {
        dayStart = DateTime(now.year, now.month, now.day, now.hour, (now.minute / 15).ceil() * 15);
        if (dayStart.isAfter(dayEnd)) continue;
      }

      // Collect occupied intervals on this day
      final busyIntervals = <TimeSlot>[];
      for (final task in existingTasks) {
        if (task.isCompleted || task.triggerTime == null) continue;
        final t = task.triggerTime!;
        if (t.year == dayBase.year && t.month == dayBase.month && t.day == dayBase.day) {
          // Assume each existing task reserves a default 30-minute block
          final bStart = t;
          final bEnd = t.add(const Duration(minutes: 30));
          if (bEnd.isAfter(dayStart) && bStart.isBefore(dayEnd)) {
            busyIntervals.add(TimeSlot(
              bStart.isBefore(dayStart) ? dayStart : bStart,
              bEnd.isAfter(dayEnd) ? dayEnd : bEnd,
            ));
          }
        }
      }

      // Sort occupied intervals
      busyIntervals.sort((a, b) => a.start.compareTo(b.start));

      // Merge overlapping intervals
      final mergedBusy = <TimeSlot>[];
      for (final interval in busyIntervals) {
        if (mergedBusy.isEmpty) {
          mergedBusy.add(interval);
        } else {
          final last = mergedBusy.last;
          if (interval.start.isBefore(last.end) || interval.start.isAtSameMomentAs(last.end)) {
            mergedBusy[mergedBusy.length - 1] = TimeSlot(
              last.start,
              interval.end.isAfter(last.end) ? interval.end : last.end,
            );
          } else {
            mergedBusy.add(interval);
          }
        }
      }

      // Derive free slots from gaps
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
  }) {
    final now = referenceTime ?? DateTime.now();
    final freeSlots = calculateFreeTimeSlots(existingTasks, referenceTime: now);

    if (freeSlots.isEmpty) {
      // Fallback if calendar is completely packed: schedule tomorrow 10:00
      final fallback = DateTime(now.year, now.month, now.day + 1, 10, 0);
      final fallbackSlot = TimeSlot(fallback, fallback.add(Duration(minutes: taskDurationMinutes)));
      return DPScheduleResult(
        optimalTime: fallback,
        allocatedSlot: fallbackSlot,
        fragmentationReductionScore: 50,
        rationale: '日历密集，已自动安排至明日上午黄金专注时段 10:00',
      );
    }

    // Dynamic programming evaluation
    double minCost = double.infinity;
    TimeSlot bestSlot = freeSlots.first;
    DateTime bestTime = freeSlots.first.start;

    for (int i = 0; i < freeSlots.length; i++) {
      final slot = freeSlots[i];
      if (slot.durationMinutes < taskDurationMinutes) continue;

      // 1. Fragmentation Cost: leaving awkward residual gap (e.g. 5-10 mins) has high penalty
      final residualGap = slot.durationMinutes - taskDurationMinutes;
      double fragmentationCost = 0.0;
      if (residualGap > 0 && residualGap < 20) {
        fragmentationCost = 50.0; // Avoid creating tiny un-schedulable fragments
      } else if (residualGap >= 45) {
        fragmentationCost = 5.0; // Clean large residual block is great
      } else {
        fragmentationCost = 15.0;
      }

      // 2. Latency Cost: tasks in Q1/Q2 prefer earlier suitable slots
      final hoursFromNow = slot.start.difference(now).inMinutes / 60.0;
      final latencyCost = hoursFromNow * 2.5;

      // 3. Circadian Focus Bonus: 09:30 - 11:30 and 14:30 - 16:30 have optimal cognitive efficiency
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

    final score = max(10, min(100, (100 - minCost).round()));
    final timeStr = '${bestTime.month}月${bestTime.day}日 ${bestTime.hour.toString().padLeft(2, '0')}:${bestTime.minute.toString().padLeft(2, '0')}';

    return DPScheduleResult(
      optimalTime: bestTime,
      allocatedSlot: bestSlot,
      fragmentationReductionScore: score,
      rationale: '动态规划计算完毕：匹配到连续 ${bestSlot.durationMinutes} 分钟专注窗口 ($timeStr)，有效降低日程碎片率',
    );
  }
}
