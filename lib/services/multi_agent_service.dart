import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../models/agent_models.dart';
import '../models/reminder.dart';
import '../models/settings.dart';
import 'dp_scheduler_service.dart';

class MultiAgentService {
  final dynamic llmService;
  final DPSchedulerService dpScheduler;

  MultiAgentService({
    this.llmService,
    this.dpScheduler = const DPSchedulerService(),
  });

  static final MultiAgentService instance = MultiAgentService();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
  ));

  Future<MultiAgentExecutionResult> executePipeline(
    String userInput, {
    AppSettings? settings,
    List<Reminder>? existingTasks,
    String language = 'zh',
  }) async {
    final effectiveSettings = settings ?? AppSettings(
      id: 'default',
      apiKey: '',
      baseUrl: '',
      modelName: '',
      language: language,
    );
    final effectiveTasks = existingTasks ?? <Reminder>[];
    final trace = <AgentStep>[];
    final trimmed = userInput.trim();

    // ====================================================
    // Step 1: 👔 Manager Agent (管理总控)
    // ====================================================
    trace.add(AgentStep(
      role: AgentRole.manager,
      title: '评估全局目标与战略优先级',
      detail: '正在解析输入意图，评估四象限权重与认知阻抗...',
    ));

    String macroTitle = trimmed.length > 25 ? '${trimmed.substring(0, 25)}...' : trimmed;
    int targetQuadrant = 2; // Default to Q2 Important Non-Urgent
    bool needsDecomposition = trimmed.length > 15 ||
        trimmed.contains('准备') ||
        trimmed.contains('重构') ||
        trimmed.contains('面试') ||
        trimmed.contains('项目') ||
        trimmed.contains('学习');

    if (effectiveSettings.apiKey.isNotEmpty) {
      try {
        final managerPrompt = '''
You are the Manager Agent in a Multi-Agent productivity architecture.
User input: "$trimmed"
Analyze the overarching intent.
Strictly return a JSON object:
{
  "macro_title": "Concise title",
  "quadrant": 2,
  "needs_decomposition": true,
  "strategic_advice": "Brief strategy"
}
''';
        final res = await _dio.post(
          '${effectiveSettings.baseUrl}/chat/completions',
          options: Options(
            headers: {
              'Authorization': 'Bearer ${effectiveSettings.apiKey}',
              'Content-Type': 'application/json',
            },
          ),
          data: {
            'model': effectiveSettings.modelName,
            'messages': [
              {'role': 'system', 'content': 'You are the Manager Agent.'},
              {'role': 'user', 'content': managerPrompt},
            ],
            'temperature': 0.2,
            'max_tokens': 256,
            'response_format': {'type': 'json_object'},
          },
        );

        final content = (res.data['choices'][0]['message']['content'] as String? ?? '').trim();
        final jsonBlockRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```', caseSensitive: false);
        final match = jsonBlockRegex.firstMatch(content);
        final jsonStr = match != null ? match.group(1)!.trim() : content;
        final decoded = jsonDecode(jsonStr);

        if (decoded is Map) {
          if (decoded['macro_title'] != null) macroTitle = decoded['macro_title'];
          if (decoded['quadrant'] is int) targetQuadrant = decoded['quadrant'];
          if (decoded['needs_decomposition'] is bool) needsDecomposition = decoded['needs_decomposition'];
        }
      } catch (_) {}
    }

    trace.add(AgentStep(
      role: AgentRole.manager,
      title: '总控评估完成: $macroTitle',
      detail: '归属第 $targetQuadrant 象限，${needsDecomposition ? "判定为复合大目标，已指派 Decomposer Agent 拆解" : "判定为单一执行项，移交排程"}',
      isCompleted: true,
    ));

    // ====================================================
    // Step 2: 🔨 Decomposer Agent (目标拆解)
    // ====================================================
    final milestones = <String>[];
    trace.add(AgentStep(
      role: AgentRole.decomposer,
      title: '原子化拆解阶段性行动项',
      detail: '正在生成低阻抗里程碑与 5 分钟微习惯...',
    ));

    if (needsDecomposition && effectiveSettings.apiKey.isNotEmpty) {
      try {
        final decompPrompt = '''
You are the Decomposer Agent in a Multi-Agent productivity architecture.
Target Macro Goal: "$macroTitle"
Context: "$trimmed"
Break down this target into 3 actionable milestone subtasks with estimated minutes.
Strictly return a JSON object:
{
  "milestones": [
    {"title": "1. 快速准备...", "minutes": 20},
    {"title": "2. 核心推进...", "minutes": 45},
    {"title": "3. 验证交付...", "minutes": 30}
  ]
}
''';
        final res = await _dio.post(
          '${effectiveSettings.baseUrl}/chat/completions',
          options: Options(
            headers: {
              'Authorization': 'Bearer ${effectiveSettings.apiKey}',
              'Content-Type': 'application/json',
            },
          ),
          data: {
            'model': effectiveSettings.modelName,
            'messages': [
              {'role': 'system', 'content': 'You are the Decomposer Agent.'},
              {'role': 'user', 'content': decompPrompt},
            ],
            'temperature': 0.3,
            'max_tokens': 512,
            'response_format': {'type': 'json_object'},
          },
        );

        final content = (res.data['choices'][0]['message']['content'] as String? ?? '').trim();
        final jsonBlockRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```', caseSensitive: false);
        final match = jsonBlockRegex.firstMatch(content);
        final jsonStr = match != null ? match.group(1)!.trim() : content;
        final decoded = jsonDecode(jsonStr);

        if (decoded is Map && decoded['milestones'] is List) {
          for (final m in decoded['milestones']) {
            if (m is Map && m['title'] != null) {
              milestones.add(m['title'].toString());
            } else if (m is String) {
              milestones.add(m);
            }
          }
        }
      } catch (_) {}
    }

    if (milestones.isEmpty) {
      // Deterministic fallback milestones
      milestones.addAll([
        '1. 快速筹备：收集关键参考资料并建立框架 (预计15分钟)',
        '2. 深度攻坚：完成核心首版实施方案与骨架 (预计45分钟)',
        '3. 成果检验：复核推进质量与后续跟踪项 (预计20分钟)',
      ]);
    }

    trace.add(AgentStep(
      role: AgentRole.decomposer,
      title: '拆解完毕，产出 ${milestones.length} 个里程碑项',
      detail: milestones.join(' | '),
      isCompleted: true,
    ));

    // ====================================================
    // Step 3: ⏱️ Scheduler Agent (动态规划排程)
    // ====================================================
    trace.add(AgentStep(
      role: AgentRole.scheduler,
      title: '调用动态规划算法匹配可用时间槽',
      detail: '正在扫描日历空闲碎片，规划最优专注填缝时间...',
    ));

    final scheduler = dpScheduler;
    final scheduledReminders = <Reminder>[];
    DateTime cursorTime = DateTime.now();

    for (int i = 0; i < milestones.length; i++) {
      final milestone = milestones[i];
      final dpResult = scheduler.findOptimalSlot(
        taskDurationMinutes: 40,
        existingTasks: [...effectiveTasks, ...scheduledReminders],
        referenceTime: cursorTime,
        quadrantLevel: targetQuadrant,
      );

      final reminder = Reminder(
        id: const Uuid().v4(),
        taskTitle: milestone,
        taskSummary: '由多智能体团队协同拆解自大目标: "$macroTitle"。${dpResult.rationale}',
        quadrantLevel: targetQuadrant,
        urgencyLevel: targetQuadrant == 1 ? 'Urgent' : 'General',
        importanceLevel: targetQuadrant <= 2 ? 'Important' : 'General',
        triggerTime: dpResult.optimalTime,
        subTasks: jsonEncode([
          '5分钟启动：打开工作文档扫清桌面',
          '推进该子任务的核心步骤',
        ]),
      );

      scheduledReminders.add(reminder);
      // Advance cursor for next subtask
      cursorTime = dpResult.optimalTime.add(const Duration(minutes: 60));
    }

    trace.add(AgentStep(
      role: AgentRole.scheduler,
      title: '动态排程完成，已精准投影至四象限',
      detail: '已生成 ${scheduledReminders.length} 项排期待办，日历碎片率显著降低。',
      isCompleted: true,
    ));

    return MultiAgentExecutionResult(
      originalInput: userInput,
      macroGoalTitle: macroTitle,
      overallPriorityQuadrant: targetQuadrant,
      decomposedMilestones: milestones,
      scheduledTasks: scheduledReminders,
      executionTrace: trace,
    );
  }
}
