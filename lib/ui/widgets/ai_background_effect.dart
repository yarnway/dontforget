import 'dart:math';
import 'package:flutter/material.dart';

class AiBackgroundEffect extends StatefulWidget {
  final Widget child;
  const AiBackgroundEffect({super.key, required this.child});

  @override
  State<AiBackgroundEffect> createState() => _AiBackgroundEffectState();
}

class _AiBackgroundEffectState extends State<AiBackgroundEffect>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<_AiNode> _nodes = [];
  final Random _random = Random(42);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    )..repeat();

    // Generate pseudo-random nodes with fixed seed for determinism
    for (int i = 0; i < 20; i++) {
      _nodes.add(_AiNode(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        speedX: (_random.nextDouble() - 0.5) * 0.08,
        speedY: (_random.nextDouble() - 0.5) * 0.08,
        radius: _random.nextDouble() * 2.2 + 1.2,
      ));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        // Base Theme Background
        Positioned.fill(
          child: Container(
            color: Theme.of(context).scaffoldBackgroundColor,
          ),
        ),

        // Animated AI Cyber Mesh & Floating Particles
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  painter: _AiMeshPainter(
                    nodes: _nodes,
                    progress: _controller.value,
                    isDark: isDark,
                    primaryColor: Theme.of(context).colorScheme.primary,
                  ),
                );
              },
            ),
          ),
        ),

        // Content
        Positioned.fill(child: widget.child),
      ],
    );
  }
}

class _AiNode {
  final double x;
  final double y;
  final double speedX;
  final double speedY;
  final double radius;

  _AiNode({
    required this.x,
    required this.y,
    required this.speedX,
    required this.speedY,
    required this.radius,
  });
}

class _AiMeshPainter extends CustomPainter {
  final List<_AiNode> nodes;
  final double progress;
  final bool isDark;
  final Color primaryColor;

  _AiMeshPainter({
    required this.nodes,
    required this.progress,
    required this.isDark,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Ambient radial pulse
    final pulseOffset = Offset(
      size.width * (0.5 + 0.2 * sin(progress * 2 * pi)),
      size.height * (0.3 + 0.15 * cos(progress * 2 * pi)),
    );
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          primaryColor.withValues(alpha: isDark ? 0.08 : 0.04),
          const Color(0xFF00E5FF).withValues(alpha: isDark ? 0.04 : 0.02),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromCircle(center: pulseOffset, radius: size.width * 0.7));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), glowPaint);

    // Calculate current positions of nodes
    final List<Offset> positions = [];
    for (final node in nodes) {
      // Loop smoothly across borders
      double nx = (node.x + node.speedX * progress) % 1.0;
      double ny = (node.y + node.speedY * progress) % 1.0;
      if (nx < 0) nx += 1.0;
      if (ny < 0) ny += 1.0;
      positions.add(Offset(nx * size.width, ny * size.height));
    }

    final linePaint = Paint()
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()..style = PaintingStyle.fill;

    const double maxDist = 140.0;

    // Draw neural connection lines between nearby nodes
    for (int i = 0; i < positions.length; i++) {
      for (int j = i + 1; j < positions.length; j++) {
        final d = (positions[i] - positions[j]).distance;
        if (d < maxDist) {
          final alphaFactor = (1.0 - (d / maxDist));
          final opacity = (isDark ? 0.18 : 0.10) * alphaFactor;
          linePaint.color = primaryColor.withValues(alpha: opacity);
          canvas.drawLine(positions[i], positions[j], linePaint);
        }
      }
    }

    // Draw nodes
    for (int i = 0; i < positions.length; i++) {
      final node = nodes[i];
      final pos = positions[i];
      final breathe = 0.8 + 0.3 * sin((progress * 2 * pi) + i);

      // Node halo
      dotPaint.color = primaryColor.withValues(alpha: isDark ? 0.12 : 0.08);
      canvas.drawCircle(pos, node.radius * breathe * 2.5, dotPaint);

      // Core point
      dotPaint.color = isDark
          ? Colors.white.withValues(alpha: 0.55)
          : primaryColor.withValues(alpha: 0.45);
      canvas.drawCircle(pos, node.radius * breathe, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AiMeshPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.isDark != isDark ||
        oldDelegate.primaryColor != primaryColor;
  }
}
