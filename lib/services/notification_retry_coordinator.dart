import 'dart:async';

/// A foreground-only pump. It does not own a timer or a background process.
/// Persisted per-entry cooldown and batch limits are enforced by its worker.
class NotificationRetryCoordinator {
  NotificationRetryCoordinator({required this.run, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Future<void> Function(bool Function() isActive) run;
  final DateTime Function() _now;
  DateTime? _lastAttempt;
  Future<void>? _running;
  bool _foreground = false;
  bool _stopped = false;
  int _generation = 0;

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _generation++;
  }

  Future<void> tick() {
    if (_stopped || !_foreground) return Future.value();
    if (_running != null) return _running!;
    final now = _now();
    final last = _lastAttempt;
    if (last != null &&
        now.difference(last).abs() < const Duration(minutes: 1)) {
      return Future.value();
    }
    _lastAttempt = now;
    final generation = _generation;
    bool active() => !_stopped && _foreground && generation == _generation;
    final operation = Future<void>.sync(() => run(active));
    // Persisted errors remain visible in settings. A timer must not emit an
    // unhandled exception or retry immediately after a failed read.
    _running = operation
        .catchError((Object _) {})
        .whenComplete(() => _running = null);
    return _running!;
  }

  Future<void> stop() async {
    _stopped = true;
    _generation++;
    await _running;
  }
}
