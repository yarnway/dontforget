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
  final List<_ClickRipple> _ripples = [];
  final Random _random = Random(77);
  Offset? _mousePos;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();

    // Generate 36 dynamic constellation nodes
    for (int i = 0; i < 36; i++) {
      _nodes.add(_AiNode(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        speedX: (_random.nextDouble() - 0.5) * 0.07,
        speedY: (_random.nextDouble() - 0.5) * 0.07,
        radius: _random.nextDouble() * 2.0 + 1.2,
        phase: _random.nextDouble() * 2 * pi,
      ));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerMove(Offset pos) {
    setState(() {
      _mousePos = pos;
    });
  }

  void _onPointerDown(Offset pos, Color primaryColor) {
    setState(() {
      _mousePos = pos;
      _ripples.add(_ClickRipple(
        position: pos,
        createdAt: DateTime.now(),
      ));
      // Prune old ripples (older than 1 sec)
      final now = DateTime.now();
      _ripples.removeWhere((r) => now.difference(r.createdAt).inMilliseconds > 900);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (e) => _onPointerMove(e.localPosition),
      onPointerMove: (e) => _onPointerMove(e.localPosition),
      onPointerDown: (e) => _onPointerDown(e.localPosition, primaryColor),
      child: Stack(
        children: [
          // Base Background
          Positioned.fill(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
          ),

          // Interactive AI Canvas (Constellation, Laser connections, Pointer Spotlight & Waves)
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _AiMeshPainter(
                      nodes: _nodes,
                      ripples: _ripples,
                      progress: _controller.value,
                      mousePos: _mousePos,
                      isDark: isDark,
                      primaryColor: primaryColor,
                    ),
                  );
                },
              ),
            ),
          ),

          // Content UI on top
          Positioned.fill(child: widget.child),
        ],
      ),
    );
  }
}

class _AiNode {
  final double x;
  final double y;
  final double speedX;
  final double speedY;
  final double radius;
  final double phase;

  _AiNode({
    required this.x,
    required this.y,
    required this.speedX,
    required this.speedY,
    required this.radius,
    required this.phase,
  });
}

class _ClickRipple {
  final Offset position;
  final DateTime createdAt;

  _ClickRipple({required this.position, required this.createdAt});
}

class _AiMeshPainter extends CustomPainter {
  final List<_AiNode> nodes;
  final List<_ClickRipple> ripples;
  final double progress;
  final Offset? mousePos;
  final bool isDark;
  final Color primaryColor;

  _AiMeshPainter({
    required this.nodes,
    required this.ripples,
    required this.progress,
    required this.mousePos,
    required this.isDark,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // 1. Ambient radial pulse in background
    final pulseOffset = Offset(
      size.width * (0.5 + 0.25 * sin(progress * 2 * pi)),
      size.height * (0.35 + 0.18 * cos(progress * 2 * pi)),
    );
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          primaryColor.withValues(alpha: isDark ? 0.07 : 0.035),
          const Color(0xFF00E5FF).withValues(alpha: isDark ? 0.04 : 0.018),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromCircle(center: pulseOffset, radius: size.width * 0.75));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), glowPaint);

    // 2. Mouse Pointer Spotlight & Aura
    if (mousePos != null) {
      final mouseGlowPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF00E5FF).withValues(alpha: isDark ? 0.12 : 0.07),
            primaryColor.withValues(alpha: isDark ? 0.06 : 0.03),
            Colors.transparent,
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: mousePos!, radius: 150));

      canvas.drawCircle(mousePos!, 150, mouseGlowPaint);
    }

    // 3. Render Click Ripples
    final now = DateTime.now();
    for (final ripple in ripples) {
      final elapsedMs = now.difference(ripple.createdAt).inMilliseconds;
      if (elapsedMs < 800) {
        final rippleProgress = elapsedMs / 800.0;
        final radius = rippleProgress * 160.0;
        final alpha = (1.0 - rippleProgress) * (isDark ? 0.35 : 0.22);

        final ripplePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (1.0 - rippleProgress) * 2.0 + 0.5
          ..color = const Color(0xFF00E5FF).withValues(alpha: alpha);

        canvas.drawCircle(ripple.position, radius, ripplePaint);
      }
    }

    // 4. Calculate actual positions of nodes with magnetic pull
    final List<Offset> positions = [];
    for (final node in nodes) {
      double nx = (node.x + node.speedX * progress) % 1.0;
      double ny = (node.y + node.speedY * progress) % 1.0;
      if (nx < 0) nx += 1.0;
      if (ny < 0) ny += 1.0;

      Offset pos = Offset(nx * size.width, ny * size.height);

      // Mouse magnetic interaction: gently attract nearby nodes towards pointer
      if (mousePos != null) {
        final distToMouse = (pos - mousePos!).distance;
        const maxMagnetDist = 160.0;
        if (distToMouse < maxMagnetDist && distToMouse > 0.1) {
          final pullFactor = (1.0 - (distToMouse / maxMagnetDist)) * 20.0;
          final dir = (mousePos! - pos) / distToMouse;
          pos = pos + dir * pullFactor;
        }
      }

      positions.add(pos);
    }

    final linePaint = Paint()
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()..style = PaintingStyle.fill;

    const double maxDist = 135.0;

    // 5. Draw Neural Constellation connection lines between nearby nodes
    for (int i = 0; i < positions.length; i++) {
      for (int j = i + 1; j < positions.length; j++) {
        final d = (positions[i] - positions[j]).distance;
        if (d < maxDist) {
          final alphaFactor = (1.0 - (d / maxDist));
          final opacity = (isDark ? 0.16 : 0.08) * alphaFactor;
          linePaint.color = primaryColor.withValues(alpha: opacity);
          linePaint.strokeWidth = 0.8;
          canvas.drawLine(positions[i], positions[j], linePaint);
        }
      }
    }

    // 6. Draw Laser Beams to Mouse Pointer!
    if (mousePos != null) {
      const double mouseBeamRadius = 180.0;
      for (final pos in positions) {
        final d = (pos - mousePos!).distance;
        if (d < mouseBeamRadius) {
          final factor = (1.0 - (d / mouseBeamRadius));
          final beamOpacity = factor * (isDark ? 0.38 : 0.22);

          linePaint.color = const Color(0xFF00E5FF).withValues(alpha: beamOpacity);
          linePaint.strokeWidth = 1.2 * factor + 0.4;
          canvas.drawLine(pos, mousePos!, linePaint);
        }
      }

      // Micro cursor node dot
      final cursorDotPaint = Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: isDark ? 0.6 : 0.4)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(mousePos!, 2.5, cursorDotPaint);
    }

    // 7. Draw Constellation Node Points
    for (int i = 0; i < positions.length; i++) {
      final node = nodes[i];
      final pos = positions[i];
      final breathe = 0.8 + 0.3 * sin((progress * 2 * pi) + node.phase);

      // Outer Halo
      dotPaint.color = primaryColor.withValues(alpha: isDark ? 0.12 : 0.06);
      canvas.drawCircle(pos, node.radius * breathe * 2.6, dotPaint);

      // Core Particle
      dotPaint.color = isDark
          ? Colors.white.withValues(alpha: 0.65)
          : primaryColor.withValues(alpha: 0.50);
      canvas.drawCircle(pos, node.radius * breathe, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AiMeshPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.mousePos != mousePos ||
        oldDelegate.ripples.length != ripples.length ||
        oldDelegate.isDark != isDark;
  }
}
