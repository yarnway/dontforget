import 'dart:math';
import '../models/reminder.dart';

/// 知识图谱节点数据模型
class GraphNode {
  final String id;
  final String title;
  final String? summary;
  final int quadrantLevel;
  final bool isCompleted;
  int degree; // 连接度（边数量）
  double x;
  double y;
  double vx;
  double vy;

  GraphNode({
    required this.id,
    required this.title,
    this.summary,
    required this.quadrantLevel,
    this.isCompleted = false,
    this.degree = 0,
    this.x = 0.0,
    this.y = 0.0,
    this.vx = 0.0,
    this.vy = 0.0,
  });
}

/// 知识图谱边数据模型
class GraphEdge {
  final String sourceId;
  final String targetId;
  final double weight;

  const GraphEdge({
    required this.sourceId,
    required this.targetId,
    this.weight = 1.0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphEdge &&
          ((sourceId == other.sourceId && targetId == other.targetId) ||
              (sourceId == other.targetId && targetId == other.sourceId));

  @override
  int get hashCode => sourceId.hashCode ^ targetId.hashCode;
}

/// 知识图谱整体拓扑结构
class KnowledgeGraphData {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  const KnowledgeGraphData({
    required this.nodes,
    required this.edges,
  });
}

/// 本地双向链接与图谱关联服务 (Bi-directional Linking & Knowledge Graph Engine)
/// 100% 运行在本地，基于分词、特征向量交集与 Jaccard 相似度算法建立备忘间的语义互联
class BiDirectionalLinkService {
  const BiDirectionalLinkService();

  static const Set<String> _stopWords = {
    '的', '了', '在', '是', '我', '有', '和', '就', '不', '人', '都', '一', '一个', '上',
    '也', '很', '到', '说', '要', '去', '你', '会', '着', '没有', '看', '好', '自己', '这',
    '那', '与', '及', '等', '之', '于', '已', '或', '做', '需', '提醒', '事项', '任务',
    'a', 'an', 'the', 'in', 'on', 'at', 'to', 'for', 'of', 'with', 'by', 'from',
    'up', 'about', 'into', 'over', 'after', 'and', 'or', 'but', 'is', 'are', 'was',
    'task', 'todo', 'reminder', 'check', 'do', 'need',
  };

  /// 本地中英文混合特征词提取器
  Set<String> extractTokens(String text) {
    if (text.trim().isEmpty) return {};

    final cleanText = text
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), ' ');

    final tokens = <String>{};
    final parts = cleanText.split(' ');

    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty || _stopWords.contains(trimmed)) continue;

      if (trimmed.length >= 2) {
        tokens.add(trimmed);
      }

      // 针对连续中文词元提取 2-gram 核心词根
      final chineseChars = trimmed.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '');
      if (chineseChars.length >= 2) {
        for (int i = 0; i < chineseChars.length - 1; i++) {
          final biGram = chineseChars.substring(i, i + 2);
          if (!_stopWords.contains(biGram)) {
            tokens.add(biGram);
          }
        }
      }
    }

    return tokens;
  }

  /// 计算两段文本间的 Jaccard 相似度与特征匹配度
  double calculateSimilarity(String textA, String textB) {
    final tokensA = extractTokens(textA);
    final tokensB = extractTokens(textB);

    if (tokensA.isEmpty || tokensB.isEmpty) return 0.0;

    final intersection = tokensA.intersection(tokensB);
    final union = tokensA.union(tokensB);

    if (union.isEmpty) return 0.0;
    final jaccard = intersection.length / union.length;

    // 若共享多个核心特征词，给予额外权重增益
    final matchBonus = min(intersection.length * 0.15, 0.45);
    return min(jaccard + matchBonus, 1.0);
  }

  /// 为给定的任务在所有历史任务库中检索相似度最高且适合双向链接的推荐 ID
  List<String> findSuggestedLinkedIds(
    Reminder targetTask,
    List<Reminder> allReminders, {
    int maxSuggestions = 3,
    double threshold = 0.22,
  }) {
    final targetContent = '${targetTask.taskTitle} ${targetTask.taskSummary ?? ''}';
    final targetTokens = extractTokens(targetContent);
    if (targetTokens.isEmpty) return [];

    final scored = <MapEntry<String, double>>[];

    for (final other in allReminders) {
      if (other.id == targetTask.id) continue;
      // 已存在链接则不重复作为新推荐
      if (targetTask.linkedTaskIds.contains(other.id)) continue;

      final otherContent = '${other.taskTitle} ${other.taskSummary ?? ''}';
      final otherTokens = extractTokens(otherContent);
      final intersection = targetTokens.intersection(otherTokens);

      if (intersection.isEmpty) continue;

      final union = targetTokens.union(otherTokens);
      final sim = (intersection.length / union.length) + (intersection.length >= 2 ? 0.2 : 0.0);

      if (sim >= threshold) {
        scored.add(MapEntry(other.id, sim));
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(maxSuggestions).map((e) => e.key).toList();
  }

  /// 构建知识图谱拓扑数据
  KnowledgeGraphData buildGraphData(List<Reminder> reminders, {double initialRadius = 240.0}) {
    if (reminders.isEmpty) {
      return const KnowledgeGraphData(nodes: [], edges: []);
    }

    final nodesMap = <String, GraphNode>{};
    final edgesSet = <GraphEdge>{};

    // 1. 初始化节点并在极坐标圆周上均匀散布
    final angleStep = (2 * pi) / reminders.length;
    final rng = Random(42);

    for (int i = 0; i < reminders.length; i++) {
      final r = reminders[i];
      final angle = i * angleStep;
      // 轻微抖动避免重叠
      final radius = initialRadius + (rng.nextDouble() * 40 - 20);
      final node = GraphNode(
        id: r.id,
        title: r.taskTitle,
        summary: r.taskSummary,
        quadrantLevel: r.quadrantLevel,
        isCompleted: r.isCompleted,
        x: radius * cos(angle),
        y: radius * sin(angle),
      );
      nodesMap[r.id] = node;
    }

    // 2. 构建显式与隐式语义双向边
    for (final r in reminders) {
      // 显式已存储的双向关联
      for (final linkedId in r.linkedTaskIds) {
        if (nodesMap.containsKey(linkedId) && r.id != linkedId) {
          edgesSet.add(GraphEdge(sourceId: r.id, targetId: linkedId, weight: 1.0));
        }
      }
    }

    // 3. 计算节点度数
    for (final edge in edgesSet) {
      nodesMap[edge.sourceId]?.degree++;
      nodesMap[edge.targetId]?.degree++;
    }

    return KnowledgeGraphData(
      nodes: nodesMap.values.toList(),
      edges: edgesSet.toList(),
    );
  }
}
