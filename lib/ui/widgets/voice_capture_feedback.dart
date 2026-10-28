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

/// The original input surface keeps its existing hold/slide/release sequence.
/// The containing overlay absorbs new touches while an arc is being selected.
class VoiceCaptureFeedback extends StatelessWidget {
  const VoiceCaptureFeedback({
    super.key,
    required this.action,
    this.fullScreen = false,
    this.preparing = false,
  });
  final VoiceReleaseAction action;
  final bool fullScreen;
  final bool preparing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final arcSurface = fullScreen
        ? Color.lerp(colors.surfaceContainerHighest, Colors.black, .62)!
        : colors.surfaceContainerHighest;
    final selectedColor = action == VoiceReleaseAction.cancel
        ? colors.error
        : colors.primary;
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
        final targetBottom = bottom + (compact ? 42.0 : 100.0);
        final bubbleBottom = bottom + (compact ? 176.0 : 260.0);
        Widget target(VoiceReleaseAction value, bool left) {
          final selected = action == value;
          final tint = value == VoiceReleaseAction.cancel
              ? colors.error
              : colors.primary;
          return Expanded(
            child: Transform.rotate(
              angle: left ? -0.13 : 0.13,
              child: AnimatedContainer(
                key: ValueKey('voice-target-${value.name}'),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 120),
                constraints: BoxConstraints(minHeight: compact ? 72 : 88),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: selected ? tint : arcSurface,
                  borderRadius: BorderRadius.circular(52),
                  border: Border.all(
                    color: selected
                        ? tint
                        : fullScreen
                        ? Colors.white24
                        : colors.outlineVariant,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: tint.withValues(alpha: .22),
                            blurRadius: 20,
                          ),
                        ]
                      : null,
                ),
                // Keep the label level while the two surfaces follow the arc.
                child: Transform.rotate(
                  angle: left ? 0.13 : -0.13,
                  child: Text(
                    l10n.get(left ? 'cancel' : 'voiceTextTarget'),
                    semanticsLabel: l10n.get(
                      left ? 'voiceSlideCancel' : 'voiceSlideText',
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? (left ? colors.onError : colors.onPrimary)
                          : fullScreen
                          ? Colors.white
                          : colors.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            if (fullScreen)
              Positioned.fill(
                child: ColoredBox(color: Colors.black.withValues(alpha: .76)),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: bottom + (compact ? 82 : 140),
              child: CustomPaint(
                painter: _VoiceArcPainter(
                  arcSurface,
                  fullScreen ? Colors.white12 : colors.outlineVariant,
                ),
              ),
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: targetBottom,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        target(VoiceReleaseAction.cancel, true),
                        const SizedBox(width: 24),
                        target(VoiceReleaseAction.text, false),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: bubbleBottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    constraints: BoxConstraints(
                      maxWidth: 244,
                      minHeight: compact ? 52 : 84,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 26,
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
                              width: 124,
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
                  ),
                  const SizedBox(height: 10),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.get(release),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: fullScreen ? Colors.white : colors.onSurface,
                      ),
                    ),
                  ),
                ],
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

class _VoiceArcPainter extends CustomPainter {
  const _VoiceArcPainter(this.color, this.outline);
  final Color color, outline;
  @override
  void paint(Canvas canvas, Size size) {
    final curve = Path()
      ..moveTo(-size.width * .06, size.height * .78)
      ..cubicTo(
        size.width * .16,
        size.height * .03,
        size.width * .84,
        size.height * .03,
        size.width * 1.06,
        size.height * .78,
      );
    final path = Path.from(curve)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(color, Colors.white, .06)!, color],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      curve,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_VoiceArcPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.outline != outline;
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
