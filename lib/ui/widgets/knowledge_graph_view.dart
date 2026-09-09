import 'dart:math';
import 'package:flutter/material.dart';
import '../../services/bidirectional_link_service.dart';

/// 知识图谱画布组件，支持节点力导向物理模拟、拖拽与高亮交互
class KnowledgeGraphView extends StatefulWidget {
  final KnowledgeGraphData graphData;
  final String? selectedNodeId;
  final ValueChanged<GraphNode?> onNodeSelected;
  final ValueChanged<GraphNode>? onNodeDoubleTap;

  const KnowledgeGraphView({
    super.key,
    required this.graphData,
    this.selectedNodeId,
    required this.onNodeSelected,
    this.onNodeDoubleTap,
  });

  @override
  State<KnowledgeGraphView> createState() => _KnowledgeGraphViewState();
}

class _KnowledgeGraphViewState extends State<KnowledgeGraphView>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  GraphNode? _draggedNode;
  Offset? _lastDragPos;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_stepPhysics);

    _animController.repeat();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  /// 力导向物理引擎单步迭代计算 (Force-Directed Simulation Step)
  void _stepPhysics() {
    final nodes = widget.graphData.nodes;
    final edges = widget.graphData.edges;
    if (nodes.isEmpty) return;

    const double kRepulsion = 4500.0;
    const double kSpring = 0.045;
    const double restLength = 130.0;
    const double damping = 0.88;
    const double centerPull = 0.012;

    // 1. 节点间库仑斥力 (Coulomb Repulsion)
    for (int i = 0; i < nodes.length; i++) {
      final a = nodes[i];
      for (int j = i + 1; j < nodes.length; j++) {
        final b = nodes[j];
        final dx = b.x - a.x;
        final dy = b.y - a.y;
        final dist = sqrt(dx * dx + dy * dy).clamp(10.0, 600.0);
        final force = kRepulsion / (dist * dist);
        final fx = (dx / dist) * force;
        final fy = (dy / dist) * force;

        if (a != _draggedNode) {
          a.vx -= fx;
          a.vy -= fy;
        }
        if (b != _draggedNode) {
          b.vx += fx;
          b.vy += fy;
        }
      }
    }

    // 2. 关联边胡克引力 (Hooke Spring Attraction)
    final nodeMap = {for (var n in nodes) n.id: n};
    for (final edge in edges) {
      final s = nodeMap[edge.sourceId];
      final t = nodeMap[edge.targetId];
      if (s == null || t == null) continue;

      final dx = t.x - s.x;
      final dy = t.y - s.y;
      final dist = sqrt(dx * dx + dy * dy).clamp(5.0, 800.0);
      final displacement = dist - restLength;
      final force = kSpring * displacement * edge.weight;
      final fx = (dx / dist) * force;
      final fy = (dy / dist) * force;

      if (s != _draggedNode) {
        s.vx += fx;
        s.vy += fy;
      }
      if (t != _draggedNode) {
        t.vx -= fx;
        t.vy -= fy;
      }
    }

    // 3. 中心引力与速度阻尼应用 (Center gravity & damping)
    for (final n in nodes) {
      if (n == _draggedNode) continue;
      // 轻微向坐标系原点归拢
      n.vx -= n.x * centerPull;
      n.vy -= n.y * centerPull;

      n.vx *= damping;
      n.vy *= damping;

      n.x += n.vx;
      n.y += n.vy;
    }

    if (mounted) {
      setState(() {});
    }
  }

  GraphNode? _findNodeAt(Offset pos) {
    for (final n in widget.graphData.nodes.reversed) {
      final radius = 22.0 + min(n.degree * 3.0, 14.0);
      final dist = sqrt(pow(pos.dx - n.x, 2) + pow(pos.dy - n.y, 2));
      if (dist <= radius + 6) {
        return n;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTapUp: (details) {
        final clicked = _findNodeAt(details.localPosition);
        widget.onNodeSelected(clicked);
      },
      onDoubleTapDown: (details) {
        final clicked = _findNodeAt(details.localPosition);
        if (clicked != null && widget.onNodeDoubleTap != null) {
          widget.onNodeDoubleTap!(clicked);
        }
      },
      onPanStart: (details) {
        final node = _findNodeAt(details.localPosition);
        if (node != null) {
          _draggedNode = node;
          _lastDragPos = details.localPosition;
          widget.onNodeSelected(node);
        }
      },
      onPanUpdate: (details) {
        if (_draggedNode != null && _lastDragPos != null) {
          final delta = details.localPosition - _lastDragPos!;
          _draggedNode!.x += delta.dx;
          _draggedNode!.y += delta.dy;
          _draggedNode!.vx = 0;
          _draggedNode!.vy = 0;
          _lastDragPos = details.localPosition;
          setState(() {});
        }
      },
      onPanEnd: (_) {
        _draggedNode = null;
        _lastDragPos = null;
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: _GraphPainter(
          graphData: widget.graphData,
          selectedNodeId: widget.selectedNodeId,
          isDark: isDark,
        ),
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  final KnowledgeGraphData graphData;
  final String? selectedNodeId;
  final bool isDark;

  _GraphPainter({
    required this.graphData,
    required this.selectedNodeId,
    required this.isDark,
  });

  Color _getNodeColor(int quadrant) {
    switch (quadrant) {
      case 1:
        return const Color(0xFFEF5350); // Red
      case 2:
        return const Color(0xFFFFA726); // Orange
      case 3:
        return const Color(0xFF42A5F5); // Blue
      case 4:
      default:
        return const Color(0xFF66BB6A); // Green
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final nodes = graphData.nodes;
    final edges = graphData.edges;
    if (nodes.isEmpty) return;

    final nodeMap = {for (var n in nodes) n.id: n};

    // 找出所有与当前选中节点相连的邻居节点 ID
    final connectedNodeIds = <String>{};
    if (selectedNodeId != null) {
      connectedNodeIds.add(selectedNodeId!);
      for (final e in edges) {
        if (e.sourceId == selectedNodeId) connectedNodeIds.add(e.targetId);
        if (e.targetId == selectedNodeId) connectedNodeIds.add(e.sourceId);
      }
    }

    // 1. 绘制边 (Edges)
    for (final edge in edges) {
      final s = nodeMap[edge.sourceId];
      final t = nodeMap[edge.targetId];
      if (s == null || t == null) continue;

      final isEdgeHighlighted = selectedNodeId == null ||
          (edge.sourceId == selectedNodeId || edge.targetId == selectedNodeId);

      final strokeColor = isEdgeHighlighted
          ? (isDark ? Colors.indigoAccent.withValues(alpha: 0.65) : Colors.indigo.withValues(alpha: 0.55))
          : (isDark ? Colors.white10 : Colors.black12);

      final edgePaint = Paint()
        ..color = strokeColor
        ..strokeWidth = isEdgeHighlighted ? 2.2 : 1.0
        ..style = PaintingStyle.stroke;

      canvas.drawLine(Offset(s.x, s.y), Offset(t.x, t.y), edgePaint);
    }

    // 2. 绘制节点 (Nodes)
    for (final node in nodes) {
      final isSelected = node.id == selectedNodeId;
      final isConnected = connectedNodeIds.contains(node.id);
      final isDimmed = selectedNodeId != null && !isConnected;

      final baseColor = _getNodeColor(node.quadrantLevel);
      final radius = 20.0 + min(node.degree * 2.5, 12.0);

      final nodeAlpha = isDimmed ? 0.35 : (node.isCompleted ? 0.6 : 1.0);
      final effectiveColor = baseColor.withValues(alpha: nodeAlpha);

      // 外发光光晕 (Glow on selected / connected)
      if (isSelected || isConnected) {
        final glowPaint = Paint()
          ..color = baseColor.withValues(alpha: isSelected ? 0.45 : 0.25)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, isSelected ? 12.0 : 6.0);
        canvas.drawCircle(Offset(node.x, node.y), radius + (isSelected ? 8.0 : 4.0), glowPaint);
      }

      // 节点实体圆
      final fillPaint = Paint()
        ..color = isDark
            ? Color.lerp(Colors.grey.shade900, effectiveColor, 0.45)!
            : Color.lerp(Colors.white, effectiveColor, 0.35)!
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(node.x, node.y), radius, fillPaint);

      // 边框环
      final borderPaint = Paint()
        ..color = effectiveColor
        ..strokeWidth = isSelected ? 3.0 : 1.6
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(Offset(node.x, node.y), radius, borderPaint);

      // 象限微标记 (Q1~Q4)
      final textSpan = TextSpan(
        text: 'Q${node.quadrantLevel}',
        style: TextStyle(
          color: isDark ? Colors.white.withValues(alpha: nodeAlpha) : Colors.black87.withValues(alpha: nodeAlpha),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(node.x - textPainter.width / 2, node.y - textPainter.height / 2),
      );

      // 标题标签 (Label below node)
      const maxLabelLength = 10;
      final displayTitle = node.title.length > maxLabelLength
          ? '${node.title.substring(0, maxLabelLength)}...'
          : node.title;

      final labelSpan = TextSpan(
        text: displayTitle,
        style: TextStyle(
          color: isDark
              ? Colors.grey.shade300.withValues(alpha: nodeAlpha)
              : Colors.grey.shade800.withValues(alpha: nodeAlpha),
          fontSize: 10,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        ),
      );
      final labelPainter = TextPainter(
        text: labelSpan,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      labelPainter.paint(
        canvas,
        Offset(node.x - labelPainter.width / 2, node.y + radius + 4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) => true;
}
