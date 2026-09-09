import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/dynamic_urgency_service.dart';
import 'package:dont_forget/services/bidirectional_link_service.dart';
import 'package:dont_forget/services/context_trigger_service.dart';

void main() {
  group('v1.5.0 Dynamic Urgency Routing Tests', () {
    const dynamicService = DynamicUrgencyService();

    test('Q2 task due within 24 hours is automatically promoted to Q1', () {
      final now = DateTime.now();
      final q2Urgent = Reminder(
        id: 'task-q2-soon',
        taskTitle: '准备高管周会述职材料',
        quadrantLevel: 2,
        originalQuadrantLevel: 2,
        isDynamicallyPromoted: false,
        triggerTime: now.add(const Duration(hours: 12)),
        createdAt: now.subtract(const Duration(days: 1)),
      );

      final q2Far = Reminder(
        id: 'task-q2-far',
        taskTitle: '阅读架构重构技术专著',
        quadrantLevel: 2,
        originalQuadrantLevel: 2,
        isDynamicallyPromoted: false,
        triggerTime: now.add(const Duration(days: 3)),
        createdAt: now.subtract(const Duration(days: 1)),
      );

      final q1Existing = Reminder(
        id: 'task-q1-exist',
        taskTitle: '处理线上紧急故障',
        quadrantLevel: 1,
        originalQuadrantLevel: 1,
        isDynamicallyPromoted: false,
        triggerTime: now.add(const Duration(hours: 2)),
        createdAt: now.subtract(const Duration(hours: 1)),
      );

      final evaluated = dynamicService.evaluatePromotions([q2Urgent, q2Far, q1Existing]);

      final updatedUrgent = evaluated.firstWhere((r) => r.id == 'task-q2-soon');
      expect(updatedUrgent.quadrantLevel, 1);
      expect(updatedUrgent.isDynamicallyPromoted, true);
      expect(updatedUrgent.originalQuadrantLevel, 2);

      final updatedFar = evaluated.firstWhere((r) => r.id == 'task-q2-far');
      expect(updatedFar.quadrantLevel, 2);
      expect(updatedFar.isDynamicallyPromoted, false);

      final updatedQ1 = evaluated.firstWhere((r) => r.id == 'task-q1-exist');
      expect(updatedQ1.quadrantLevel, 1);
      expect(updatedQ1.isDynamicallyPromoted, false);
    });

    test('Q4 stagnant task opacity calculation and auto-fold predicate', () {
      final now = DateTime.now();

      final q4Fresh = Reminder(
        id: 'q4-fresh',
        taskTitle: '稍后买咖啡豆',
        quadrantLevel: 4,
        createdAt: now.subtract(const Duration(hours: 10)),
      );

      final q4Stagnant = Reminder(
        id: 'q4-stagnant',
        taskTitle: '整理旧书桌抽屉',
        quadrantLevel: 4,
        createdAt: now.subtract(const Duration(hours: 72)),
      );

      final q4Old = Reminder(
        id: 'q4-old',
        taskTitle: '备份去年照片',
        quadrantLevel: 4,
        createdAt: now.subtract(const Duration(hours: 150)),
      );

      // Fresh task has full opacity 1.0 and is not folded
      expect(dynamicService.calculateQ4VisualOpacity(q4Fresh), 1.0);
      expect(dynamicService.isQ4StagnantFolded(q4Fresh), false);

      // 72h task has decayed opacity (< 1.0 and >= 0.35) and is folded
      final stagnantOpacity = dynamicService.calculateQ4VisualOpacity(q4Stagnant);
      expect(stagnantOpacity, lessThan(1.0));
      expect(stagnantOpacity, greaterThanOrEqualTo(0.35));
      expect(dynamicService.isQ4StagnantFolded(q4Stagnant), true);

      // 150h task reaches minimal opacity 0.35 and is folded
      expect(dynamicService.calculateQ4VisualOpacity(q4Old), 0.35);
      expect(dynamicService.isQ4StagnantFolded(q4Old), true);
    });
  });

  group('v1.5.0 Bi-directional Linking & Knowledge Graph Tests', () {
    const linkService = BiDirectionalLinkService();

    test('Local tokenization and Jaccard similarity', () {
      final tokens1 = linkService.extractTokens('准备周五的架构方案汇报材料');
      expect(tokens1.isNotEmpty, true);

      final similarity = linkService.calculateSimilarity('准备周五的架构方案汇报材料', '周五汇报架构设计方案');
      expect(similarity, greaterThan(0.2));

      final zeroSim = linkService.calculateSimilarity('准备周五的架构方案汇报材料', '去超市买苹果香蕉牛奶');
      expect(zeroSim, lessThan(0.1));
    });

    test('buildGraphData creates nodes, edges, and quadrant coordinates', () {
      final taskA = Reminder(
        id: 'task-a',
        taskTitle: '重构网络同步模块',
        quadrantLevel: 2,
        linkedTaskIds: ['task-b'],
      );
      final taskB = Reminder(
        id: 'task-b',
        taskTitle: '编写局域网同步单元测试',
        quadrantLevel: 2,
        linkedTaskIds: ['task-a'],
      );
      final taskC = Reminder(
        id: 'task-c',
        taskTitle: '购买办公用品',
        quadrantLevel: 4,
      );

      final graphData = linkService.buildGraphData([taskA, taskB, taskC]);

      expect(graphData.nodes.length, 3);
      expect(graphData.edges.length, 1); // A <-> B shares one undirected edge
      expect(graphData.edges.first.sourceId, 'task-a');
      expect(graphData.edges.first.targetId, 'task-b');

      final nodeA = graphData.nodes.firstWhere((n) => n.id == 'task-a');
      final nodeB = graphData.nodes.firstWhere((n) => n.id == 'task-b');
      expect(nodeA.quadrantLevel, 2);
      expect(nodeB.quadrantLevel, 2);
    });
  });

  group('v1.5.0 Context-Aware Triggers & Catch-Up Digest Tests', () {
    final contextService = ContextTriggerService();

    tearDown(() {
      contextService.switchProfile(ContextProfile.general);
      contextService.clearSuppressed();
      contextService.resetSessionTriggers();
    });

    test('Context trigger rule serialization and parsing', () {
      const rule = ContextTriggerRule(
        type: 'wifi',
        value: 'Company-Guest',
        prompt: '记得在公司内网提交周报',
      );

      final jsonStr = rule.toJsonString();
      final parsed = ContextTriggerRule.tryParse(jsonStr);

      expect(parsed, isNotNull);
      expect(parsed!.type, 'wifi');
      expect(parsed.value, 'Company-Guest');
      expect(parsed.prompt, '记得在公司内网提交周报');
    });

    test('Deep focus / office mode silently suppresses Q3 and Q4 notifications', () {
      contextService.switchProfile(ContextProfile.deepWork);

      final q1 = Reminder(id: 'q1', taskTitle: '服务器宕机', quadrantLevel: 1);
      final q2 = Reminder(id: 'q2', taskTitle: '下季度规划', quadrantLevel: 2);
      final q3 = Reminder(id: 'q3', taskTitle: '取快递', quadrantLevel: 3);
      final q4 = Reminder(id: 'q4', taskTitle: '看科技博客', quadrantLevel: 4);

      // Q1 and Q2 should NOT be intercepted
      expect(contextService.shouldInterceptNotification(q1), false);
      expect(contextService.shouldInterceptNotification(q2), false);

      // Q3 and Q4 SHOULD be intercepted and added to suppressed queue
      expect(contextService.shouldInterceptNotification(q3), true);
      expect(contextService.shouldInterceptNotification(q4), true);
      expect(contextService.suppressedReminders.length, 2);
    });

    test('Switching from focus mode to general mode automatically triggers catch-up digest', () async {
      contextService.switchProfile(ContextProfile.deepWork);

      final q3 = Reminder(id: 'q3-task', taskTitle: '回复常规邮件', quadrantLevel: 3);
      contextService.shouldInterceptNotification(q3);
      expect(contextService.suppressedReminders.length, 1);

      List<Reminder>? emittedDigest;
      final sub = contextService.onCatchUpDigestReady.listen((digest) {
        emittedDigest = digest;
      });

      // Switch to general mode
      contextService.switchProfile(ContextProfile.general);

      await pumpEventQueue();
      expect(emittedDigest, isNotNull);
      expect(emittedDigest!.length, 1);
      expect(emittedDigest!.first.id, 'q3-task');
      expect(contextService.suppressedReminders.isEmpty, true);

      await sub.cancel();
    });

    test('evaluateContextTriggers matches profile and Wi-Fi rules', () {
      final taskWifi = Reminder(
        id: 'task-wifi',
        taskTitle: '办公打卡',
        quadrantLevel: 3,
        contextTrigger: const ContextTriggerRule(type: 'wifi', value: 'HQ-Corp').toJsonString(),
      );

      final taskProfile = Reminder(
        id: 'task-profile',
        taskTitle: '深度专注阅读',
        quadrantLevel: 2,
        contextTrigger: const ContextTriggerRule(type: 'profile', value: 'deepWork').toJsonString(),
      );

      final taskNone = Reminder(
        id: 'task-none',
        taskTitle: '常规事项',
        quadrantLevel: 4,
      );

      // In General mode with no SSID
      contextService.switchProfile(ContextProfile.general);
      var matched = contextService.evaluateContextTriggers([taskWifi, taskProfile, taskNone]);
      expect(matched.isEmpty, true);

      // When connected to HQ-Corp Wi-Fi
      matched = contextService.evaluateContextTriggers([taskWifi, taskProfile, taskNone], ssid: 'HQ-Corp-5G');
      expect(matched.length, 1);
      expect(matched.first.id, 'task-wifi');

      // When switched to deepWork profile
      contextService.switchProfile(ContextProfile.deepWork);
      matched = contextService.evaluateContextTriggers([taskWifi, taskProfile, taskNone]);
      expect(matched.length, 1);
      expect(matched.first.id, 'task-profile');
    });
  });

  group('v1.5.0 Reminder Model Tests', () {
    test('Reminder serialization preserves v1.5 fields', () {
      final reminder = Reminder(
        id: 'v15-model',
        taskTitle: '端侧知识图谱升级',
        taskSummary: '支持力导向布局与双向检索',
        quadrantLevel: 1,
        originalQuadrantLevel: 2,
        isDynamicallyPromoted: true,
        linkedTaskIds: ['task-1', 'task-2'],
        contextTrigger: '{"type":"profile","value":"office"}',
      );

      final json = reminder.toJson();
      expect(json['original_quadrant_level'], 2);
      expect(json['is_dynamically_promoted'], 1);
      expect(json['linked_task_ids'], '["task-1","task-2"]');
      expect(json['context_trigger'], '{"type":"profile","value":"office"}');

      final restored = Reminder.fromJson(json);
      expect(restored.originalQuadrantLevel, 2);
      expect(restored.isDynamicallyPromoted, true);
      expect(restored.linkedTaskIds, ['task-1', 'task-2']);
      expect(restored.contextTrigger, '{"type":"profile","value":"office"}');
    });

    test('Reminder v1.5 field getters', () {
      final r = Reminder(
        id: 'fields-test',
        taskTitle: 'Fields Test',
        quadrantLevel: 1,
        originalQuadrantLevel: 2,
        isDynamicallyPromoted: true,
        linkedTaskIds: ['other'],
        contextTrigger: '{"type":"wifi","value":"Home"}',
      );

      expect(r.isDynamicallyPromoted, true);
      expect(r.linkedTaskIds.isNotEmpty, true);
      expect(r.contextTrigger != null, true);

      final rPlain = Reminder(
        id: 'plain',
        taskTitle: 'Plain Task',
        quadrantLevel: 4,
      );

      expect(rPlain.isDynamicallyPromoted, false);
      expect(rPlain.linkedTaskIds.isEmpty, true);
      expect(rPlain.contextTrigger, isNull);
    });
  });
}
