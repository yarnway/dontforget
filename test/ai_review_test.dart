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
      final reportZh = await llmService.generateReviewReport(
        [],
        settings,
        language: 'zh',
      );
      expect(reportZh.contains('暂无'), true);

      final reportEn = await llmService.generateReviewReport(
        [],
        settings,
        language: 'en',
      );
      expect(reportEn.contains('No tasks'), true);

      final reportJa = await llmService.generateReviewReport(
        [],
        settings,
        language: 'ja',
      );
      expect(reportJa.contains('まだありません'), true);
    });

    test(
      'zero completed and all completed reports avoid invented progress',
      () async {
        final pending = await llmService.generateReviewReport([
          Reminder(id: '1', taskTitle: 'Pending', quadrantLevel: 2),
        ], settings);
        expect(pending, contains('不限日期'));
        expect(pending, contains('没有标记为完成'));
        expect(pending, contains('数量不能反映实际投入时间'));
        expect(pending, isNot(contains('执行动能')));
        expect(pending, isNot(contains('本周')));
        final completed = await llmService.generateReviewReport([
          Reminder(
            id: '1',
            taskTitle: 'Done',
            quadrantLevel: 2,
            isCompleted: true,
          ),
        ], settings);
        expect(completed, contains('回顾已完成记录'));
        expect(completed, isNot(contains('从未完成事项中选一项')));
      },
    );

    test(
      'Fallback review generation produces structured markdown in Chinese',
      () async {
        final reminders = [
          Reminder(
            id: '1',
            taskTitle: '准备周会材料',
            quadrantLevel: 1,
            isCompleted: true,
          ),
          Reminder(
            id: '2',
            taskTitle: '产品深度规划',
            quadrantLevel: 2,
            isCompleted: true,
          ),
          Reminder(
            id: '3',
            taskTitle: '回复商务邮件',
            quadrantLevel: 3,
            isCompleted: false,
          ),
          Reminder(
            id: '4',
            taskTitle: '整理读书笔记',
            quadrantLevel: 4,
            isCompleted: false,
          ),
        ];

        final report = await llmService.generateReviewReport(
          reminders,
          settings,
          language: 'zh',
        );
        expect(report.contains('任务概览'), true);
        expect(report.contains('数据说明'), true);
        expect(report.contains('下一步建议'), true);
        expect(report.contains('50%'), true);
      },
    );

    test('Fallback review generation in English', () async {
      final reminders = [
        Reminder(
          id: '1',
          taskTitle: 'Prepare slides',
          quadrantLevel: 2,
          isCompleted: true,
        ),
        Reminder(
          id: '2',
          taskTitle: 'Review PR',
          quadrantLevel: 2,
          isCompleted: true,
        ),
      ];

      final report = await llmService.generateReviewReport(
        reminders,
        settings,
        language: 'en',
      );
      expect(report.contains('Task overview'), true);
      expect(report.contains('What these data show'), true);
      expect(report.contains('Suggested next steps'), true);
      expect(report.contains('100%'), true);
    });

    test('Fallback review generation in Japanese', () async {
      final reminders = [
        Reminder(
          id: '1',
          taskTitle: '資料作成',
          quadrantLevel: 1,
          isCompleted: true,
        ),
      ];

      final report = await llmService.generateReviewReport(
        reminders,
        settings,
        language: 'ja',
      );
      expect(report.contains('タスクの概要'), true);
      expect(report.contains('データの範囲'), true);
      expect(report.contains('次の行動の提案'), true);
      expect(report.contains('100%'), true);
    });
  });
}
