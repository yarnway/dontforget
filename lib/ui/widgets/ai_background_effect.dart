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
  late AnimationController _animController;
  final List<_Particle3D> _particles = [];
  final List<_RippleWave> _waves = [];
  Offset? _mousePos;
  Offset? _lastMousePos;
  DateTime _lastMoveTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    )..repeat();

    _initLogoParticles();
  }

  void _initLogoParticles() {
    final rand = Random(42);

    // 1. Upper Diagonal Ribbon of Logo (Chevron Stroke 1)
    // From (0.42, -0.65) to (-0.38, 0.05)
    for (int i = 0; i < 65; i++) {
      final t = rand.nextDouble();
      final w = (rand.nextDouble() - 0.5) * 0.18;
      final z = (rand.nextDouble() - 0.5) * 0.28;

      final startX = 0.42 + w;
      const startY = -0.65;
      final endX = -0.38 + w;
      const endY = 0.05;

      final bx = startX + (endX - startX) * t;
      final by = startY + (endY - startY) * t;

      _particles.add(_createParticle(bx, by, z, rand, const Color(0xFF00E5FF)));
    }

    // 2. Lower Chevron of Logo (Chevron Stroke 2)
    // Wing part A: from (-0.15, 0.15) to (0.35, -0.05)
    for (int i = 0; i < 35; i++) {
      final t = rand.nextDouble();
      final w = (rand.nextDouble() - 0.5) * 0.15;
      final z = (rand.nextDouble() - 0.5) * 0.26;

      final bx = -0.15 + (0.35 - (-0.15)) * t + w * 0.5;
      final by = 0.15 + (-0.05 - 0.15) * t + w;

      _particles.add(_createParticle(bx, by, z, rand, const Color(0xFF2979FF)));
    }

    // Wing part B: from (0.05, 0.28) down to (0.42, 0.65)
    for (int i = 0; i < 45; i++) {
      final t = rand.nextDouble();
      final w = (rand.nextDouble() - 0.5) * 0.16;
      final z = (rand.nextDouble() - 0.5) * 0.26;

      final bx = 0.05 + (0.42 - 0.05) * t + w * 0.5;
      final by = 0.28 + (0.65 - 0.28) * t + w;

      _particles.add(_createParticle(bx, by, z, rand, const Color(0xFF00B0FF)));
    }

    // 3. 3D Orbital Rings around the Logo
    for (int i = 0; i < 40; i++) {
      final angle = (i / 40.0) * 2 * pi;
      final radius = 0.82 + (rand.nextDouble() - 0.5) * 0.14;
      const tilt = 0.45;

      final bx = cos(angle) * radius;
      final by = sin(angle) * radius * cos(tilt);
      final bz = sin(angle) * radius * sin(tilt) + (rand.nextDouble() - 0.5) * 0.12;

      _particles.add(_createParticle(bx, by, bz, rand, const Color(0xFF7C4DFF)));
    }
  }

  _Particle3D _createParticle(
      double bx, double by, double bz, Random rand, Color baseColor) {
    return _Particle3D(
      baseX: bx,
      baseY: by,
      baseZ: bz,
      curX: bx,
      curY: by,
      curZ: bz,
      baseRadius: rand.nextDouble() * 1.8 + 1.2,
      phase: rand.nextDouble() * 2 * pi,
      color: baseColor,
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _onPointerHover(Offset pos) {
    final now = DateTime.now();
    _mousePos = pos;

    // If mouse moved significantly, emit a continuous repulsion wave
    if (_lastMousePos != null) {
      final dist = (pos - _lastMousePos!).distance;
      if (dist > 12 && now.difference(_lastMoveTime).inMilliseconds > 60) {
        _waves.add(_RippleWave(
          center: pos,
          createdAt: now,
          maxRadius: 220,
          strength: 0.12,
        ));
        _lastMoveTime = now;
      }
    }
    _lastMousePos = pos;
  }

  void _onPointerDown(Offset pos) {
    final now = DateTime.now();
    _mousePos = pos;
    // Click triggers a powerful 3D push dispersal shockwave
    _waves.add(_RippleWave(
      center: pos,
      createdAt: now,
      maxRadius: 360,
      strength: 0.32,
    ));

    // Clean up old waves
    _waves.removeWhere((w) => now.difference(w.createdAt).inMilliseconds > 1000);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (e) => _onPointerHover(e.localPosition),
      onPointerMove: (e) => _onPointerHover(e.localPosition),
      onPointerDown: (e) => _onPointerDown(e.localPosition),
      child: Stack(
        children: [
          // Base Background
          Positioned.fill(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
          ),

          // 3D Optical Logo Hologram & Wave Dispersal Painter
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _animController,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _Logo3dParticlePainter(
                      particles: _particles,
                      waves: _waves,
                      progress: _animController.value,
                      mousePos: _mousePos,
                      isDark: isDark,
                      primaryColor: primaryColor,
                    ),
                  );
                },
              ),
            ),
          ),

          // Content Layer (suspended on top of 3D hologram)
          Positioned.fill(child: widget.child),
        ],
      ),
    );
  }
}

class _Particle3D {
  final double baseX;
  final double baseY;
  final double baseZ;

  double curX;
  double curY;
  double curZ;

  double vx = 0;
  double vy = 0;
  double vz = 0;

  final double baseRadius;
  final double phase;
  final Color color;

  // Screen projected coordinates
  double screenX = 0;
  double screenY = 0;
  double scale = 1;
  double depthZ = 0;

  _Particle3D({
    required this.baseX,
    required this.baseY,
    required this.baseZ,
    required this.curX,
    required this.curY,
    required this.curZ,
    required this.baseRadius,
    required this.phase,
    required this.color,
  });
}

class _RippleWave {
  final Offset center;
  final DateTime createdAt;
  final double maxRadius;
  final double strength;

  _RippleWave({
    required this.center,
    required this.createdAt,
    required this.maxRadius,
    required this.strength,
  });
}

class _Logo3dParticlePainter extends CustomPainter {
  final List<_Particle3D> particles;
  final List<_RippleWave> waves;
  final double progress;
  final Offset? mousePos;
  final bool isDark;
  final Color primaryColor;

  _Logo3dParticlePainter({
    required this.particles,
    required this.waves,
    required this.progress,
    required this.mousePos,
    required this.isDark,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final baseRadius = min(size.width, size.height) * 0.38;

    // 1. Interactive 3D Parallax & Continuous Gentle Gyroscope
    double parallaxX = 0;
    double parallaxY = 0;
    if (mousePos != null) {
      parallaxX = (mousePos!.dx / size.width - 0.5) * 0.35;
      parallaxY = (mousePos!.dy / size.height - 0.5) * 0.30;
    }

    final double rotY = sin(progress * 2 * pi) * 0.18 + parallaxX;
    final double rotX = cos(progress * 2 * pi * 0.5) * 0.10 - parallaxY;

    final double cosY = cos(rotY);
    final double sinY = sin(rotY);
    final double cosX = cos(rotX);
    final double sinX = sin(rotX);

    const double cameraZ = 2.5;
    const double fov = 1.9;

    // 2. Physics Update: Wave Dispersal (波纹推散) & Hooke's Elastic Return
    final now = DateTime.now();

    for (final p in particles) {
      // 2.1 Ripple Wave Dispersal Force (冲击推散)
      for (final wave in waves) {
        final elapsed = now.difference(wave.createdAt).inMilliseconds;
        if (elapsed < 850) {
          final waveProg = elapsed / 850.0;
          final currentRadius = waveProg * wave.maxRadius;
          final distToCenter = Offset(p.screenX - wave.center.dx, p.screenY - wave.center.dy).distance;
          final waveDelta = (distToCenter - currentRadius).abs();

          // If within the shockwave band (width 40px)
          if (waveDelta < 40.0 && distToCenter > 1.0) {
            final waveFactor = (1.0 - waveDelta / 40.0) * (1.0 - waveProg) * wave.strength;
            final norm = Offset((p.screenX - wave.center.dx) / distToCenter, (p.screenY - wave.center.dy) / distToCenter);

            // Push outward in 3D
            p.vx += norm.dx * waveFactor * 0.09;
            p.vy += norm.dy * waveFactor * 0.09;
            p.vz += (waveFactor * 0.06);
          }
        }
      }

      // 2.2 Direct Mouse Repulsion (鼠标滑动推散)
      if (mousePos != null) {
        final dist = Offset(p.screenX - mousePos!.dx, p.screenY - mousePos!.dy).distance;
        const double mouseRepelDist = 120.0;
        if (dist < mouseRepelDist && dist > 1.0) {
          final repel = (1.0 - dist / mouseRepelDist) * 0.025;
          final norm = Offset((p.screenX - mousePos!.dx) / dist, (p.screenY - mousePos!.dy) / dist);
          p.vx += norm.dx * repel;
          p.vy += norm.dy * repel;
          p.vz -= repel * 0.5;
        }
      }

      // 2.3 Spring Restitution back to Logo Base coordinates (弹性复位)
      const double springK = 0.055;
      const double damping = 0.88;

      final diffX = p.baseX - p.curX;
      final diffY = p.baseY - p.curY;
      final diffZ = p.baseZ - p.curZ;

      p.vx = (p.vx + diffX * springK) * damping;
      p.vy = (p.vy + diffY * springK) * damping;
      p.vz = (p.vz + diffZ * springK) * damping;

      p.curX += p.vx;
      p.curY += p.vy;
      p.curZ += p.vz;

      // 2.4 3D Rotation & Projection
      // Y-axis rotation
      final x1 = p.curX * cosY + p.curZ * sinY;
      final y1 = p.curY;
      final z1 = -p.curX * sinY + p.curZ * cosY;

      // X-axis rotation
      final x2 = x1;
      final y2 = y1 * cosX - z1 * sinX;
      final z2 = y1 * sinX + z1 * cosX;

      final scale = fov / (cameraZ + z2);

      p.screenX = centerX + x2 * scale * baseRadius;
      p.screenY = centerY + y2 * scale * baseRadius;
      p.scale = scale;
      p.depthZ = z2;
    }

    // 3. Render Expanding Shockwaves (波纹视觉效果)
    for (final wave in waves) {
      final elapsed = now.difference(wave.createdAt).inMilliseconds;
      if (elapsed < 850) {
        final prog = elapsed / 850.0;
        final r = prog * wave.maxRadius;
        final alpha = (1.0 - prog) * (isDark ? 0.28 : 0.18);

        final wavePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (1.0 - prog) * 2.2 + 0.5
          ..shader = RadialGradient(
            colors: [
              const Color(0xFF00E5FF).withValues(alpha: alpha * 0.1),
              const Color(0xFF00E5FF).withValues(alpha: alpha),
            ],
            stops: const [0.8, 1.0],
          ).createShader(Rect.fromCircle(center: wave.center, radius: r + 1));

        canvas.drawCircle(wave.center, r, wavePaint);
      }
    }

    // 4. Sort particles by depth for true 3D volumetric rendering
    final sortedParticles = List<_Particle3D>.from(particles)
      ..sort((a, b) => b.depthZ.compareTo(a.depthZ));

    // 5. Draw Holographic Laser Threads between adjacent particles in the logo
    final threadPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    const double threadMaxDist = 48.0;
    for (int i = 0; i < sortedParticles.length; i++) {
      for (int j = i + 1; j < min(i + 8, sortedParticles.length); j++) {
        final p1 = sortedParticles[i];
        final p2 = sortedParticles[j];
        final dist = Offset(p1.screenX - p2.screenX, p1.screenY - p2.screenY).distance;
        if (dist < threadMaxDist) {
          final factor = 1.0 - (dist / threadMaxDist);
          final alpha = factor * (isDark ? 0.18 : 0.10) * p1.scale;
          threadPaint.color = p1.color.withValues(alpha: alpha);
          canvas.drawLine(Offset(p1.screenX, p1.screenY), Offset(p2.screenX, p2.screenY), threadPaint);
        }
      }
    }

    // 6. Draw 3D Optical Glowing Particles (Core + Halo + Flare)
    final haloPaint = Paint()..style = PaintingStyle.fill;
    final corePaint = Paint()..style = PaintingStyle.fill;

    for (final p in sortedParticles) {
      final breathe = 0.8 + 0.3 * sin((progress * 2 * pi) + p.phase);
      final depthBrightness = ((p.depthZ + 1.0) / 2.0).clamp(0.2, 1.0);
      final radius = p.baseRadius * p.scale * breathe;

      // Outer optical glow halo
      final haloAlpha = (isDark ? 0.22 : 0.12) * depthBrightness;
      haloPaint.color = p.color.withValues(alpha: haloAlpha);
      canvas.drawCircle(Offset(p.screenX, p.screenY), radius * 3.2, haloPaint);

      // Core luminous point
      final coreAlpha = (isDark ? 0.85 : 0.65) * depthBrightness;
      corePaint.color = isDark
          ? Colors.white.withValues(alpha: coreAlpha)
          : p.color.withValues(alpha: coreAlpha);
      canvas.drawCircle(Offset(p.screenX, p.screenY), radius, corePaint);
    }

    // 7. Mouse Pointer Subtle Halo
    if (mousePos != null) {
      final pointerGlow = Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF00E5FF).withValues(alpha: isDark ? 0.08 : 0.04),
            Colors.transparent,
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: mousePos!, radius: 100));
      canvas.drawCircle(mousePos!, 100, pointerGlow);
    }
  }

  @override
  bool shouldRepaint(covariant _Logo3dParticlePainter oldDelegate) => true;
}
