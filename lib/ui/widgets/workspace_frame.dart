import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// Gives the workspace a consistent width while the window is resized.
class WorkspaceFrame extends StatelessWidget {
  const WorkspaceFrame({super.key, required this.child});

  final Widget child;

  static double widthFor(double availableWidth) {
    const compactWidth = AppTheme.workspaceMaxWidth;
    if (availableWidth <= compactWidth) return availableWidth;
    // Use most of the extra space while keeping wide single-column views readable.
    return math.min(
      1920.0,
      compactWidth + (availableWidth - compactWidth) * .75,
    );
  }

  static double widthLimitOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WorkspaceWidth>()?.value ??
      AppTheme.workspaceMaxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = widthFor(constraints.maxWidth);
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: _WorkspaceWidth(value: width, child: child),
      );
    },
  );
}

class _WorkspaceWidth extends InheritedWidget {
  const _WorkspaceWidth({required this.value, required super.child});

  final double value;

  @override
  bool updateShouldNotify(_WorkspaceWidth oldWidget) =>
      value != oldWidget.value;
}
