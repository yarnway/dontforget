import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notification_payload.dart';
import '../models/reminder.dart';

enum LiveReminderAvailability { available, disabled, unsupported, unavailable }

class LiveReminderStatus {
  const LiveReminderStatus(this.availability, {this.payload});
  final LiveReminderAvailability availability;
  final String? payload;
}

abstract interface class LiveReminderBackend {
  Future<LiveReminderStatus> read();
  Future<void> start(Map<String, Object> content);
  Future<void> synchronize(Map<String, Object>? content);
  Future<void> end();
}

class ChannelLiveReminderBackend implements LiveReminderBackend {
  static const channel = MethodChannel('dontforget/live_reminder');
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<LiveReminderStatus> read() async {
    if (!supported) {
      return const LiveReminderStatus(LiveReminderAvailability.unsupported);
    }
    final value = await channel.invokeMapMethod<String, dynamic>('status');
    return LiveReminderStatus(switch (value?['availability']) {
      'available' => LiveReminderAvailability.available,
      'disabled' => LiveReminderAvailability.disabled,
      'unsupported' => LiveReminderAvailability.unsupported,
      _ => LiveReminderAvailability.unavailable,
    }, payload: value?['payload'] as String?);
  }

  @override
  Future<void> start(Map<String, Object> content) =>
      channel.invokeMethod('start', content);
  @override
  Future<void> synchronize(Map<String, Object>? content) async {
    if (supported) await channel.invokeMethod<void>('synchronize', content);
  }

  @override
  Future<void> end() async {
    if (supported) await channel.invokeMethod<void>('end');
  }
}

final liveReminderServiceProvider = ChangeNotifierProvider<LiveReminderService>(
  (ref) {
    final service = LiveReminderService(ChannelLiveReminderBackend());
    return service;
  },
);

/// Explicitly selected, local-only Live Activity. It never schedules a system
/// notification or mutates a task. Operations serialize so recovery/stop wins
/// over an earlier in-flight start, and an old dataset cannot restart itself.
class LiveReminderService extends ChangeNotifier {
  LiveReminderService(this.backend, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final LiveReminderBackend backend;
  final DateTime Function() now;
  LiveReminderStatus status = const LiveReminderStatus(
    LiveReminderAvailability.unavailable,
  );
  Future<void> _operations = Future.value();
  int _generation = 0;
  bool _disposed = false;
  Timer? _expiry;

  static bool eligible(Reminder reminder, DateTime now) {
    final time = reminder.triggerTime;
    return time != null &&
        !reminder.isCompleted &&
        reminder.noticeAcknowledgedAt == null &&
        time.isAfter(now) &&
        time.difference(now) <= const Duration(hours: 8);
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  void _publish(LiveReminderStatus value) {
    if (_disposed) return;
    status = value;
    notifyListeners();
  }

  Future<void> refresh() => _enqueue(() async {
    if (_disposed) return;
    try {
      _publish(await backend.read());
    } catch (_) {
      _publish(const LiveReminderStatus(LiveReminderAvailability.unavailable));
    }
  });

  Map<String, Object> _content(
    Reminder reminder,
    String epoch,
    String language,
  ) => {
    'payload': NotificationPayload.forReminder(
      reminder,
      datasetEpoch: epoch,
    ).encode(),
    'title': String.fromCharCodes(reminder.taskTitle.runes.take(120)),
    'endTime': reminder.triggerTime!.millisecondsSinceEpoch / 1000,
    'language': ['zh', 'ja'].contains(language) ? language : 'en',
  };

  Future<void> start(Reminder reminder, String epoch, String language) {
    _expiry?.cancel();
    final generation = _generation;
    return _enqueue(() async {
      if (_disposed || generation != _generation) return;
      final observed = await backend.read();
      if (_disposed || generation != _generation) return;
      _publish(observed);
      if (observed.availability != LiveReminderAvailability.available ||
          !eligible(reminder, now())) {
        throw StateError('Live reminder is unavailable for this occurrence.');
      }
      await backend.start(_content(reminder, epoch, language));
      if (_disposed || generation != _generation) return;
      _publish(await backend.read());
      _scheduleExpiry(reminder.triggerTime!);
    });
  }

  /// Call only after data loading succeeds, and again after a foreground resume.
  /// The current selection survives process restarts through ActivityKit, not
  /// through a second task database or a backup-sensitive preference.
  Future<void> synchronize(
    List<Reminder> reminders,
    String epoch,
    String language,
  ) {
    final generation = _generation;
    return _enqueue(() async {
      if (_disposed || generation != _generation) return;
      final observed = await backend.read();
      if (_disposed || generation != _generation) return;
      final selected = NotificationPayload.tryParse(observed.payload);
      if (selected == null ||
          observed.availability != LiveReminderAvailability.available) {
        _expiry?.cancel();
        // A corrupt or permission-disabled native selection cannot be kept
        // alive: it has no trustworthy current occurrence to navigate to.
        if (observed.payload != null) {
          await backend.end();
          if (_disposed || generation != _generation) return;
          _publish(await backend.read());
        } else {
          _publish(observed);
        }
        return;
      }
      Reminder? current;
      if (selected.datasetEpoch == epoch) {
        for (final reminder in reminders) {
          if (!eligible(reminder, now())) continue;
          final payload = NotificationPayload.forReminder(
            reminder,
            datasetEpoch: epoch,
          );
          if (payload.reminderKey == selected.reminderKey) {
            current = reminder;
            break;
          }
        }
      }
      await backend.synchronize(
        current == null ? null : _content(current, epoch, language),
      );
      if (_disposed || generation != _generation) return;
      _publish(await backend.read());
      _expiry?.cancel();
      if (current != null) _scheduleExpiry(current.triggerTime!);
    });
  }

  void _scheduleExpiry(DateTime time) {
    _expiry?.cancel();
    final remaining = time.difference(now());
    _expiry = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      unawaited(stop().catchError((Object _) {}));
    });
  }

  /// Invalidate synchronously before queuing native cleanup. Call at recovery
  /// entry as well as for an explicit user stop.
  Future<void> stop() {
    _generation++;
    _expiry?.cancel();
    return _enqueue(() async {
      await backend.end();
      if (!_disposed) _publish(await backend.read());
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _expiry?.cancel();
    super.dispose();
  }
}
