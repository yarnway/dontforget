import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/llm_service.dart';

void main() {
  group('Cognitive Intervention Engine Tests', () {
    test('Empty Boat Effect flag serialization and deserialization', () {
      final task = Reminder(
        id: 'test-1',
        taskTitle: '重构接口文档',
        quadrantLevel: 2,
        isEmotionFiltered: true,
      );

      final json = task.toJson();
      expect(json['is_emotion_filtered'], 1);

      final restored = Reminder.fromJson(json);
      expect(restored.isEmotionFiltered, true);
    });

    test('Anti-Social Loafing stagnation detection', () {
      // Not stagnant: created now
      final freshTask = Reminder(
        id: 'test-fresh',
        taskTitle: '刚刚创建的任务',
        quadrantLevel: 2,
        createdAt: DateTime.now(),
      );
      expect(freshTask.isStagnant(hours: 24), false);

      // Stagnant: created 30 hours ago in Q2
      final stagnantTask = Reminder(
        id: 'test-stagnant',
        taskTitle: '拖延停滞的任务',
        quadrantLevel: 2,
        createdAt: DateTime.now().subtract(const Duration(hours: 30)),
      );
      expect(stagnantTask.isStagnant(hours: 24), true);

      // Completed tasks should never be stagnant
      final completedTask = stagnantTask.copyWith(isCompleted: true);
      expect(completedTask.isStagnant(hours: 24), false);

      // Non-Q2 tasks (e.g. Q4 memos) should not trigger stagnation alarm
      final q4Task = stagnantTask.copyWith(quadrantLevel: 4);
      expect(q4Task.isStagnant(hours: 24), false);
    });

    test('Micro-habits JSON list parsing', () {
      final habits = ['1. 打开编辑器', '2. 写下3行核心逻辑', '3. 保存测试'];
      final task = Reminder(
        id: 'test-habits',
        taskTitle: '大任务',
        quadrantLevel: 2,
        subTasks: jsonEncode(habits),
      );

      final parsed = task.getSubTasksList();
      expect(parsed.length, 3);
      expect(parsed.first, '1. 打开编辑器');

      // Empty or invalid subtasks should return empty list
      final emptyTask = task.copyWith(subTasks: '');
      expect(emptyTask.getSubTasksList(), isEmpty);
    });

    test('LLMService offline micro-habits decomposition fallback', () async {
      final service = LLMService();
      final dummySettings = AppSettings(
        id: 'default',
        apiKey: '', // Empty key ensures offline heuristic fallback
        baseUrl: 'http://localhost',
        modelName: 'dummy',
        language: 'zh',
      );

      final task = Reminder(
        id: 'test-decomp',
        taskTitle: '撰写商业企划书',
        quadrantLevel: 2,
      );

      // Test Chinese fallback
      final zhHabits = await service.decomposeTaskToMicroHabits(task, dummySettings, language: 'zh');
      expect(zhHabits.length, 3);
      expect(zhHabits.any((h) => h.contains('撰写商业企划书')), true);

      // Test English fallback
      final enHabits = await service.decomposeTaskToMicroHabits(task, dummySettings, language: 'en');
      expect(enHabits.length, 3);
      expect(enHabits.any((h) => h.contains('撰写商业企划书')), true);

      // Test Japanese fallback
      final jaHabits = await service.decomposeTaskToMicroHabits(task, dummySettings, language: 'ja');
      expect(jaHabits.length, 3);
      expect(jaHabits.any((h) => h.contains('撰写商业企划书')), true);
    });
  });
}
