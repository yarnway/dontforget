import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

enum VoiceReleaseAction { save, cancel, text }

class VoiceCaptureGesture {
  bool _selectionOpen = false;

  void reset() => _selectionOpen = false;

  VoiceReleaseAction update(Offset movement) {
    // Slide up to choose, then move horizontally. A small vertical drift while
    // choosing must not unexpectedly save the recording. Returning to the input
    // closes the selection area and restores the normal release-to-save action.
    if (movement.dy <= -48) _selectionOpen = true;
    if (movement.dy >= -16) _selectionOpen = false;
    if (!_selectionOpen || movement.dx.abs() < 24) {
      return VoiceReleaseAction.save;
    }
    return movement.dx < 0
        ? VoiceReleaseAction.cancel
        : VoiceReleaseAction.text;
  }
}

/// The held input keeps ownership of the gesture; these are visual targets.
class VoiceCaptureFeedback extends StatelessWidget {
  const VoiceCaptureFeedback({
    super.key,
    required this.action,
    this.fullScreen = false,
    this.preparing = false,
  });
  final VoiceReleaseAction action;
  final bool fullScreen, preparing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final background = fullScreen
        ? Color.lerp(colors.surfaceContainerHighest, Colors.black, .62)!
        : colors.surfaceContainerHighest;
    final unselected = Color.lerp(
      background,
      fullScreen ? Colors.white : colors.surface,
      .055,
    )!;
    final release = preparing
        ? 'voicePreparing'
        : switch (action) {
            VoiceReleaseAction.save => 'voiceReleaseSave',
            VoiceReleaseAction.cancel => 'voiceReleaseCancel',
            VoiceReleaseAction.text => 'voiceReleaseText',
          };
    final surface = LayoutBuilder(
      builder: (context, bounds) {
        final compact = bounds.maxHeight < 440;
        final bottom = fullScreen ? MediaQuery.paddingOf(context).bottom : 0.0;
        final scaler = MediaQuery.textScalerOf(context);
        final statusStyle = TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: fullScreen ? Colors.white : colors.onSurface,
        );
        final iconWidth = compact
            ? math.min(176.0, bounds.maxWidth * .45)
            : 244.0;
        final messageWidth = math.max(
          1.0,
          bounds.maxWidth - 48 - (compact ? iconWidth + 12 : 0),
        );
        var messageHeight = 0.0;
        // Reserve the same space for every action, so selecting an arc never
        // moves the circle under the held finger, including large text.
        for (final key in [
          'voicePreparing',
          'voiceReleaseSave',
          'voiceReleaseCancel',
          'voiceReleaseText',
        ]) {
          final text = TextPainter(
            text: TextSpan(text: l10n.get(key), style: statusStyle),
            textDirection: Directionality.of(context),
            textScaler: scaler,
            maxLines: 3,
          )..layout(maxWidth: messageWidth);
          messageHeight = math.max(messageHeight, text.height);
          text.dispose();
        }
        final statusHeight = compact
            ? math.max(62.0, messageHeight)
            : 94 + messageHeight;
        final radius = math.min(
          math.min(bounds.maxWidth / 2, 320.0),
          math.max(48.0, bounds.maxHeight - bottom - statusHeight - 36),
        );
        final band = math.min(
          radius * .75,
          math.max(80.0, scaler.scale(14) * 3.4 + 24),
        );
        final geometry = _VoiceArcGeometry(radius, band);
        final left = (bounds.maxWidth - radius * 2) / 2;
        final labelWidth = math.min(radius * .55, band * .85);
        final labelHeight = math.min(band * .8, scaler.scale(14) * 3.8);
        final duration = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 120);
        final leftFill = action == VoiceReleaseAction.cancel
            ? colors.error
            : unselected;
        final rightFill = action == VoiceReleaseAction.text
            ? colors.primary
            : unselected;
        Widget target(VoiceReleaseAction value) {
          final selected = action == value;
          final cancel = value == VoiceReleaseAction.cancel;
          final center = geometry.labelCenter(cancel);
          return Positioned(
            left: left + center.dx - labelWidth / 2,
            bottom: bottom + radius - center.dy - labelHeight / 2,
            width: labelWidth,
            height: labelHeight,
            child: Semantics(
              selected: selected,
              child: Container(
                key: ValueKey('voice-target-${value.name}'),
                alignment: Alignment.center,
                child: Text(
                  l10n.get(cancel ? 'cancel' : 'voiceTextTarget'),
                  semanticsLabel: l10n.get(
                    cancel ? 'voiceSlideCancel' : 'voiceSlideText',
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? (cancel ? colors.onError : colors.onPrimary)
                        : fullScreen
                        ? Colors.white
                        : colors.onSurface,
                  ),
                ),
              ),
            ),
          );
        }

        final selectedColor = action == VoiceReleaseAction.cancel
            ? colors.error
            : colors.primary;
        final icon = Container(
          constraints: BoxConstraints(
            maxWidth: iconWidth,
            minHeight: compact ? 52 : 84,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 16 : 26,
            vertical: 16,
          ),
          decoration: BoxDecoration(
            color: selectedColor,
            borderRadius: BorderRadius.circular(28),
          ),
          child: ExcludeSemantics(
            child: action == VoiceReleaseAction.save
                ? SizedBox(
                    height: 28,
                    width: compact ? math.max(40, iconWidth - 32) : 124,
                    child: CustomPaint(
                      painter: _VoiceWavePainter(colors.onPrimary),
                    ),
                  )
                : Icon(
                    action == VoiceReleaseAction.cancel
                        ? Icons.close_rounded
                        : Icons.text_fields_rounded,
                    size: 30,
                    color: action == VoiceReleaseAction.cancel
                        ? colors.onError
                        : colors.onPrimary,
                  ),
          ),
        );
        final message = Semantics(
          liveRegion: true,
          child: Text(
            l10n.get(release),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: statusStyle,
          ),
        );
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            if (fullScreen)
              Positioned.fill(
                child: ColoredBox(color: Colors.black.withValues(alpha: .76)),
              ),
            Positioned(
              left: left,
              bottom: 0,
              width: radius * 2,
              height: radius + bottom,
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: leftFill),
                duration: duration,
                builder: (context, animatedLeft, _) =>
                    TweenAnimationBuilder<Color?>(
                      tween: ColorTween(end: rightFill),
                      duration: duration,
                      builder: (context, animatedRight, _) => CustomPaint(
                        painter: _VoiceArcPainter(
                          geometry,
                          background,
                          animatedLeft!,
                          animatedRight!,
                          fullScreen ? Colors.white24 : colors.outlineVariant,
                        ),
                      ),
                    ),
              ),
            ),
            target(VoiceReleaseAction.cancel),
            target(VoiceReleaseAction.text),
            Positioned(
              left: 24,
              right: 24,
              bottom: bottom + radius + 24,
              child: compact
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        icon,
                        const SizedBox(width: 12),
                        Expanded(child: message),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [icon, const SizedBox(height: 10), message],
                    ),
            ),
          ],
        );
      },
    );
    return Material(
      type: MaterialType.transparency,
      child: fullScreen ? surface : SizedBox(height: 280, child: surface),
    );
  }
}

/// One circle defines the base, both target bands and both label positions.
/// Target edges are inset concentric arcs, rather than rotated floating pills.
class _VoiceArcGeometry {
  const _VoiceArcGeometry(this.radius, this.band);
  final double radius, band;
  double get outer => math.max(1, radius - 4);
  double get inner => math.max(1, outer - band);
  Offset get center => Offset(radius, radius);
  static const startLeft = -math.pi + .11;
  static const endLeft = -math.pi / 2 - .13;
  Offset point(double r, double angle) =>
      center + Offset(math.cos(angle), math.sin(angle)) * r;
  Offset labelCenter(bool left) {
    final angle = left
        ? (startLeft + endLeft) / 2
        : -math.pi - (startLeft + endLeft) / 2;
    return point((outer + inner) / 2, angle);
  }

  Path target(bool left) {
    final start = left ? startLeft : -math.pi - endLeft;
    final end = left ? endLeft : -math.pi - startLeft;
    final sweep = end - start;
    final corner = math.min(12.0, band / 5);
    const delta = .055;
    final initial = point(outer, start + delta);
    final p = Path()
      ..moveTo(initial.dx, initial.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: outer),
        start + delta,
        sweep - 2 * delta,
        false,
      );
    void curve(Offset control, Offset end) =>
        p.quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
    void line(Offset end) => p.lineTo(end.dx, end.dy);
    curve(point(outer, end), point(outer - corner, end));
    line(point(inner + corner, end));
    curve(point(inner, end), point(inner, end - delta));
    p.arcTo(
      Rect.fromCircle(center: center, radius: inner),
      end - delta,
      -(sweep - 2 * delta),
      false,
    );
    curve(point(inner, start), point(inner + corner, start));
    line(point(outer - corner, start));
    curve(point(outer, start), initial);
    return p..close();
  }
}

class _VoiceArcPainter extends CustomPainter {
  const _VoiceArcPainter(
    this.geometry,
    this.background,
    this.leftFill,
    this.rightFill,
    this.outline,
  );
  final _VoiceArcGeometry geometry;
  final Color background, leftFill, rightFill, outline;
  @override
  void paint(Canvas canvas, Size size) {
    final circle = Rect.fromCircle(
      center: geometry.center,
      radius: geometry.radius,
    );
    final base = Path()
      ..moveTo(0, geometry.radius)
      ..arcTo(circle, math.pi, math.pi, false)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      base,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(background, Colors.white, .045)!, background],
        ).createShader(Offset.zero & size),
    );
    canvas.drawArc(
      circle,
      math.pi,
      math.pi,
      false,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    for (final left in [true, false]) {
      final path = geometry.target(left);
      canvas.drawPath(path, Paint()..color = left ? leftFill : rightFill);
      canvas.drawPath(
        path,
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_VoiceArcPainter old) =>
      geometry.radius != old.geometry.radius ||
      geometry.band != old.geometry.band ||
      background != old.background ||
      leftFill != old.leftFill ||
      rightFill != old.rightFill ||
      outline != old.outline;
}

class _VoiceWavePainter extends CustomPainter {
  const _VoiceWavePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const levels = [
      0.2,
      0.35,
      0.5,
      0.3,
      0.7,
      0.45,
      0.85,
      1.0,
      0.65,
      0.9,
      0.5,
      0.7,
      0.4,
      0.55,
      0.3,
      0.4,
      0.2,
    ];
    for (var i = 0; i < levels.length; i++) {
      final x = (i + .5) * size.width / levels.length;
      final amplitude = size.height * levels[i] / 2;
      canvas.drawLine(
        Offset(x, size.height / 2 - amplitude),
        Offset(x, size.height / 2 + amplitude),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VoiceWavePainter oldDelegate) =>
      oldDelegate.color != color;
}
