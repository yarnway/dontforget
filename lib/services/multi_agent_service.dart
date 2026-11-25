import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../models/agent_models.dart';
import '../models/reminder.dart';
import '../models/settings.dart';
import 'dp_scheduler_service.dart';
import 'text_bounds.dart';

class MultiAgentService {
  final dynamic llmService;
  final DPSchedulerService dpScheduler;

  MultiAgentService({
    this.llmService,
    this.dpScheduler = const DPSchedulerService(),
    Dio? client,
  }) : _dio =
           client ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 12),
               sendTimeout: const Duration(seconds: 25),
               receiveTimeout: const Duration(seconds: 25),
             ),
           );

  static final MultiAgentService instance = MultiAgentService();

  final Dio _dio;
  final Set<CancelToken> _activeTokens = {};
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    for (final token in _activeTokens.toList()) {
      token.cancel('Model session ended');
    }
    _dio.close(force: true);
  }

  void _checkActive() {
    if (_disposed) throw StateError('Model session has ended.');
  }

  static String _extractContent(dynamic data) {
    if (data is! Map) return '';
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final first = choices[0];
    if (first is! Map) return '';
    final message = first['message'];
    if (message is! Map) return '';
    final raw = message['content'];
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    final reasoning = message['reasoning_content'];
    return reasoning is String ? reasoning.trim() : '';
  }

  static String _extractJson(String content) {
    final jsonBlockRegex = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
      caseSensitive: false,
    );
    final match = jsonBlockRegex.firstMatch(content);
    if (match != null) return match.group(1)!.trim();
    final start = content.indexOf('{');
    final end = content.lastIndexOf('}');
    if (start != -1 && end != -1 && end > start) {
      return content.substring(start, end + 1);
    }
    return content;
  }

  Future<Response<dynamic>> _postJson(
    String baseUrl,
    String apiKey,
    Map<String, dynamic> body,
  ) async {
    _checkActive();
    final token = CancelToken();
    _activeTokens.add(token);
    try {
      final res = await _dio.post(
        '${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions',
        cancelToken: token,
        options: Options(
          followRedirects: false,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
        data: body,
      );
      _checkActive();
      return res;
    } finally {
      _activeTokens.remove(token);
    }
  }

  Future<MultiAgentExecutionResult> executePipeline(
    String userInput, {
    AppSettings? settings,
    List<Reminder>? existingTasks,
    String language = 'zh',
  }) async {
    _checkActive();
    final effectiveSettings =
        settings?.primaryModelSettings ??
        AppSettings(
          id: 'default',
          apiKey: '',
          baseUrl: '',
          modelName: '',
          language: language,
        );
    final lang = settings?.language ?? language;
    String pick(String zh, String en, String ja) => switch (lang) {
      'en' => en,
      'ja' => ja,
      _ => zh,
    };

    final effectiveTasks = existingTasks ?? <Reminder>[];
    final trace = <AgentStep>[];
    final trimmed = userInput.trim();

    trace.add(
      AgentStep(
        role: AgentRole.manager,
        title: pick(
          '评估全局目标与战略优先级',
          'Evaluating overarching goal & priority',
          '目標全体と優先度を評価中',
        ),
        detail: pick(
          '正在解析输入意图，评估四象限权重与认知阻抗...',
          'Analyzing intent, quadrant priority, and scope...',
          '入力意図と4象限の優先度を解析しています...',
        ),
      ),
    );

    String macroTitle = truncateRunes(trimmed, 25, suffix: '...');
    int targetQuadrant = 2; // Default Q2 Important Non-Urgent
    bool needsDecomposition =
        trimmed.runes.length > 15 ||
        trimmed.contains('准备') ||
        trimmed.contains('重构') ||
        trimmed.contains('面试') ||
        trimmed.contains('项目') ||
        trimmed.contains('学习') ||
        RegExp(
          r'\b(prepare|refactor|interview|project|study|plan)\b',
          caseSensitive: false,
        ).hasMatch(trimmed);

    if (effectiveSettings.apiKey.isNotEmpty) {
      try {
        final managerPrompt = '''
You are the Manager Agent in a Multi-Agent productivity architecture.
User input: "$trimmed"
Analyze the overarching intent and respond in the user's language ($lang).
Strictly return a JSON object:
{
  "macro_title": "Concise title",
  "quadrant": 2,
  "needs_decomposition": true,
  "strategic_advice": "Brief strategy"
}
''';
        final res = await _postJson(
          effectiveSettings.baseUrl,
          effectiveSettings.apiKey,
          {
            'model': effectiveSettings.requestModelName,
            'messages': [
              {'role': 'system', 'content': 'You are the Manager Agent.'},
              {'role': 'user', 'content': managerPrompt},
            ],
            'temperature': 0.2,
            'max_tokens': 256,
            'response_format': {'type': 'json_object'},
          },
        );

        final content = _extractContent(res.data);
        final decoded = jsonDecode(_extractJson(content));

        if (decoded is Map) {
          final rawTitle = decoded['macro_title'] ?? decoded['coreGoal'];
          if (rawTitle is String && rawTitle.trim().isNotEmpty) {
            macroTitle = truncateRunes(rawTitle.trim(), 80);
          }
          final quadRawValue = decoded['quadrant'] ?? decoded['targetQuadrant'];
          final rawQuad = quadRawValue is int
              ? quadRawValue
              : int.tryParse(quadRawValue?.toString() ?? '');
          if (rawQuad != null) {
            // Strictly clamp to 1..4 so SQLite rows never fail BackupInspector or LanSync.
            targetQuadrant = rawQuad.clamp(1, 4);
          }
          final rawNeedsDecomp =
              decoded['needs_decomposition'] ?? decoded['needsDecomposition'];
          if (rawNeedsDecomp is bool) {
            needsDecomposition = rawNeedsDecomp;
          }
        }
      } catch (_) {}
      _checkActive();
    }

    trace.add(
      AgentStep(
        role: AgentRole.manager,
        title: pick(
          '总控评估完成: $macroTitle',
          'Goal assessed: $macroTitle',
          '評価完了: $macroTitle',
        ),
        detail: pick(
          '归属第 $targetQuadrant 象限，${needsDecomposition ? "判定为复合大目标，已指派 Decomposer Agent 拆解" : "判定为单一执行项，移交排程"}',
          'Assigned to Q$targetQuadrant; ${needsDecomposition ? "delegating to Decomposer Agent" : "single actionable item, forwarding to Scheduler"}',
          '第 $targetQuadrant 象限に分類。${needsDecomposition ? "複合目標として分解エージェントへ委譲" : "単一タスクとしてスケジューラへ委譲"}',
        ),
        isCompleted: true,
      ),
    );

    final milestoneSpecs = <({String title, int minutes})>[];
    trace.add(
      AgentStep(
        role: AgentRole.decomposer,
        title: pick(
          '原子化拆解阶段性行动项',
          'Breaking down actionable milestones',
          '実行可能なマイルストーンへ分解中',
        ),
        detail: pick(
          '正在生成低阻抗里程碑与 5 分钟微习惯...',
          'Generating low-friction milestones and starter steps...',
          'マイルストーンと開始ステップを生成しています...',
        ),
      ),
    );

    if (needsDecomposition && effectiveSettings.apiKey.isNotEmpty) {
      try {
        final decompPrompt = '''
You are the Decomposer Agent in a Multi-Agent productivity architecture.
Target Macro Goal: "$macroTitle"
Context: "$trimmed"
Break down this target into 3 actionable milestone subtasks in language ($lang) with estimated minutes (15-120).
Strictly return a JSON object:
{
  "milestones": [
    {"title": "1. ...", "minutes": 20},
    {"title": "2. ...", "minutes": 45},
    {"title": "3. ...", "minutes": 30}
  ]
}
''';
        final res = await _postJson(
          effectiveSettings.baseUrl,
          effectiveSettings.apiKey,
          {
            'model': effectiveSettings.requestModelName,
            'messages': [
              {'role': 'system', 'content': 'You are the Decomposer Agent.'},
              {'role': 'user', 'content': decompPrompt},
            ],
            'temperature': 0.3,
            'max_tokens': 512,
            'response_format': {'type': 'json_object'},
          },
        );

        final content = _extractContent(res.data);
        final decoded = jsonDecode(_extractJson(content));

        if (decoded is Map && decoded['milestones'] is List) {
          for (final m in (decoded['milestones'] as List).take(6)) {
            if (m is Map && m['title'] != null) {
              final title = truncateRunes(m['title'].toString().trim(), 120);
              if (title.isEmpty) continue;
              final rawMin = m['minutes'] is int
                  ? m['minutes'] as int
                  : int.tryParse(m['minutes']?.toString() ?? '');
              final minutes = (rawMin ?? 40).clamp(15, 180);
              milestoneSpecs.add((title: title, minutes: minutes));
            } else if (m is String && m.trim().isNotEmpty) {
              milestoneSpecs.add((
                title: truncateRunes(m.trim(), 120),
                minutes: 40,
              ));
            }
          }
        }
      } catch (_) {}
      _checkActive();
    }

    if (milestoneSpecs.isEmpty) {
      if (!needsDecomposition) {
        milestoneSpecs.add((
          title: truncateRunes(trimmed, 120),
          minutes: 30,
        ));
      } else {
        milestoneSpecs.addAll([
          (
            title: pick(
              '1. 快速筹备：$macroTitle 收集参考资料与框架 (预计15分钟)',
              '1. Kickoff: Gather references & outline for $macroTitle (15m)',
              '1. 準備：$macroTitle の資料整理と骨子作成 (約15分)',
            ),
            minutes: 15,
          ),
          (
            title: pick(
              '2. 深度攻坚：$macroTitle 核心推进与首版落地 (预计45分钟)',
              '2. Deep work: Core implementation for $macroTitle (45m)',
              '2. 集中実行：$macroTitle のコア作業を進める (約45分)',
            ),
            minutes: 45,
          ),
          (
            title: pick(
              '3. 成果检验：$macroTitle 复核质量与收尾跟进 (预计20分钟)',
              '3. Review: Verify outcome & next steps for $macroTitle (20m)',
              '3. 確認：$macroTitle の品質確認と仕上げ (約20分)',
            ),
            minutes: 20,
          ),
        ]);
      }
    }

    final milestones = [for (final spec in milestoneSpecs) spec.title];

    trace.add(
      AgentStep(
        role: AgentRole.decomposer,
        title: pick(
          '拆解完毕，产出 ${milestones.length} 个里程碑项',
          'Prepared ${milestones.length} milestone item(s)',
          '${milestones.length} 件のマイルストーンを作成完了',
        ),
        detail: milestones.join(' | '),
        isCompleted: true,
      ),
    );

    trace.add(
      AgentStep(
        role: AgentRole.scheduler,
        title: pick(
          '调用动态规划算法匹配可用时间槽',
          'Matching optimal focus slots via DP scheduler',
          '動的計画法で空き時間スロットを最適化中',
        ),
        detail: pick(
          '正在扫描日历空闲碎片，规划最优专注填缝时间...',
          'Scanning free calendar blocks to minimize fragmentation...',
          '予定の空き時間を走査し、集中枠を割り当てています...',
        ),
      ),
    );

    final scheduler = dpScheduler;
    final scheduledReminders = <Reminder>[];
    DateTime cursorTime = DateTime.now();
    final safeQuadrant = targetQuadrant.clamp(1, 4);

    for (final spec in milestoneSpecs) {
      final dpResult = scheduler.findOptimalSlot(
        taskDurationMinutes: spec.minutes,
        existingTasks: [...effectiveTasks, ...scheduledReminders],
        referenceTime: cursorTime,
        quadrantLevel: safeQuadrant,
        language: lang,
      );

      final reminder = Reminder(
        id: const Uuid().v4(),
        taskTitle: spec.title,
        taskSummary: pick(
          '由多智能体团队协同拆解自目标: "$macroTitle"。${dpResult.rationale}',
          'Planned from goal "$macroTitle". ${dpResult.rationale}',
          '目標「$macroTitle」から計画。${dpResult.rationale}',
        ),
        quadrantLevel: safeQuadrant,
        urgencyLevel: safeQuadrant == 1 ? 'Urgent' : 'General',
        importanceLevel: safeQuadrant <= 2 ? 'Important' : 'General',
        triggerTime: dpResult.optimalTime,
        subTasks: jsonEncode([
          pick(
            '5分钟启动：打开工作文档扫清桌面',
            '5-min start: Open workspace and clear distractions',
            '5分スタート：作業ファイルを開き環境を整える',
          ),
          pick(
            '推进该子任务的核心步骤',
            'Complete the core steps of this milestone',
            'このマイルストーンの主要ステップを進める',
          ),
        ]),
      );

      scheduledReminders.add(reminder);
      cursorTime = dpResult.optimalTime.add(
        Duration(minutes: spec.minutes + 15),
      );
    }

    trace.add(
      AgentStep(
        role: AgentRole.scheduler,
        title: pick(
          '动态排程完成，已精准投影至四象限',
          'Dynamic scheduling complete',
          '動的スケジューリング完了',
        ),
        detail: pick(
          '已生成 ${scheduledReminders.length} 项排期待办，日历碎片率显著降低。',
          'Scheduled ${scheduledReminders.length} task(s) into optimal focus blocks.',
          '${scheduledReminders.length} 件の予定を最適な時間枠に配置しました。',
        ),
        isCompleted: true,
      ),
    );

    return MultiAgentExecutionResult(
      originalInput: userInput,
      macroGoalTitle: macroTitle,
      overallPriorityQuadrant: safeQuadrant,
      decomposedMilestones: milestones,
      scheduledTasks: scheduledReminders,
      executionTrace: trace,
    );
  }
}
