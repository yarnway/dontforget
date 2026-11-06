import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Measures the compact editor, independently of focus. Its full-width state
/// uses the same threshold so changing the footer cannot cause resize loops.
class WindowsComposerLayout {
  const WindowsComposerLayout({
    required this.expanded,
    required this.footerBelow,
    required this.iconSend,
    required this.actionsWidth,
    required this.minLines,
    required this.maxLines,
  });

  final bool expanded, footerBelow, iconSend;
  final double actionsWidth;
  final int minLines, maxLines;

  factory WindowsComposerLayout.measure({
    required String text,
    required double width,
    required double availableHeight,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection direction,
    Locale? locale,
    bool showSummary = false,
  }) {
    final scaledFont = textScaler.scale(style.fontSize ?? 15);
    final iconSend = width < 600 || scaledFont > 22;
    // Three 44px targets, send, and toolbar padding. Keep time options in a
    // fixed slot so the first typed character never changes the editor width.
    final actionsWidth = 132.0 + (iconSend ? 48 : 92) + 8;
    final narrow = width < 560 || (scaledFont > 22 && width < 720);
    final compactWidth = math.max(
      1.0,
      width - 24 - (narrow || showSummary ? 0 : actionsWidth),
    );
    // A paste can be very large. Never lay it out twice just to choose a mode.
    var expanded = text.length >= 320;
    if (!expanded && text.isNotEmpty) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        maxLines: 2,
        textDirection: direction,
        textScaler: textScaler,
        locale: locale,
        strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
      );
      try {
        painter.layout(maxWidth: compactWidth);
        expanded = painter.didExceedMaxLines;
      } finally {
        painter.dispose();
      }
    }
    final footerBelow = narrow || showSummary || expanded;
    // Leave the task list usable on short windows, large fonts and OSK insets.
    final budget = (availableHeight * .36).clamp(100.0, 280.0);
    final rows =
        ((budget - 32 - (footerBelow ? 48 : 0)) /
                (scaledFont * (style.height ?? 1.45)))
            .floor()
            .clamp(1, 8);
    return WindowsComposerLayout(
      expanded: expanded,
      footerBelow: footerBelow,
      iconSend: iconSend,
      actionsWidth: actionsWidth,
      minLines: expanded ? math.min(3, rows) : 1,
      maxLines: expanded ? rows : math.min(2, rows),
    );
  }
}
