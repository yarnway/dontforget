import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/agent_models.dart';
import 'package:dont_forget/services/dp_scheduler_service.dart';
import 'package:dont_forget/services/multi_agent_service.dart';
import 'package:dont_forget/services/spaced_repetition_service.dart';
import 'package:dont_forget/services/data_export_service.dart';

void main() {
  group('1. Bit Manipulation State Machine (TaskBitmask & O(1) Filtering)', () {
    test('Calculates bitmask accurately based on task properties', () {
      final now = DateTime.now();
      final taskQ1 = Reminder(
        id: 'task-1',
        taskTitle: 'Urgent Task',
        quadrantLevel: 1,
        triggerTime: now.subtract(const Duration(minutes: 10)),
        isCompleted: false,
      );

      // Q1 should have bit 0 set, and overdue bit 5 set
      expect(taskQ1.bitmask & TaskBitmask.q1, equals(TaskBitmask.q1));
      expect(taskQ1.bitmask & TaskBitmask.overdue, equals(TaskBitmask.overdue));
      expect(taskQ1.bitmask & TaskBitmask.completed, equals(0));

      final taskQ2Reviewed = Reminder(
        id: 'task-2',
        taskTitle: 'Q2 Study Task',
        quadrantLevel: 2,
        triggerTime: now.add(const Duration(hours: 4)),
        isCompleted: true,
        spacedRepetitionLevel: 3,
      );

      // Q2 bit 1 set, completed bit 4 set, reviewCard bit 11 set
      expect(taskQ2Reviewed.bitmask & TaskBitmask.q2, equals(TaskBitmask.q2));
      expect(taskQ2Reviewed.bitmask & TaskBitmask.completed, equals(TaskBitmask.completed));
      expect(taskQ2Reviewed.bitmask & TaskBitmask.reviewCard, equals(TaskBitmask.reviewCard));
      expect(taskQ2Reviewed.bitmask & TaskBitmask.overdue, equals(0));
    });

    test('O(1) multi-criteria filtering using bitwise AND', () {
      final tasks = [
        Reminder(id: '1', taskTitle: 'T1', quadrantLevel: 1, isCompleted: false),
        Reminder(id: '2', taskTitle: 'T2', quadrantLevel: 2, isCompleted: false, spacedRepetitionLevel: 2),
        Reminder(id: '3', taskTitle: 'T3', quadrantLevel: 2, isCompleted: true, spacedRepetitionLevel: 1),
        Reminder(id: '4', taskTitle: 'T4', quadrantLevel: 4, isCompleted: false),
      ];

      // Query: Find all uncompleted tasks that are spaced repetition cards in Q2
      const queryMask = TaskBitmask.q2 | TaskBitmask.reviewCard;
      final matched = tasks.where((t) {
        return (t.bitmask & queryMask) == queryMask && (t.bitmask & TaskBitmask.completed) == 0;
      }).toList();

      expect(matched.length, equals(1));
      expect(matched.first.id, equals('2'));
    });
  });

  group('2. Dynamic Programming Free Slot Scheduling (DPSchedulerService)', () {
    test('Calculates fragmentation penalty and finds optimal slot', () {
      const scheduler = DPSchedulerService();
      final baseDate = DateTime(2026, 9, 10, 9, 0);

      // Existing busy events: 10:00 - 11:00, 14:00 - 15:00
      final busyTasks = [
        Reminder(
          id: 'busy-1',
          taskTitle: 'Meeting',
          quadrantLevel: 1,
          triggerTime: baseDate.add(const Duration(hours: 1)),
        ),
        Reminder(
          id: 'busy-2',
          taskTitle: 'Design Review',
          quadrantLevel: 1,
          triggerTime: baseDate.add(const Duration(hours: 5)),
        ),
      ];

      // Schedule a 60-minute task with DP
      final result = scheduler.findOptimalSlot(
        taskDurationMinutes: 60,
        existingTasks: busyTasks,
        referenceTime: baseDate,
        quadrantLevel: 2,
      );

      expect(result.allocatedSlot, isNotNull);
      expect(result.allocatedSlot.durationMinutes, greaterThanOrEqualTo(60));
      expect(result.fragmentationReductionScore, isNonNegative);
    });
  });

  group('3. Multi-Agent Collective Pipeline (MultiAgentService)', () {
    test('Offline heuristic pipeline breaks down goal into milestones and slots', () async {
      final multiAgent = MultiAgentService();
      const goal = '准备大型技术专家面试：深入复习操作系统、分布式共识算法及高性能网络编程';

      final result = await multiAgent.executePipeline(goal);

      expect(result.scheduledTasks.isNotEmpty, isTrue);
      expect(result.executionTrace.length, equals(6));
      expect(result.executionTrace.any((s) => s.role == AgentRole.manager), isTrue);
      expect(result.executionTrace.any((s) => s.role == AgentRole.decomposer), isTrue);
      expect(result.executionTrace.any((s) => s.role == AgentRole.scheduler), isTrue);

      for (final task in result.scheduledTasks) {
        expect(task.taskTitle.isNotEmpty, isTrue);
        expect(task.triggerTime, isNotNull);
      }
    });
  });

  group('4. Spaced Repetition (Ebbinghaus Memory Curve)', () {
    test('Ebbinghaus interval advancement on remembered and reset on difficulty', () {
      const service = SpacedRepetitionService();
      final task = Reminder(
        id: 'card-1',
        taskTitle: 'Raft Consensus Algorithm',
        quadrantLevel: 2,
        spacedRepetitionLevel: 1,
        nextReviewAt: DateTime.now().subtract(const Duration(hours: 2)),
      );

      expect(service.isDue(task), isTrue);

      // Remembered -> advances to Level 2 (2 days interval)
      final afterRemembered = service.reviewCard(task, true);
      expect(afterRemembered.spacedRepetitionLevel, equals(2));
      expect(afterRemembered.nextReviewAt, isNotNull);
      final daysDiff = afterRemembered.nextReviewAt!.difference(DateTime.now()).inDays;
      expect(daysDiff, inInclusiveRange(1, 2));

      // Level 5 mastery stays at 5 with 15 days
      final masteredCard = task.copyWith(spacedRepetitionLevel: 5);
      final afterMastered = service.reviewCard(masteredCard, true);
      expect(afterMastered.spacedRepetitionLevel, equals(5));

      // Forgot / difficult -> resets back to Level 1 (1 day interval)
      final afterForgot = service.reviewCard(masteredCard, false);
      expect(afterForgot.spacedRepetitionLevel, equals(1));
    });
  });

  group('5. Data Export Service (RFC 4180 CSV with UTF-8 BOM)', () {
    test('Generates Excel 2019+ compatible CSV with UTF-8 BOM and 16 dimensions', () {
      const exportService = DataExportService();
      final now = DateTime(2026, 9, 9, 14, 30);
      final tasks = [
        Reminder(
          id: 'export-1',
          taskTitle: 'Task with "quotes" and, commas',
          taskSummary: 'Description with\nnew line',
          quadrantLevel: 1,
          triggerTime: now,
          isCompleted: false,
          urgencyLevel: 'Urgent',
          spacedRepetitionLevel: 2,
        ),
      ];

      final csvContent = exportService.generateCsvContent(tasks);

      // Verify UTF-8 BOM prefix
      expect(csvContent.startsWith('\uFEFF'), isTrue);

      // Verify RFC 4180 escaping
      expect(csvContent.contains('"Task with ""quotes"" and, commas"'), isTrue);
      expect(csvContent.contains('重要且紧急 (Q1)'), isTrue);
      expect(csvContent.contains('2026'), isTrue);
      expect(csvContent.contains('0x'), isTrue); // Hex bitmask
    });
  });
}
