import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

enum VoiceReleaseAction { save, cancel, text, send }

class VoiceCaptureGesture {
  bool _selectionOpen = false;
  VoiceReleaseAction _last = VoiceReleaseAction.save;
  bool get selectionOpen => _selectionOpen;
  void reset() {
    _selectionOpen = false;
    _last = VoiceReleaseAction.save;
  }

  VoiceReleaseAction update(Offset movement) {
    if (movement.dy <= -48) _selectionOpen = true;
    if (movement.dy >= -16) _selectionOpen = false;
    if (!_selectionOpen) return _last = VoiceReleaseAction.save;
    final x = movement.dx;
    // Keep the selected release action stable through small finger tremors.
    if (x >= 96 || (_last == VoiceReleaseAction.send && x >= 80)) {
      return _last = VoiceReleaseAction.send;
    }
    if (x <= -24 || (_last == VoiceReleaseAction.cancel && x <= -12)) {
      return _last = VoiceReleaseAction.cancel;
    }
    if (x >= 24 || (_last == VoiceReleaseAction.text && x >= 12)) {
      return _last = VoiceReleaseAction.text;
    }
    return _last = VoiceReleaseAction.save;
  }
}

/// Visual feedback only: the original held input retains its pointer route.
class VoiceCaptureFeedback extends StatelessWidget {
  const VoiceCaptureFeedback({
    super.key,
    required this.action,
    this.fullScreen = false,
    this.preparing = false,
    this.selectionOpen = false,
    this.transcript = '',
    this.liveTranscription = true,
  });
  final VoiceReleaseAction action;
  final bool fullScreen, preparing, selectionOpen;
  final String transcript;
  final bool liveTranscription;
  static const _green = Color(0xFF3BB47B);
  static const _cancel = Color(0xFFC63C3C);
  static const _neutral = Color(0xFF252525);

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final status = preparing
        ? 'voicePreparing'
        : switch (action) {
            VoiceReleaseAction.save => 'voiceReleaseSave',
            VoiceReleaseAction.cancel => 'voiceReleaseCancel',
            VoiceReleaseAction.text => 'voiceReleaseText',
            VoiceReleaseAction.send => 'voiceReleaseSend',
          };
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: fullScreen
            ? null
            : 280 + math.max(0, scaler.scale(14) - 14) * 5,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final compact = bounds.maxHeight < 440;
            final width = math.min(
              bounds.maxWidth,
              compact ? math.min(640.0, bounds.maxHeight * 1.1) : 640.0,
            );
            final shortLabels = scaler.scale(14) > 20 || width < 280;
            final cancelLabel = loc.get(
              shortLabels ? 'voiceShortCancelTarget' : 'cancel',
            );
            final textLabel = loc.get(switch (action) {
              VoiceReleaseAction.text =>
                shortLabels ? 'voiceEditChoice' : 'voiceEditOnRelease',
              VoiceReleaseAction.send =>
                shortLabels ? 'send' : 'voiceReleaseSend',
              _ => shortLabels ? 'voiceEditChoice' : 'voiceSlideTextTarget',
            });
            final targetStyle = TextStyle(
              fontSize: compact ? 12 : 14,
              fontWeight: FontWeight.w600,
              height: 1.15,
            );
            final labelWidth = width * (compact ? .42 : .4);
            var labelHeight = 0.0;
            // Reserve every action's label height so sliding changes the
            // action without moving the targets or transcript above them.
            for (final value in [
              cancelLabel,
              loc.get(shortLabels ? 'voiceEditChoice' : 'voiceSlideTextTarget'),
              loc.get(shortLabels ? 'voiceEditChoice' : 'voiceEditOnRelease'),
              loc.get(shortLabels ? 'send' : 'voiceReleaseSend'),
            ]) {
              final painter = TextPainter(
                text: TextSpan(text: value, style: targetStyle),
                textDirection: Directionality.of(context),
                textScaler: scaler,
                maxLines: 3,
              )..layout(maxWidth: math.max(1, labelWidth));
              labelHeight = math.max(labelHeight, painter.height);
              painter.dispose();
            }
            final band = math.max(width * .15, labelHeight + 20);
            final geometry = _VoiceSceneGeometry(width, bounds.maxHeight, band);
            final left = (bounds.maxWidth - width) / 2;
            final topInset = fullScreen
                ? MediaQuery.paddingOf(context).top
                : 0.0;
            final bubbleWidth = compact
                ? math.min(120.0, width * .4)
                : width * .408;
            final bubbleHeight = compact ? 46.0 : width * .185;
            const captionStyle = TextStyle(
              fontSize: 15,
              height: 1.35,
              color: Color(0xFFAAAAAA),
              fontWeight: FontWeight.w500,
            );
            final safe = MediaQuery.paddingOf(context);
            final sideInset = math.max(
              24.0,
              math.max(safe.left, safe.right) + 12,
            );
            final feedbackWidth = math.min(
              bounds.maxWidth - sideInset * 2,
              640.0,
            );
            final captionWidth = compact
                ? feedbackWidth - bubbleWidth - 12
                : feedbackWidth;
            // Reserve the same line box for every release state so sliding
            // changes the message without moving the bubble or its targets.
            var captionHeight = 0.0;
            for (final key in [
              'voicePreparing',
              'voiceReleaseSave',
              'voiceReleaseCancel',
              'voiceReleaseText',
              'voiceReleaseSend',
            ]) {
              final painter = TextPainter(
                text: TextSpan(text: loc.get(key), style: captionStyle),
                textDirection: Directionality.of(context),
                textScaler: scaler,
                maxLines: compact ? 1 : 3,
              )..layout(maxWidth: math.max(1, captionWidth));
              captionHeight = math.max(captionHeight, painter.height);
              painter.dispose();
            }
            final bubbleCaptionGap = (width * .04).clamp(12.0, 20.0);
            final feedbackHeight = compact
                ? math.max(bubbleHeight + 8, captionHeight)
                : bubbleHeight + 8 + bubbleCaptionGap + captionHeight;
            final feedbackGap = compact ? 16.0 : 24.0;
            final feedbackTop = math.max(
              topInset + 8,
              geometry.targetsTop - feedbackGap - feedbackHeight,
            );
            final bubbleColor = preparing
                ? const Color(0xFF3C5147)
                : action == VoiceReleaseAction.cancel
                ? _cancel
                : _green;
            final bubble = SizedBox(
              key: const ValueKey('voice-recording-bubble'),
              width: bubbleWidth,
              height: bubbleHeight + 8,
              child: CustomPaint(
                painter: _VoiceBubblePainter(bubbleColor),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Center(
                    child: preparing
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              value: MediaQuery.disableAnimationsOf(context)
                                  ? .7
                                  : null,
                              strokeWidth: 2,
                              color: const Color(0xFFBFD4C9),
                            ),
                          )
                        : SizedBox(
                            width: bubbleWidth * .43,
                            height: math.max(7, width * .014),
                            child: CustomPaint(
                              painter: _VoiceWavePainter(
                                action == VoiceReleaseAction.cancel
                                    ? Colors.white70
                                    : const Color(0xFF1E7850),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            );
            final caption = Semantics(
              liveRegion: true,
              child: SizedBox(
                height: captionHeight,
                child: Center(
                  child: Text(
                    loc.get(status),
                    key: const ValueKey('voice-release-caption'),
                    textAlign: TextAlign.center,
                    maxLines: compact ? 1 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: captionStyle,
                  ),
                ),
              ),
            );
            final duration = MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 120);
            Widget target(bool cancel) {
              final value = cancel
                  ? VoiceReleaseAction.cancel
                  : VoiceReleaseAction.text;
              final selected =
                  action == value ||
                  (!cancel && action == VoiceReleaseAction.send);
              final center = geometry.labelCenter(cancel);
              return Positioned(
                left: left + center.dx - labelWidth / 2,
                top: center.dy - (labelHeight + 4) / 2,
                width: labelWidth,
                height: labelHeight + 4,
                child: Transform.rotate(
                  angle: geometry.labelAngle(cancel),
                  child: Semantics(
                    selected: selected,
                    excludeSemantics: true,
                    label: loc.get(
                      cancel
                          ? 'voiceSlideCancel'
                          : switch (action) {
                              VoiceReleaseAction.text => 'voiceReleaseText',
                              VoiceReleaseAction.send => 'voiceReleaseSend',
                              _ => 'voiceSlideText',
                            },
                    ),
                    child: Container(
                      key: ValueKey('voice-target-${value.name}'),
                      alignment: Alignment.center,
                      child: Text(
                        cancel ? cancelLabel : textLabel,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: targetStyle.copyWith(
                          color: selected && !cancel
                              ? const Color(0xFF103D29)
                              : const Color(0xFFDADADA),
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
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: .76),
                    ),
                  ),
                Positioned(
                  left: left,
                  top: 0,
                  width: width,
                  height: bounds.maxHeight,
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(
                      end: action == VoiceReleaseAction.cancel
                          ? _cancel
                          : _neutral,
                    ),
                    duration: duration,
                    builder: (_, leftFill, _) => TweenAnimationBuilder<Color?>(
                      tween: ColorTween(
                        end:
                            (action == VoiceReleaseAction.text ||
                                action == VoiceReleaseAction.send)
                            ? _green
                            : _neutral,
                      ),
                      duration: duration,
                      builder: (_, rightFill, _) => CustomPaint(
                        painter: _VoiceScenePainter(
                          geometry,
                          leftFill!,
                          rightFill!,
                        ),
                      ),
                    ),
                  ),
                ),
                if (((selectionOpen && action != VoiceReleaseAction.cancel) ||
                        action == VoiceReleaseAction.text ||
                        action == VoiceReleaseAction.send) &&
                    feedbackTop - topInset > 56)
                  Positioned(
                    left: math.max(
                      safe.left + 12,
                      math.max(16, (bounds.maxWidth - 560) / 2),
                    ),
                    right: math.max(
                      safe.right + 12,
                      math.max(16, (bounds.maxWidth - 560) / 2),
                    ),
                    top: math.max(topInset + 8, feedbackTop - 260),
                    bottom: math.max(0, bounds.maxHeight - feedbackTop + 12),
                    child: VoiceTranscriptPreview(
                      key: const ValueKey('voice-transcript-preview'),
                      action: action,
                      transcript: transcript,
                      liveTranscription: liveTranscription,
                    ),
                  ),
                target(true),
                target(false),
                Positioned(
                  key: const ValueKey('voice-recording-feedback'),
                  left: (bounds.maxWidth - feedbackWidth) / 2,
                  width: feedbackWidth,
                  top: feedbackTop,
                  child: compact
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            bubble,
                            const SizedBox(width: 12),
                            Expanded(child: caption),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            bubble,
                            SizedBox(height: bubbleCaptionGap),
                            caption,
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The release choices are indicators: the held input still owns the pointer.
class VoiceTranscriptPreview extends StatelessWidget {
  const VoiceTranscriptPreview({
    super.key,
    required this.action,
    required this.transcript,
    this.liveTranscription = true,
  });
  final VoiceReleaseAction action;
  final String transcript;
  final bool liveTranscription;
  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.primary.withValues(alpha: .65)),
      ),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final compact = bounds.maxHeight < 160;
          Widget choice(bool send) {
            final selected = send
                ? action == VoiceReleaseAction.send
                : action == VoiceReleaseAction.text;
            return Expanded(
              child: Semantics(
                selected: selected,
                excludeSemantics: true,
                label: loc.get(send ? 'voiceReleaseSend' : 'voiceReleaseText'),
                child: Container(
                  key: ValueKey(
                    send
                        ? 'voice-preview-send-mode'
                        : 'voice-preview-edit-mode',
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primary
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    loc.get(send ? 'send' : 'voiceEditChoice'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? colors.onPrimary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.all(compact ? 8 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compact) ...[
                  Row(
                    children: [
                      choice(false),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          size: 18,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      choice(true),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, viewport) => SingleChildScrollView(
                      reverse: true,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: viewport.maxHeight,
                        ),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              transcript.isEmpty
                                  ? loc.get(
                                      liveTranscription
                                          ? 'voiceListeningText'
                                          : 'voiceTranscribeAfterRelease',
                                    )
                                  : transcript,
                              key: const ValueKey('voice-preview-content'),
                              style: TextStyle(
                                fontSize: compact ? 16 : 18,
                                height: 1.45,
                                color: transcript.isEmpty
                                    ? colors.onSurfaceVariant
                                    : colors.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!compact &&
                    bounds.maxHeight >= 220 &&
                    MediaQuery.textScalerOf(context).scale(13) <= 20) ...[
                  const SizedBox(height: 10),
                  Text(
                    loc.get('voiceSendOnRelease'),
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A large circle makes the same shallow arc as the reference. Its two
/// concentric strokes have round inner ends and extend beyond the side edges.
class _VoiceSceneGeometry {
  const _VoiceSceneGeometry(this.width, this.height, this.band);
  final double width, height, band;
  double get radius => width * 1.42;
  double get capTop => height - width * .30;
  Offset get center => Offset(width / 2, capTop + radius);
  double get actionRadius => radius + width * .045 + band / 2;
  double get innerEnd => width * .04 + band / 2;
  double get targetsTop => point(innerEnd).dy - band / 2;
  double angle(double x) =>
      -math.pi / 2 + math.asin((x / actionRadius).clamp(-1.0, 1.0));
  Offset point(double x) => Offset(
    center.dx + x,
    center.dy - math.sqrt(math.max(0, actionRadius * actionRadius - x * x)),
  );
  Offset labelCenter(bool left) => point((left ? -1 : 1) * width * .3);
  double labelAngle(bool left) =>
      math.asin(((left ? -1 : 1) * width * .3 / actionRadius).clamp(-1.0, 1.0));
  Path target(bool left) {
    final outerX = width / 2 + band;
    final start = angle(left ? -outerX : innerEnd);
    final end = angle(left ? -innerEnd : outerX);
    return Path()..addArc(
      Rect.fromCircle(center: center, radius: actionRadius),
      start,
      end - start,
    );
  }
}

class _VoiceScenePainter extends CustomPainter {
  const _VoiceScenePainter(this.geometry, this.leftFill, this.rightFill);
  final _VoiceSceneGeometry geometry;
  final Color leftFill, rightFill;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawCircle(
      geometry.center,
      geometry.radius,
      Paint()
        ..shader =
            const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF606060), Color(0xFF929292)],
            ).createShader(
              Rect.fromLTRB(0, geometry.capTop, size.width, size.height),
            ),
    );
    canvas.drawCircle(
      geometry.center,
      geometry.radius,
      Paint()
        ..color = const Color(0xFF737373)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, geometry.width * .007),
    );
    for (final left in [true, false]) {
      canvas.drawPath(
        geometry.target(left),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = geometry.band
          ..color = left ? leftFill : rightFill,
      );
    }
  }

  @override
  bool shouldRepaint(_VoiceScenePainter old) =>
      geometry.width != old.geometry.width ||
      geometry.height != old.geometry.height ||
      geometry.band != old.geometry.band ||
      leftFill != old.leftFill ||
      rightFill != old.rightFill;
}

class _VoiceBubblePainter extends CustomPainter {
  const _VoiceBubblePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height - 8),
      Radius.circular(size.width * .09),
    );
    canvas.drawRRect(body, Paint()..color = color);
    final tail = Path()
      ..moveTo(size.width / 2 - 8, size.height - 9)
      ..lineTo(size.width / 2 - 2, size.height - 2)
      ..quadraticBezierTo(
        size.width / 2,
        size.height,
        size.width / 2 + 2,
        size.height - 2,
      )
      ..lineTo(size.width / 2 + 8, size.height - 9)
      ..close();
    canvas.drawPath(tail, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_VoiceBubblePainter old) => color != old.color;
}

class _VoiceWavePainter extends CustomPainter {
  const _VoiceWavePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 25; i++) {
      final x = (i + .5) * size.width / 25;
      final amplitude = size.height * (.32 + .12 * math.sin(i * .73).abs());
      canvas.drawLine(
        Offset(x, size.height / 2 - amplitude),
        Offset(x, size.height / 2 + amplitude),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VoiceWavePainter old) => color != old.color;
}
