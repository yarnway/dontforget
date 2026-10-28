import 'dart:collection';

import '../models/notification_payload.dart';
import '../models/reminder.dart';
import 'pending_notification_actions.dart';

/// The host publishes this only after recovery and provider loading finish.
/// Obtaining a snapshot and opening its route must not yield to asynchronous
/// work; otherwise the host must revalidate after that work before navigating.
final class NotificationRouteSnapshot {
  NotificationRouteSnapshot({
    required this.datasetEpoch,
    required Iterable<Reminder> reminders,
  }) : reminders = List.unmodifiable(reminders);

  final String datasetEpoch;
  final List<Reminder> reminders;
}

enum NotificationActionOutcome { applied, repair, rejected }

/// Consumes durable intents only when the host's StorageBootstrap, provider,
/// dataset and runtime gates are ready. Database mutation belongs to the host's
/// existing notifier; native synchronization stays in its journal path.
final class NotificationActionRouteService {
  NotificationActionRouteService({
    required this.readQueue,
    required this.readSnapshot,
    required this.apply,
    this.onResult,
  });

  final Future<PendingNotificationActions?> Function() readQueue;
  final NotificationRouteSnapshot? Function() readSnapshot;
  final Future<NotificationActionOutcome> Function(
    Reminder,
    NotificationActionRequest,
  )
  apply;
  final void Function(NotificationActionOutcome)? onResult;
  bool _ready = false;
  bool _disposed = false;
  Future<void>? _flushing;
  bool _flushAgain = false;
  final LinkedHashSet<String> _handled = LinkedHashSet();

  Future<void> setReady(bool ready) {
    _ready = ready;
    return ready ? flush() : (_flushing ?? Future.value());
  }

  Future<void> flush() {
    if (_disposed || !_ready) return Future.value();
    _flushAgain = true;
    if (_flushing != null) return _flushing!;
    return _flushing = (() async {
      while (_flushAgain && _ready && !_disposed) {
        _flushAgain = false;
        await _consume();
      }
    })().whenComplete(() => _flushing = null);
  }

  Future<void> _consume() async {
    final queue = await readQueue();
    if (queue == null) return;
    while (_ready && !_disposed) {
      final entries = await queue.read();
      if (entries.isEmpty || !_ready || _disposed) return;
      final snapshot = readSnapshot();
      if (snapshot == null) return;
      final request = entries.first;
      Reminder? target;
      if (!_handled.contains(request.identity)) {
        for (final reminder in snapshot.reminders) {
          if (request.payload.matches(
            reminder,
            currentDatasetEpoch: snapshot.datasetEpoch,
          )) {
            target = reminder;
            break;
          }
        }
      }
      var outcome = NotificationActionOutcome.rejected;
      if (target != null &&
          (request.actionId != 'skip_occurrence' || target.isRecurring)) {
        outcome = await apply(target, request);
      }
      // Keep the intent on an exception. Once committed, noticeRevision makes
      // even a crash before remove harmless on the next launch.
      _handled.add(request.identity);
      while (_handled.length > 256) {
        _handled.remove(_handled.first);
      }
      await queue.remove(request.identity);
      if (!_disposed && outcome != NotificationActionOutcome.rejected) {
        onResult?.call(outcome);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _ready = false;
  }
}

enum NotificationRouteDisposition { rejected, duplicate, queued, opened }

/// Holds cold-start clicks until both data and navigation are available.
/// Clicking is navigation only: this service never acknowledges or edits data.
final class NotificationRouteService {
  NotificationRouteService({
    required this.readSnapshot,
    required this.openReminder,
    this.maxPending = 32,
    this.maxRemembered = 256,
  }) {
    if (maxPending < 1 || maxRemembered < maxPending) {
      throw ArgumentError('Notification queue limits are invalid.');
    }
  }

  final NotificationRouteSnapshot? Function() readSnapshot;
  final bool Function(Reminder reminder) openReminder;
  final int maxPending;
  final int maxRemembered;
  final LinkedHashMap<String, NotificationPayload> _pending = LinkedHashMap();
  final LinkedHashSet<String> _handled = LinkedHashSet();
  bool _ready = false;
  bool _flushing = false;
  bool _disposed = false;

  int get pendingCount => _pending.length;

  /// At recovery entry use false with discardPending. At startup, keep queued
  /// clicks while waiting for the database, reminders and Navigator to be ready.
  void setReady(bool ready, {bool discardPending = false}) {
    if (_disposed) return;
    _ready = ready;
    if (discardPending) _pending.clear();
    if (ready) flush();
  }

  NotificationRouteDisposition receive(String? encoded) {
    if (_disposed) return NotificationRouteDisposition.rejected;
    final payload = NotificationPayload.tryParse(encoded);
    if (payload == null) return NotificationRouteDisposition.rejected;
    final key = payload.identity;
    if (_pending.containsKey(key) || _handled.contains(key)) {
      return NotificationRouteDisposition.duplicate;
    }
    if (_pending.length >= maxPending) _pending.remove(_pending.keys.first);
    _pending[key] = payload;
    final opened = flush();
    if (opened.contains(key)) return NotificationRouteDisposition.opened;
    return _pending.containsKey(key)
        ? NotificationRouteDisposition.queued
        : NotificationRouteDisposition.rejected;
  }

  /// The host can retry after mounting navigation or loading provider state.
  /// A temporarily unavailable snapshot leaves the click queued. A definitive
  /// mismatch discards it, so deleted/changed tasks never open another route.
  Set<String> flush() {
    final opened = <String>{};
    if (!_ready || _flushing || _disposed) return opened;
    _flushing = true;
    try {
      while (_ready && !_disposed && _pending.isNotEmpty) {
        final snapshot = readSnapshot();
        if (snapshot == null) break;
        final key = _pending.keys.first;
        final payload = _pending[key]!;
        Reminder? target;
        for (final reminder in snapshot.reminders) {
          if (payload.matches(
            reminder,
            currentDatasetEpoch: snapshot.datasetEpoch,
          )) {
            target = reminder;
            break;
          }
        }
        if (target == null) {
          _pending.remove(key);
          _remember(key);
          continue;
        }
        // Mark first to make a synchronous duplicate callback harmless.
        _remember(key);
        var accepted = false;
        try {
          accepted = openReminder(target);
        } finally {
          if (!accepted) _handled.remove(key);
        }
        if (!accepted) break;
        _pending.remove(key);
        opened.add(key);
      }
    } finally {
      _flushing = false;
    }
    return opened;
  }

  void _remember(String key) {
    _handled.add(key);
    while (_handled.length > maxRemembered) {
      _handled.remove(_handled.first);
    }
  }

  void dispose() {
    _disposed = true;
    _ready = false;
    _pending.clear();
    _handled.clear();
  }
}
