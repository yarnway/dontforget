import 'dart:math';
import 'package:flutter/material.dart';

/// Next-Generation 3D Holographic AI Background
/// Features:
/// - 3x particle density (~555 logo particles + 70 deep-space stars)
/// - Astra & DeepSeek inspired multi-chromatic AI aesthetics
/// - Twinkling cosmic starlight with 4-point optical diffraction cross-flares
/// - Synaptic wire bundles with traveling photon energy pulses (线束脉冲)
/// - Viscous damped mouse tracking & fluid wake physics (阻尼交互)
/// - Organic multi-axis spatial floating & Lissajous orbital precession (自然缓慢空间摆动)
/// - 3D shockwave dispersal & Hooke's law elastic recovery
class AiBackgroundEffect extends StatefulWidget {
  final Widget child;
  const AiBackgroundEffect({super.key, required this.child});

  @override
  State<AiBackgroundEffect> createState() => _AiBackgroundEffectState();
}

class _AiBackgroundEffectState extends State<AiBackgroundEffect>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  // Particle sets
  final List<_Particle3D> _particles = [];
  final List<_Star3D> _stars = [];
  final List<_RippleWave> _waves = [];

  // Damped mouse tracking with viscous inertia
  Offset? _rawMousePos;
  Offset _dampedMousePos = const Offset(-1000, -1000);
  Offset _prevDampedMousePos = const Offset(-1000, -1000);
  Offset _mouseVelocity = Offset.zero;
  DateTime _lastMoveTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    // 24-second ultra-smooth loop for majestic celestial rotation
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    )..repeat();

    _initLogoParticles();
    _initCosmicStars();
  }

  void _initLogoParticles() {
    final rand = Random(2026);

    // Color palette inspired by Astra (celestial violet-cyan) & DeepSeek (oceanic bioluminescence)
    const colorPureWhite = Color(0xFFFFFFFF);
    const colorCyan = Color(0xFF00F0FF);
    const colorElectricBlue = Color(0xFF2979FF);
    const colorDeepSeekAqua = Color(0xFF00B0FF);
    const colorAstraViolet = Color(0xFF7C4DFF);
    const colorNeonMagenta = Color(0xFFE040FB);
    const colorEmeraldCyan = Color(0xFF00E676);

    // 1. Upper Sweeping 3D Chevron Ribbon (Stroke 1) - 240 particles across 3 volumetric depth layers
    // Spatially arches forward into +Z and tucks back into -Z with distinct front/core/back facets
    for (int i = 0; i < 240; i++) {
      final t = i / 240.0;
      final layer = i % 3; // 0 = Front Facet, 1 = Core Spine, 2 = Rear Facet

      // S-curve spatial trajectory
      const startX = 0.44;
      const startY = -0.68;
      const endX = -0.38;
      const endY = 0.06;

      final spineX = startX + (endX - startX) * t;
      final spineY = startY + (endY - startY) * t;
      // Prominent forward 3D curvature: bows outward toward viewer by +0.48 in the middle!
      final spineZ = sin(t * pi) * 0.48 - 0.20;

      final w = (rand.nextDouble() - 0.5) * 0.14;
      double bx, by, bz;
      Color color;

      if (layer == 0) {
        // Front High-Relief Facet (凸出高光面)
        bx = spineX + w * 0.7;
        by = spineY + w * 0.4;
        bz = spineZ + 0.26 + (rand.nextDouble() - 0.5) * 0.08;
        // Ultra-luminous cyan to white-hot radiant blue
        color = Color.lerp(colorCyan, colorPureWhite, 0.4 + rand.nextDouble() * 0.3)!;
      } else if (layer == 1) {
        // Core Ridge Spine (核心骨架层)
        bx = spineX + w;
        by = spineY + w * 0.6;
        bz = spineZ + (rand.nextDouble() - 0.5) * 0.10;
        // Astra violet to electric cyan gradient
        color = t < 0.5
            ? Color.lerp(colorAstraViolet, colorCyan, t * 2.0)!
            : Color.lerp(colorCyan, colorElectricBlue, (t - 0.5) * 2.0)!;
      } else {
        // Rear Underbelly Facet (深景背光面)
        bx = spineX - w * 0.7;
        by = spineY - w * 0.4;
        bz = spineZ - 0.28 + (rand.nextDouble() - 0.5) * 0.08;
        // Deep cosmic violet & midnight magenta
        color = Color.lerp(colorAstraViolet, colorNeonMagenta, t)!;
      }

      _particles.add(_createParticle(bx, by, bz, rand, color));
    }

    // 2. Lower Left Chevron Wing (Wing A) - 130 particles
    // Cuts diagonally through 3D space from depth -0.48 through to foreground +0.42!
    for (int i = 0; i < 130; i++) {
      final t = i / 130.0;
      final isFront = (i % 2 == 0);
      final w = (rand.nextDouble() - 0.5) * 0.16;

      final spineX = -0.16 + (0.36 - (-0.16)) * t;
      final spineY = 0.16 + (-0.06 - 0.16) * t;
      // Traverses from deep space -0.48 to foreground +0.42
      final spineZ = -0.48 + 0.90 * t;

      final bx = spineX + w * 0.6;
      final by = spineY + w;
      final bz = spineZ + (isFront ? 0.18 : -0.18) + (rand.nextDouble() - 0.5) * 0.08;

      final color = isFront
          ? Color.lerp(colorDeepSeekAqua, colorCyan, t)!
          : Color.lerp(colorElectricBlue, const Color(0xFF1A237E), t)!;

      _particles.add(_createParticle(bx, by, bz, rand, color));
    }

    // 3. Lower Right Chevron Wing (Wing B) - 150 particles
    // Sweeps backwards in opposite depth direction from foreground +0.42 to deep space -0.46!
    for (int i = 0; i < 150; i++) {
      final t = i / 150.0;
      final isFront = (i % 2 == 0);
      final w = (rand.nextDouble() - 0.5) * 0.16;

      final spineX = 0.04 + (0.43 - 0.04) * t;
      final spineY = 0.27 + (0.66 - 0.27) * t;
      // Sweeps backwards from +0.42 into deep space -0.46
      final spineZ = 0.42 - 0.88 * t;

      final bx = spineX + w * 0.5;
      final by = spineY + w;
      final bz = spineZ + (isFront ? 0.18 : -0.18) + (rand.nextDouble() - 0.5) * 0.08;

      final color = isFront
          ? Color.lerp(colorCyan, colorEmeraldCyan, t * 0.8)!
          : Color.lerp(colorDeepSeekAqua, colorAstraViolet, t)!;

      _particles.add(_createParticle(bx, by, bz, rand, color));
    }

    // 4. Dual 3D Intersecting Celestial Orbit Rings (天体交错环) - 140 particles
    // Ring 1 (Meridian Gyro Ring, tilted 50° across X, passing through front Z=+0.75 to rear Z=-0.75)
    for (int i = 0; i < 70; i++) {
      final angle = (i / 70.0) * 2 * pi;
      final radius = 0.88 + (rand.nextDouble() - 0.5) * 0.08;
      const tiltX = 0.85; // ~49 degrees
      const yawY = 0.42;  // ~24 degrees

      final x0 = cos(angle) * radius;
      final y0 = sin(angle) * radius * cos(tiltX);
      final z0 = sin(angle) * radius * sin(tiltX);

      // Rotate around Y
      final bx = x0 * cos(yawY) + z0 * sin(yawY);
      final by = y0;
      final bz = -x0 * sin(yawY) + z0 * cos(yawY) + (rand.nextDouble() - 0.5) * 0.06;

      _particles.add(_createParticle(bx, by, bz, rand, colorAstraViolet));
    }

    // Ring 2 (Counter-tilted Polar Gyro Ring, tilted -62° across X, rolled 35° across Z)
    for (int i = 0; i < 70; i++) {
      final angle = (i / 70.0) * 2 * pi;
      final radius = 0.82 + (rand.nextDouble() - 0.5) * 0.08;
      const tiltX = -1.05; // ~-60 degrees
      const rollZ = 0.55;  // ~31 degrees

      final x0 = cos(angle) * radius;
      final y0 = sin(angle) * radius * cos(tiltX);
      final z0 = sin(angle) * radius * sin(tiltX);

      // Rotate around Z
      final bx = x0 * cos(rollZ) - y0 * sin(rollZ);
      final by = x0 * sin(rollZ) + y0 * cos(rollZ);
      final bz = z0 + (rand.nextDouble() - 0.5) * 0.06;

      _particles.add(_createParticle(bx, by, bz, rand, colorNeonMagenta));
    }
  }

  void _initCosmicStars() {
    final rand = Random(777);
    // 180 ambient 3D deep-space background stars distributed in true 3D cosmic volume
    for (int i = 0; i < 180; i++) {
      final x = (rand.nextDouble() - 0.5) * 3.6;
      final y = (rand.nextDouble() - 0.5) * 2.8;
      final z = (rand.nextDouble() - 0.5) * 3.2;
      final baseSize = rand.nextDouble() * 1.6 + 0.8;
      final twinkleSpeed = rand.nextDouble() * 2.5 + 1.0;
      final phase = rand.nextDouble() * 2 * pi;
      // Top 36 stars have 4-point optical diffraction cross flares
      final hasFlare = i < 36;

      _stars.add(_Star3D(
        x: x,
        y: y,
        z: z,
        baseSize: baseSize,
        twinkleSpeed: twinkleSpeed,
        phase: phase,
        hasFlare: hasFlare,
      ));
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
      baseRadius: rand.nextDouble() * 1.6 + 1.1,
      phase: rand.nextDouble() * 2 * pi,
      pulseSpeed: rand.nextDouble() * 1.5 + 1.0,
      color: baseColor,
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _onPointerHover(Offset pos) {
    _rawMousePos = pos;
    final now = DateTime.now();

    // If mouse moved actively, emit soft fluid ripples
    if (now.difference(_lastMoveTime).inMilliseconds > 70) {
      if ((pos - _dampedMousePos).distance > 18) {
        _waves.add(_RippleWave(
          center: pos,
          createdAt: now,
          maxRadius: 240,
          strength: 0.14,
        ));
        _lastMoveTime = now;
      }
    }
  }

  void _onPointerDown(Offset pos) {
    _rawMousePos = pos;
    final now = DateTime.now();

    // Powerful 3D push shockwave on click
    _waves.add(_RippleWave(
      center: pos,
      createdAt: now,
      maxRadius: 380,
      strength: 0.36,
    ));

    // Cleanup expired waves
    _waves.removeWhere((w) => now.difference(w.createdAt).inMilliseconds > 900);
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

          // 3D Optical Logo Hologram, Starlight, Wire Pulses & Viscous Damped Physics
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _animController,
                builder: (context, _) {
                  // Update smooth damped mouse coordinates with viscous spring inertia
                  if (_rawMousePos != null) {
                    if (_dampedMousePos.dx < -500) {
                      _dampedMousePos = _rawMousePos!;
                      _prevDampedMousePos = _rawMousePos!;
                    } else {
                      _prevDampedMousePos = _dampedMousePos;
                      // Smooth exponential damping (fluid tracking)
                      _dampedMousePos += (_rawMousePos! - _dampedMousePos) * 0.085;
                      _mouseVelocity = _dampedMousePos - _prevDampedMousePos;
                    }
                  }

                  return CustomPaint(
                    painter: _Logo3dParticlePainter(
                      particles: _particles,
                      stars: _stars,
                      waves: _waves,
                      progress: _animController.value,
                      mousePos: _rawMousePos != null ? _dampedMousePos : null,
                      mouseVelocity: _mouseVelocity,
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

class _Star3D {
  final double x;
  final double y;
  final double z;
  final double baseSize;
  final double twinkleSpeed;
  final double phase;
  final bool hasFlare;

  double screenX = 0;
  double screenY = 0;
  double scale = 1;
  double depthZ = 0;

  _Star3D({
    required this.x,
    required this.y,
    required this.z,
    required this.baseSize,
    required this.twinkleSpeed,
    required this.phase,
    required this.hasFlare,
  });
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
  final double pulseSpeed;
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
    required this.pulseSpeed,
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
  final List<_Star3D> stars;
  final List<_RippleWave> waves;
  final double progress;
  final Offset? mousePos;
  final Offset mouseVelocity;
  final bool isDark;
  final Color primaryColor;

  _Logo3dParticlePainter({
    required this.particles,
    required this.stars,
    required this.waves,
    required this.progress,
    required this.mousePos,
    required this.mouseVelocity,
    required this.isDark,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final baseRadius = min(size.width, size.height) * 0.38;

    // 1. Organic Gentle 3D Spatial Precession (Lissajous Space Levitation)
    // Multi-frequency harmonic oscillation mimicking Astra celestial float & DeepSeek oceanic swell
    double parallaxX = 0;
    double parallaxY = 0;
    if (mousePos != null) {
      parallaxX = (mousePos!.dx / size.width - 0.5) * 0.28;
      parallaxY = (mousePos!.dy / size.height - 0.5) * 0.24;
    }

    // Multi-axis rotation (Yaw, Pitch, Roll) with enhanced 3D spatial excursion
    final double rotY = sin(progress * 2 * pi) * 0.38 +
        sin(progress * 2 * pi * 0.35) * 0.12 +
        parallaxX;
    final double rotX = cos(progress * 2 * pi * 0.65) * 0.18 +
        sin(progress * 2 * pi * 0.20) * 0.06 -
        parallaxY;
    final double rotZ = sin(progress * 2 * pi * 0.40) * 0.08; // Majestic slow roll

    // Floating oceanic levitation & breathing scale
    final double floatingY = sin(progress * 2 * pi * 0.75) * 7.0;
    final double breatheScale = 1.0 + sin(progress * 2 * pi * 0.40) * 0.025;

    // Precalculate trigonometric functions
    final double cy = cos(rotY);
    final double sy = sin(rotY);
    final double cx = cos(rotX);
    final double sx = sin(rotX);
    final double cz = cos(rotZ);
    final double sz = sin(rotZ);

    const double cameraZ = 2.6;
    const double fov = 1.95;

    // 2. Project Deep Space Stars & Render Optical Flares
    final starPaint = Paint()..style = PaintingStyle.fill;
    final flarePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;

    for (final s in stars) {
      // Rotation
      final x1 = s.x * cy + s.z * sy;
      final y1 = s.y;
      final z1 = -s.x * sy + s.z * cy;

      final x2 = x1;
      final y2 = y1 * cx - z1 * sx;
      final z2 = y1 * sx + z1 * cx;

      final scale = fov / (cameraZ + z2);
      s.screenX = centerX + x2 * scale * baseRadius * 1.35;
      s.screenY = centerY + (y2 * scale * baseRadius * 1.35) + floatingY * 0.4;
      s.scale = scale;
      s.depthZ = z2;

      // Star twinkle
      final twinkle = (sin(progress * s.twinkleSpeed * 2 * pi + s.phase) + 1.0) / 2.0;
      final starAlpha = (isDark ? 0.45 : 0.25) * twinkle * (scale.clamp(0.4, 1.2));

      starPaint.color = isDark
          ? Colors.white.withValues(alpha: starAlpha)
          : const Color(0xFF00B0FF).withValues(alpha: starAlpha);
      canvas.drawCircle(Offset(s.screenX, s.screenY), s.baseSize * scale * (0.8 + 0.4 * twinkle), starPaint);

      // 4-Point Optical Diffraction Cross Flare for bright stars
      if (s.hasFlare && twinkle > 0.6) {
        final flareProg = (twinkle - 0.6) / 0.4;
        final flareLen = 9.0 * flareProg * scale;
        final flareAlpha = (isDark ? 0.35 : 0.20) * flareProg;
        flarePaint.color = const Color(0xFF00F0FF).withValues(alpha: flareAlpha);

        // Horizontal ray
        canvas.drawLine(
          Offset(s.screenX - flareLen, s.screenY),
          Offset(s.screenX + flareLen, s.screenY),
          flarePaint,
        );
        // Vertical ray
        canvas.drawLine(
          Offset(s.screenX, s.screenY - flareLen),
          Offset(s.screenX, s.screenY + flareLen),
          flarePaint,
        );
      }
    }

    // 3. Physics Update: 3D Spherical Dispersal & 10x Slow-Motion Cosmic Re-aggregation
    final now = DateTime.now();

    for (final p in particles) {
      // 3.1 Shockwave dispersal (3D 全向波纹推散)
      for (final wave in waves) {
        final elapsed = now.difference(wave.createdAt).inMilliseconds;
        if (elapsed < 880) {
          final waveProg = elapsed / 880.0;
          final currentRadius = waveProg * wave.maxRadius;
          final distToCenter = Offset(p.screenX - wave.center.dx, p.screenY - wave.center.dy).distance;
          final waveDelta = (distToCenter - currentRadius).abs();

          if (waveDelta < 50.0 && distToCenter > 1.0) {
            final waveFactor = (1.0 - waveDelta / 50.0) * (1.0 - waveProg) * wave.strength;
            final norm = Offset(
              (p.screenX - wave.center.dx) / distToCenter,
              (p.screenY - wave.center.dy) / distToCenter,
            );
            final zImpulse = (p.curZ >= 0 ? 1.0 : -1.0) * (waveFactor * 0.10);

            // Push outward in full 3D sphere with momentum
            p.vx += norm.dx * waveFactor * 0.08;
            p.vy += norm.dy * waveFactor * 0.08;
            p.vz += zImpulse;
          }
        }
      }

      // 3.2 Damped Mouse Proximity & 3D Viscous Vortex Drag (鼠标阻尼与三维拖曳旋涡)
      if (mousePos != null) {
        final dist = Offset(p.screenX - mousePos!.dx, p.screenY - mousePos!.dy).distance;
        const double mouseRepelDist = 145.0;
        if (dist < mouseRepelDist && dist > 1.0) {
          final repel = (1.0 - dist / mouseRepelDist) * 0.024;
          final norm = Offset((p.screenX - mousePos!.dx) / dist, (p.screenY - mousePos!.dy) / dist);
          final zRepel = (p.curZ >= 0 ? 1.0 : -1.0) * repel * 1.4;

          // 3D Repulsion: pushes outwards and bulges in depth
          p.vx += norm.dx * repel;
          p.vy += norm.dy * repel;
          p.vz += zRepel;

          // Fluid wake drag: particles catch a fraction of the mouse's momentum
          p.vx += mouseVelocity.dx * 0.0014 * (1.0 - dist / mouseRepelDist);
          p.vy += mouseVelocity.dy * 0.0014 * (1.0 - dist / mouseRepelDist);
        }
      }

      // 3.3 10x Slower Deep-Space Cosmic Re-aggregation (慢10倍失重星云微漂移与极其缓慢优雅归位)
      // springK = 0.0016 (literally 10x slower than 0.016)
      // damping = 0.984 allows particles to drift like cosmic dust in zero-g for 12~18 seconds
      const double springK = 0.0016;
      const double damping = 0.984;

      final diffX = p.baseX - p.curX;
      final diffY = p.baseY - p.curY;
      final diffZ = p.baseZ - p.curZ;

      // Subtle celestial micro-turbulence when scattered in space (interstellar plasma effect)
      final dispDist = sqrt(diffX * diffX + diffY * diffY + diffZ * diffZ);
      double microDriftX = 0;
      double microDriftY = 0;
      double microDriftZ = 0;
      if (dispDist > 0.03) {
        final driftAngle = (progress * 2 * pi * 2.5) + p.phase;
        microDriftX = sin(driftAngle) * 0.00015;
        microDriftY = cos(driftAngle * 1.3) * 0.00015;
        microDriftZ = sin(driftAngle * 0.7) * 0.00020;
      }

      p.vx = (p.vx + diffX * springK + microDriftX) * damping;
      p.vy = (p.vy + diffY * springK + microDriftY) * damping;
      p.vz = (p.vz + diffZ * springK + microDriftZ) * damping;

      p.curX += p.vx;
      p.curY += p.vy;
      p.curZ += p.vz;

      // 3.4 3D Full Matrix Rotation (Yaw -> Pitch -> Roll)
      // Y-rotation
      final x1 = p.curX * cy + p.curZ * sy;
      final y1 = p.curY;
      final z1 = -p.curX * sy + p.curZ * cy;

      // X-rotation
      final x2 = x1;
      final y2 = y1 * cx - z1 * sx;
      final z2 = y1 * sx + z1 * cx;

      // Z-rotation (Roll)
      final x3 = x2 * cz - y2 * sz;
      final y3 = x2 * sz + y2 * cz;
      final z3 = z2;

      final scale = (fov / (cameraZ + z3)) * breatheScale;

      p.screenX = centerX + x3 * scale * baseRadius;
      p.screenY = centerY + y3 * scale * baseRadius + floatingY;
      p.scale = scale;
      p.depthZ = z3;
    }

    // 4. Render Dispersal Shockwaves
    for (final wave in waves) {
      final elapsed = now.difference(wave.createdAt).inMilliseconds;
      if (elapsed < 880) {
        final prog = elapsed / 880.0;
        final r = prog * wave.maxRadius;
        final alpha = (1.0 - prog) * (isDark ? 0.32 : 0.20);

        final wavePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (1.0 - prog) * 2.4 + 0.6
          ..shader = RadialGradient(
            colors: [
              const Color(0xFF00F0FF).withValues(alpha: alpha * 0.1),
              const Color(0xFF7C4DFF).withValues(alpha: alpha),
            ],
            stops: const [0.82, 1.0],
          ).createShader(Rect.fromCircle(center: wave.center, radius: r + 1));

        canvas.drawCircle(wave.center, r, wavePaint);
      }
    }

    // 5. Depth Sort for True Volumetric Rendering
    final sortedParticles = List<_Particle3D>.from(particles)
      ..sort((a, b) => b.depthZ.compareTo(a.depthZ));

    // 6. Depth-Aware Synaptic Wire Bundles & Traveling Photon Pulses (3D立体线束脉冲)
    final threadPaint = Paint()..style = PaintingStyle.stroke;
    final pulsePaint = Paint()..style = PaintingStyle.fill;

    const double threadMaxDist = 42.0;

    // Connect along adjacent indices with 3D depth gating (prevents flattening depth)
    for (int i = 0; i < sortedParticles.length; i++) {
      final p1 = sortedParticles[i];
      for (int j = i + 1; j < min(i + 5, sortedParticles.length); j++) {
        final p2 = sortedParticles[j];
        final dist = Offset(p1.screenX - p2.screenX, p1.screenY - p2.screenY).distance;
        final depthDiff = (p1.depthZ - p2.depthZ).abs();

        // ONLY connect if both screen distance AND 3D depth difference are within thresholds
        if (dist < threadMaxDist && depthDiff < 0.36) {
          final factor = (1.0 - (dist / threadMaxDist)) * (1.0 - (depthDiff / 0.36));
          final alpha = factor * (isDark ? 0.22 : 0.14) * p1.scale;

          threadPaint.color = p1.color.withValues(alpha: alpha);
          threadPaint.strokeWidth = 0.7 * factor + 0.3;
          canvas.drawLine(Offset(p1.screenX, p1.screenY), Offset(p2.screenX, p2.screenY), threadPaint);

          // Traveling Synaptic Energy Pulse (沿着光纤线束穿梭的能量光子)
          final pulseProg = ((progress * 6.0 * p1.pulseSpeed) + (p1.phase * 0.3)) % 1.0;
          final pulseX = p1.screenX + (p2.screenX - p1.screenX) * pulseProg;
          final pulseY = p1.screenY + (p2.screenY - p1.screenY) * pulseProg;

          final pulseAlpha = factor * (isDark ? 0.78 : 0.52) * p1.scale;
          pulsePaint.color = isDark
              ? Colors.white.withValues(alpha: pulseAlpha)
              : p1.color.withValues(alpha: pulseAlpha);

          canvas.drawCircle(Offset(pulseX, pulseY), 1.3 * p1.scale, pulsePaint);
        }
      }
    }

    // 7. Volumetric Glowing Particle Nodes with 3D Depth Shading & Specular Glow
    final haloPaint = Paint()..style = PaintingStyle.fill;
    final corePaint = Paint()..style = PaintingStyle.fill;

    for (final p in sortedParticles) {
      final breathe = 0.85 + 0.25 * sin((progress * 2 * pi * 1.5) + p.phase);
      // Depth shading factor: foreground (+Z) is larger, whiter, and brighter; background (-Z) is darker and smaller
      final depthFactor = ((p.depthZ + 1.2) / 2.4).clamp(0.18, 1.0);
      final radius = p.baseRadius * p.scale * breathe * (0.80 + 0.40 * depthFactor);

      // Outer optical glow halo
      final haloAlpha = (isDark ? 0.26 : 0.16) * depthFactor;
      haloPaint.color = p.color.withValues(alpha: haloAlpha);
      canvas.drawCircle(Offset(p.screenX, p.screenY), radius * (2.4 + 1.2 * depthFactor), haloPaint);

      // Core luminous crystal point with 3D specular highlight on front particles
      final isFront = depthFactor > 0.65;
      final coreAlpha = (isDark ? (isFront ? 0.98 : 0.70) : (isFront ? 0.88 : 0.55)) * depthFactor;
      corePaint.color = isDark
          ? (isFront ? Color.lerp(p.color, Colors.white, 0.60)! : p.color.withValues(alpha: coreAlpha))
          : (isFront ? Colors.white.withValues(alpha: coreAlpha) : p.color.withValues(alpha: coreAlpha));
      canvas.drawCircle(Offset(p.screenX, p.screenY), radius, corePaint);
    }

    // 8. Damped Mouse Viscous Aura
    if (mousePos != null) {
      final mouseAura = Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF00F0FF).withValues(alpha: isDark ? 0.09 : 0.05),
            Colors.transparent,
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: mousePos!, radius: 120));
      canvas.drawCircle(mousePos!, 120, mouseAura);
    }
  }

  @override
  bool shouldRepaint(covariant _Logo3dParticlePainter oldDelegate) => true;
}
