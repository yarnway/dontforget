import 'dart:async';

import 'package:flutter/widgets.dart';

/// Refreshes time-dependent controls without rebuilding the surrounding editor.
class ForegroundTimeBuilder extends StatefulWidget {
  const ForegroundTimeBuilder({
    super.key,
    required this.builder,
    this.boundary,
    this.now = DateTime.now,
  });

  final Widget Function(BuildContext context, DateTime now) builder;
  final DateTime? boundary;
  final DateTime Function() now;

  @override
  State<ForegroundTimeBuilder> createState() => _ForegroundTimeBuilderState();
}

class _ForegroundTimeBuilderState extends State<ForegroundTimeBuilder>
    with WidgetsBindingObserver {
  Timer? _timer;
  late DateTime _now;

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _now = widget.now();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_foreground) return;
    var delay = const Duration(minutes: 1);
    final remaining = widget.boundary?.difference(_now);
    if (remaining != null && remaining > Duration.zero && remaining < delay) {
      delay = remaining;
    }
    _timer = Timer(delay, () {
      if (!mounted || !_foreground) return;
      setState(() => _now = widget.now());
      _schedule();
    });
  }

  @override
  void didUpdateWidget(ForegroundTimeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _now = widget.now();
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _now = widget.now());
      _schedule();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}
