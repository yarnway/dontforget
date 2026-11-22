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
    this.onAccessibleAction,
  });
  final VoiceReleaseAction action;
  final bool fullScreen, preparing, selectionOpen;
  final String transcript;
  final bool liveTranscription;
  final ValueChanged<VoiceReleaseAction>? onAccessibleAction;
  static const _green = VoiceCaptureColors.bubble;
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
            final captionStyle = TextStyle(
              fontSize: 15,
              height: 1.35,
              color: fullScreen
                  ? const Color(0xFFD0D0D0)
                  : Theme.of(context).colorScheme.onSurfaceVariant,
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
            final extraFeedbackGap = math.min(
              width * .35,
              math.max(0.0, (bounds.maxHeight - 640) * .6),
            );
            final feedbackGap = compact ? 16.0 : 24.0 + extraFeedbackGap;
            final feedbackTop = math.max(
              topInset + 8,
              geometry.targetsTop - feedbackGap - feedbackHeight,
            );
            final showTranscript =
                ((selectionOpen && action != VoiceReleaseAction.cancel) ||
                    action == VoiceReleaseAction.text ||
                    action == VoiceReleaseAction.send) &&
                feedbackTop - topInset > 56;
            final previewWidth = math.min(
              bounds.maxWidth -
                  math.max(safe.left, 24) -
                  math.max(safe.right, 24),
              560.0,
            );
            final textMeasure = TextPainter(
              text: TextSpan(
                text: transcript.isEmpty
                    ? loc.get(
                        liveTranscription
                            ? 'voiceListeningText'
                            : 'voiceTranscribeAfterRelease',
                      )
                    : transcript,
                style: const TextStyle(fontSize: 20, height: 1.45),
              ),
              textDirection: Directionality.of(context),
              textScaler: scaler,
              maxLines: 6,
            )..layout(maxWidth: math.max(1, previewWidth - 40));
            final desiredPreviewHeight = (textMeasure.height + 64).clamp(
              104.0,
              260.0,
            );
            textMeasure.dispose();
            final previewBottom = compact
                ? feedbackTop - 12
                : feedbackTop + bubbleHeight + 8;
            final previewTop = math.max(
              topInset + 8,
              previewBottom - desiredPreviewHeight,
            );
            final bubbleColor = preparing
                ? const Color(0xFF3C5147)
                : action == VoiceReleaseAction.cancel
                ? _cancel
                : _green;
            final bubble = RepaintBoundary(
              child: SizedBox(
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
                                semanticsLabel: loc.get('voicePreparing'),
                                value: MediaQuery.disableAnimationsOf(context)
                                    ? .7
                                    : null,
                                strokeWidth: 2,
                                color: const Color(0xFFBFD4C9),
                              ),
                            )
                          : SizedBox(
                              width: bubbleWidth * .43,
                              height: math.max(10, width * .026),
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
              ),
            );
            final caption = Semantics(
              container: true,
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
                            ? const Color(0xFFE0E0E0)
                            : _neutral,
                      ),
                      duration: duration,
                      builder: (_, rightFill, _) => RepaintBoundary(
                        child: CustomPaint(
                          painter: _VoiceScenePainter(
                            geometry,
                            leftFill!,
                            rightFill!,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (showTranscript)
                  Positioned(
                    left: (bounds.maxWidth - previewWidth) / 2,
                    width: previewWidth,
                    top: previewTop,
                    height: previewBottom - previewTop,
                    child: VoiceTranscriptPreview(
                      key: const ValueKey('voice-transcript-preview'),
                      transcript: transcript,
                      liveTranscription: liveTranscription,
                    ),
                  ),
                if (onAccessibleAction == null) ...[
                  target(true),
                  target(false),
                ],
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
                            if (showTranscript)
                              SizedBox(height: bubbleHeight + 8)
                            else
                              bubble,
                            SizedBox(height: bubbleCaptionGap),
                            caption,
                          ],
                        ),
                ),
                if (onAccessibleAction != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: math.max(24.0, safe.bottom + 16),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Wrap(
                          key: const ValueKey('voice-accessible-actions'),
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            FilledButton.icon(
                              key: const ValueKey('voice-accessible-save'),
                              autofocus: true,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                backgroundColor: VoiceCaptureColors.bubble,
                                foregroundColor: VoiceCaptureColors.ink,
                              ),
                              onPressed: () =>
                                  onAccessibleAction!(VoiceReleaseAction.save),
                              icon: const Icon(Icons.check_rounded),
                              label: Text(loc.get('voiceAccessibleSave')),
                            ),
                            FilledButton.tonalIcon(
                              key: const ValueKey('voice-accessible-text'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                backgroundColor: const Color(0xFFE0E0E0),
                                foregroundColor: const Color(0xFF171717),
                              ),
                              onPressed: () =>
                                  onAccessibleAction!(VoiceReleaseAction.text),
                              icon: const Icon(Icons.edit_note_rounded),
                              label: Text(loc.get('voiceAccessibleEditText')),
                            ),
                            OutlinedButton.icon(
                              key: const ValueKey('voice-accessible-cancel'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                backgroundColor: const Color(0xFF2B2B2B),
                                foregroundColor: Colors.white,
                                side: const BorderSide(
                                  color: Color(0xFF666666),
                                ),
                              ),
                              onPressed: () => onAccessibleAction!(
                                VoiceReleaseAction.cancel,
                              ),
                              icon: const Icon(Icons.close_rounded),
                              label: Text(loc.get('cancel')),
                            ),
                          ],
                        ),
                      ),
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

/// Shared capture surfaces keep the live transcript and editor visually linked.
abstract final class VoiceCaptureColors {
  static const bubble = Color(0xFF61B77F);
  static const ink = Color(0xFF102C1B);
  static const secondaryInk = Color(0xFF19462A);
}

class VoiceTextBubble extends StatelessWidget {
  const VoiceTextBubble({
    super.key,
    required this.child,
    this.tailAlignment = .86,
  });
  final Widget child;
  final double tailAlignment;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('voice-text-bubble'),
    painter: _VoiceBubblePainter(
      VoiceCaptureColors.bubble,
      tailAlignment: tailAlignment,
    ),
    child: Padding(padding: const EdgeInsets.only(bottom: 8), child: child),
  );
}

/// Preview only: the held input retains ownership of the gesture and pointer.
class VoiceTranscriptPreview extends StatelessWidget {
  const VoiceTranscriptPreview({
    super.key,
    required this.transcript,
    this.liveTranscription = true,
  });
  final String transcript;
  final bool liveTranscription;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, bounds) {
        final compact = bounds.maxHeight < 100;
        return VoiceTextBubble(
          child: Padding(
            padding: compact
                ? const EdgeInsets.all(4)
                : const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                                fontSize: compact ? 16 : 20,
                                height: compact ? 1.2 : 1.45,
                                color: transcript.isEmpty
                                    ? VoiceCaptureColors.secondaryInk
                                    : VoiceCaptureColors.ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!compact) const SizedBox(height: 8),
                if (!compact)
                  const Align(
                    alignment: Alignment.centerRight,
                    child: ExcludeSemantics(
                      child: SizedBox(
                        width: 32,
                        height: 12,
                        child: CustomPaint(
                          painter: _VoiceWavePainter(
                            VoiceCaptureColors.secondaryInk,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: rightFill.computeLuminance() > .3
                  ? const [Color(0xFF151515), Color(0xFF202020)]
                  : const [Color(0xFF606060), Color(0xFF929292)],
            ).createShader(
              Rect.fromLTRB(0, geometry.capTop, size.width, size.height),
            ),
    );
    canvas.drawCircle(
      geometry.center,
      geometry.radius,
      Paint()
        ..color = rightFill.computeLuminance() > .3
            ? const Color(0xFF2C2C2C)
            : const Color(0xFF737373)
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
  const _VoiceBubblePainter(this.color, {this.tailAlignment = .5});
  final Color color;
  final double tailAlignment;
  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height - 8),
      Radius.circular(math.min(20, size.width * .09)),
    );
    canvas.drawRRect(body, Paint()..color = color);
    final tailX = (size.width * tailAlignment).clamp(16.0, size.width - 16);
    final tail = Path()
      ..moveTo(tailX - 8, size.height - 9)
      ..lineTo(tailX - 2, size.height - 2)
      ..quadraticBezierTo(tailX, size.height, tailX + 2, size.height - 2)
      ..lineTo(tailX + 8, size.height - 9)
      ..close();
    canvas.drawPath(tail, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_VoiceBubblePainter old) =>
      color != old.color || tailAlignment != old.tailAlignment;
}

class _VoiceWavePainter extends CustomPainter {
  const _VoiceWavePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = (size.width / 40).clamp(.7, 2.0)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 25; i++) {
      final x = (i + .5) * size.width / 25;
      final amplitude =
          size.height * (.12 + .34 * math.pow(math.sin(math.pi * i / 24), 2));
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
