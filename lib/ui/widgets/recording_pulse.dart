import 'package:flutter/material.dart';

/// Keep the microphone still when idle, hidden, or reduced motion is requested.
/// Passing the button as [child] also keeps animation ticks out of its subtree.
class RecordingPulse extends StatefulWidget {
  const RecordingPulse({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<RecordingPulse> createState() => _RecordingPulseState();
}

class _RecordingPulseState extends State<RecordingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant RecordingPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    final shouldAnimate =
        widget.active &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) => DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: widget.active && _controller.isAnimating
            ? [
                BoxShadow(
                  color: Theme.of(context).colorScheme.error
                      .withValues(alpha: 0.4 * _controller.value),
                  blurRadius: 8 * _controller.value,
                  spreadRadius: 2 * _controller.value,
                ),
              ]
            : const [],
      ),
      child: child,
    ),
  );
}
