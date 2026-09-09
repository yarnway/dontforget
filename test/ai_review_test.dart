import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/llm_service.dart';

void main() {
  group('AI Review Report Tests', () {
    final llmService = LLMService();
    final settings = AppSettings(
      id: '1',
      apiKey: '',
      baseUrl: 'https://api.deepseek.com',
      modelName: 'deepseek-chat',
      language: 'zh',
    );

    test('Empty reminders returns friendly prompt', () async {
      final reportZh = await llmService.generateReviewReport([], settings, language: 'zh');
      expect(reportZh.contains('暂无'), true);

      final reportEn = await llmService.generateReviewReport([], settings, language: 'en');
      expect(reportEn.contains('No tasks'), true);

      final reportJa = await llmService.generateReviewReport([], settings, language: 'ja');
      expect(reportJa.contains('まだありません'), true);
    });

    test('Fallback review generation produces structured markdown in Chinese', () async {
      final reminders = [
        Reminder(id: '1', taskTitle: '准备周会材料', quadrantLevel: 1, isCompleted: true),
        Reminder(id: '2', taskTitle: '产品深度规划', quadrantLevel: 2, isCompleted: true),
        Reminder(id: '3', taskTitle: '回复商务邮件', quadrantLevel: 3, isCompleted: false),
        Reminder(id: '4', taskTitle: '整理读书笔记', quadrantLevel: 4, isCompleted: false),
      ];

      final report = await llmService.generateReviewReport(reminders, settings, language: 'zh');
      expect(report.contains('精力分布与投入诊断'), true);
      expect(report.contains('阶段成就与肯定'), true);
      expect(report.contains('极简破局与行动建议'), true);
      expect(report.contains('50%'), true);
    });

    test('Fallback review generation in English', () async {
      final reminders = [
        Reminder(id: '1', taskTitle: 'Prepare slides', quadrantLevel: 2, isCompleted: true),
        Reminder(id: '2', taskTitle: 'Review PR', quadrantLevel: 2, isCompleted: true),
      ];

      final report = await llmService.generateReviewReport(reminders, settings, language: 'en');
      expect(report.contains('Energy & Priority Diagnosis'), true);
      expect(report.contains('Accomplishments & Affirmation'), true);
      expect(report.contains('Pragmatic Action Tips'), true);
      expect(report.contains('100%'), true);
    });

    test('Fallback review generation in Japanese', () async {
      final reminders = [
        Reminder(id: '1', taskTitle: '資料作成', quadrantLevel: 1, isCompleted: true),
      ];

      final report = await llmService.generateReviewReport(reminders, settings, language: 'ja');
      expect(report.contains('精力配分と優先度の診断'), true);
      expect(report.contains('成果の振り返りと肯定'), true);
      expect(report.contains('生産性向上のアクション提案'), true);
      expect(report.contains('100%'), true);
    });
  });
}
