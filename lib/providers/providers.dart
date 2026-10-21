import 'dart:async';
import '../services/recovery/runtime_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database_helper.dart';
import '../models/settings.dart';
import '../models/reminder.dart';
import '../models/media_record.dart';
import '../services/llm_service.dart';
import '../services/notification_service.dart';
import '../services/lan_sync_service.dart';
import '../services/dp_scheduler_service.dart';
import '../services/multi_agent_service.dart';
import '../services/spaced_repetition_service.dart';
import '../services/data_export_service.dart';
import '../services/dynamic_urgency_service.dart';
import '../services/bidirectional_link_service.dart';
import '../services/context_trigger_service.dart';

final databaseHelperProvider = Provider<DatabaseHelper>((ref) {
  return DatabaseHelper.instance;
});

final runtimeRecoveryGateProvider = Provider<RuntimeRecoveryGate>((ref) {
  return RuntimeRecoveryGate();
});

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((
  ref,
) {
  return SettingsNotifier(ref.read(databaseHelperProvider));
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  final DatabaseHelper _dbHelper;
  late final Future<void> ready;
  DataGeneration? _stateGeneration;

  SettingsNotifier(this._dbHelper) : super(AppSettings.defaults()) {
    ready = _loadSettings();
    // A consumer may await ready later; still observe an early startup failure.
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<void> _loadSettings() async {
    final generation = _dbHelper.captureGeneration();
    final rows = await _dbHelper.read(
      generation,
      (db) => db.query('Settings', where: 'id = ?', whereArgs: ['default']),
    );
    _dbHelper.checkGeneration(generation);
    _stateGeneration = generation;
    if (rows.isNotEmpty && mounted) {
      state = AppSettings.fromJson(rows.first);
    }
  }

  Future<void> updateSettings(AppSettings newSettings) async {
    // Capture before waiting for startup: maintenance must not retarget a save.
    final generation = _dbHelper.captureGeneration();
    if (_stateGeneration != null) {
      _dbHelper.checkGeneration(_stateGeneration!);
    }
    await ready;
    _dbHelper.checkGeneration(generation);
    _dbHelper.checkGeneration(_stateGeneration!);
    final saved = newSettings.copyWith();
    await _dbHelper.writeTransaction(generation, (txn) async {
      await txn.delete('Settings', where: 'id = ?', whereArgs: ['default']);
      await txn.insert('Settings', {...saved.toJson(), 'id': 'default'});
    });
    _dbHelper.checkGeneration(generation);
    if (mounted) {
      state = AppSettings.fromJson({...saved.toJson(), 'id': 'default'});
    }
  }
}

final remindersProvider =
    StateNotifierProvider<RemindersNotifier, List<Reminder>>((ref) {
      return RemindersNotifier(
        ref.read(databaseHelperProvider),
        notifications: ref.read(notificationServiceProvider),
        runLoadEffects: !ref.read(runtimeRecoveryGateProvider).paused,
      );
    });

enum ReminderNoticePhase { upcoming, due }

enum ReminderActionDisposition { applied, alreadyApplied, stale }

class ReminderActionResult {
  const ReminderActionResult(
    this.disposition, {
    this.reminder,
    this.nativeSyncFailed = false,
  });

  final ReminderActionDisposition disposition;
  final Reminder? reminder;
  final bool nativeSyncFailed;
  bool get accepted => disposition != ReminderActionDisposition.stale;
}

class ReminderBatchResult {
  const ReminderBatchResult({this.changed = 0, this.nativeSyncFailures = 0});
  final int changed;
  final int nativeSyncFailures;
}

class StaleReminderOccurrenceException implements Exception {
  const StaleReminderOccurrenceException();
}

enum _ReminderAction { acknowledgeUpcoming, acknowledgeDue, snooze, complete }

class RemindersNotifier extends StateNotifier<List<Reminder>> {
  final DatabaseHelper _dbHelper;
  final NotificationService _notifications;
  late final Future<void> ready;
  Future<void> _operations = Future<void>.value();
  DataGeneration? _stateGeneration;
  final Set<String> _pendingNotificationRetries = {};
  final Set<String> _pendingNotificationCancellations = {};

  RemindersNotifier(
    this._dbHelper, {
    NotificationService? notifications,
    bool runLoadEffects = true,
  }) : _notifications =
           notifications ?? NotificationService.forDatabase(_dbHelper),
       super([]) {
    ready = _enqueue(
      (generation) =>
          _loadReminders(generation, startup: true, runEffects: runLoadEffects),
      requiresCurrentState: false,
    );
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  // Capture at enqueue time, not when an older queued operation completes.
  // Failed operations reach their caller without poisoning subsequent work.
  Future<T> _enqueue<T>(
    Future<T> Function(DataGeneration generation) operation, {
    DataGeneration? generation,
    bool requiresCurrentState = true,
  }) async {
    final ticket = generation ?? _dbHelper.captureGeneration();
    _dbHelper.checkGeneration(ticket);
    if (requiresCurrentState && _stateGeneration != null) {
      _dbHelper.checkGeneration(_stateGeneration!);
    }
    final result = _operations.then((_) {
      _dbHelper.checkGeneration(ticket);
      if (requiresCurrentState) {
        final stateGeneration = _stateGeneration;
        if (stateGeneration == null) {
          throw const DatabaseAccessException(
            DatabaseAccessError.staleGeneration,
          );
        }
        _dbHelper.checkGeneration(stateGeneration);
      }
      return operation(ticket);
    });
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _loadReminders(
    DataGeneration generation, {
    bool startup = false,
    bool runEffects = true,
  }) async {
    try {
      final rows = await _dbHelper.read(
        generation,
        (db) => db.query('Reminders'),
      );
      _dbHelper.checkGeneration(generation);
      if (!mounted) {
        return;
      }
      final list = rows.map(Reminder.fromJson).toList();
      final previousGeneration = _stateGeneration;
      if (previousGeneration != null &&
          !_dbHelper.isCurrent(previousGeneration)) {
        _pendingNotificationRetries.clear();
        _pendingNotificationCancellations.clear();
      }
      _stateGeneration = generation;
      state = list;
      // Recovery already rebuilt notifications from the committed database.
      // Loading UI state must not reschedule or mutate it a second time.
      if (!runEffects) return;
      // Promote before scheduling so startup uses the final saved priority.
      await _applyDynamicUrgency(generation, synchronize: false);
      final now = DateTime.now();
      for (final reminder in state) {
        _dbHelper.checkGeneration(generation);
        if (!mounted) {
          return;
        }
        if (reminder.isCompleted ||
            reminder.noticeAcknowledgedAt != null ||
            reminder.triggerTime == null) {
          await _dbHelper.runOperation(generation, () async {
            _dbHelper.checkGeneration(generation);
            await _synchronizeReminder(reminder, generation);
          });
        } else if (!reminder.isCompleted &&
            reminder.triggerTime != null &&
            reminder.triggerTime!.isAfter(now)) {
          await _dbHelper.runOperation(generation, () async {
            _dbHelper.checkGeneration(generation);
            await _synchronizeReminder(reminder, generation);
          });
        }
      }
    } catch (error, stack) {
      // Generation/maintenance failures must reach startup and mutation callers.
      _dbHelper.checkGeneration(generation);
      if (startup) {
        rethrow;
      }
      if (mounted) {
        debugPrint('Warning: Reminders load error: $error\n$stack');
      }
    }
  }

  Future<ReminderActionResult> addReminder(Reminder reminder) async {
    final generation = _dbHelper.captureGeneration();
    return addReminderForGeneration(reminder, generation);
  }

  /// Explicitly reconcile saved occurrences after permission or native errors.
  /// This does not edit tasks, acknowledge past occurrences, or request access.
  Future<({int attempted, int failed})> retryNotificationDelivery({
    DateTime? now,
  }) => _enqueue(
    (generation) => _dbHelper.runOperation(generation, () async {
      void checkCurrent() {
        _dbHelper.checkGeneration(generation);
        if (!mounted) throw StateError('Reminder state is no longer active.');
        if (_notifications.isPausedForMaintenance) {
          throw StateError('Notification recovery is in progress.');
        }
      }

      checkCurrent();
      final rows = await _dbHelper.read(
        generation,
        (db) => db.query('Reminders'),
      );
      checkCurrent();
      var attempted = 0;
      var failed = 0;
      final existingIds = <String>{};
      for (final row in rows) {
        checkCurrent();
        final reminder = Reminder.fromJson(row);
        existingIds.add(reminder.id);
        final cancel =
            reminder.isCompleted ||
            reminder.noticeAcknowledgedAt != null ||
            reminder.triggerTime == null ||
            (!reminder.triggerTime!.isAfter(now ?? DateTime.now()) &&
                _pendingNotificationCancellations.contains(reminder.id));
        // Existing overdue notices remain available. Retrying must not replay
        // them, erase their delivered banner, or persist an acknowledgement.
        if (!cancel && !reminder.triggerTime!.isAfter(now ?? DateTime.now())) {
          continue;
        }
        attempted++;
        try {
          if (cancel) {
            await _notifications.cancelReminderStrict(reminder.id);
          } else {
            await _notifications.scheduleReminderStrict(reminder);
          }
          _pendingNotificationRetries.remove(reminder.id);
          _pendingNotificationCancellations.remove(reminder.id);
        } catch (_) {
          _pendingNotificationRetries.add(reminder.id);
          if (cancel) _pendingNotificationCancellations.add(reminder.id);
          failed++;
        }
        // Recovery/disposal is not a native failure to collect and continue.
        checkCurrent();
      }
      // A failed cancellation can outlive the saved row in this session.
      // Retain that ID until cancellation succeeds; do not recreate the task.
      for (final id in _pendingNotificationRetries.difference(existingIds)) {
        checkCurrent();
        attempted++;
        try {
          await _notifications.cancelReminderStrict(id);
          _pendingNotificationRetries.remove(id);
          _pendingNotificationCancellations.remove(id);
        } catch (_) {
          failed++;
        }
        checkCurrent();
      }
      return (attempted: attempted, failed: failed);
    }),
  );

  Future<ReminderActionResult> addReminderForGeneration(
    Reminder reminder,
    DataGeneration generation,
  ) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      if (!mounted) {
        throw StateError('Reminder state is no longer active.');
      }
      Reminder toAdd = reminder;
      final replacements = <String, Reminder>{};
      if (toAdd.linkedTaskIds.isEmpty && state.isNotEmpty) {
        final suggestedIds = const BiDirectionalLinkService()
            .findSuggestedLinkedIds(toAdd, state);
        if (suggestedIds.isNotEmpty) {
          toAdd = toAdd.copyWith(linkedTaskIds: suggestedIds);
          for (final other in state) {
            if (suggestedIds.contains(other.id) &&
                !other.linkedTaskIds.contains(toAdd.id)) {
              replacements[other.id] = other.copyWith(
                linkedTaskIds: [...other.linkedTaskIds, toAdd.id],
              );
            }
          }
        }
      }
      await _dbHelper.writeTransaction(ticket, (txn) async {
        await txn.insert('Reminders', toAdd.toJson());
        for (final other in replacements.values) {
          await txn.update(
            'Reminders',
            {'linked_task_ids': other.toJson()['linked_task_ids']},
            where: 'id = ?',
            whereArgs: [other.id],
          );
        }
      });
      _dbHelper.checkGeneration(ticket);
      if (mounted) {
        state = [
          for (final item in state) replacements[item.id] ?? item,
          toAdd,
        ];
      }
      return ReminderActionResult(
        ReminderActionDisposition.applied,
        reminder: toAdd,
        nativeSyncFailed:
            _pendingNotificationRetries.contains(toAdd.id) ||
                (!toAdd.isCompleted &&
                    toAdd.noticeAcknowledgedAt == null &&
                    (toAdd.triggerTime?.isAfter(DateTime.now()) ?? false))
            ? await _synchronizeReminder(toAdd, ticket)
            : false,
      );
    }),
    generation: generation,
  );

  Future<ReminderActionResult> updateReminder(
    Reminder reminder, {
    Reminder? baseline,
  }) async {
    final generation = _dbHelper.captureGeneration();
    return updateReminderForGeneration(
      reminder,
      generation,
      baseline: baseline,
    );
  }

  Future<ReminderActionResult> updateReminderForGeneration(
    Reminder reminder,
    DataGeneration generation, {
    Reminder? baseline,
  }) async {
    if (baseline != null && baseline.id != reminder.id) {
      throw ArgumentError('Reminder edit baseline does not match.');
    }
    _dbHelper.checkGeneration(generation);
    if (_stateGeneration != null) {
      _dbHelper.checkGeneration(_stateGeneration!);
    }
    // Preserve field changes requested before waiting behind another edit.
    final changes = reminder.toJson()
      ..remove('id')
      ..removeWhere((key, _) => _noticeMetadata.contains(key));
    final before =
        baseline ?? state.where((r) => r.id == reminder.id).firstOrNull;
    if (before != null) {
      final values = before.toJson();
      changes.removeWhere((key, value) => values[key] == value);
    }
    return _enqueue(
      (ticket) => _dbHelper.runOperation(ticket, () async {
        if (!mounted) {
          throw StateError('Reminder state is no longer active.');
        }
        var needsNotificationSync = false;
        var cancelOverdue = false;
        final updated = await _dbHelper.writeTransaction(ticket, (txn) async {
          final rows = await txn.query(
            'Reminders',
            where: 'id = ?',
            whereArgs: [reminder.id],
          );
          if (rows.isEmpty) throw StateError('Task no longer exists.');
          final current = Reminder.fromJson(rows.single);
          var saved = Reminder.fromJson({...current.toJson(), ...changes});
          if (_scheduleChanged(current, saved)) {
            cancelOverdue = true;
            // A whole old Reminder can carry the pre-snooze time even when its
            // caller intended only a title edit. Never resurrect that occurrence.
            if (reminder.noticeRevision != current.noticeRevision) {
              throw const StaleReminderOccurrenceException();
            }
            saved = saved.copyWith(
              noticeRevision: current.noticeRevision + 1,
              noticeAcknowledgedAt: null,
              upcomingDismissedAt: null,
              snoozedAt: null,
              recurrenceAnchorTime: null,
            );
          }
          needsNotificationSync =
              _nativeContentChanged(current, saved) ||
              (changes.isEmpty &&
                  _pendingNotificationRetries.contains(saved.id));
          if (changes.isNotEmpty) {
            await txn.update(
              'Reminders',
              saved.toJson()..remove('id'),
              where: 'id = ?',
              whereArgs: [saved.id],
            );
          }
          return saved;
        });
        _dbHelper.checkGeneration(ticket);
        _publish([updated]);
        return ReminderActionResult(
          changes.isEmpty
              ? ReminderActionDisposition.alreadyApplied
              : ReminderActionDisposition.applied,
          reminder: updated,
          nativeSyncFailed: needsNotificationSync
              ? await _synchronizeReminder(
                  updated,
                  ticket,
                  cancelOverdue: cancelOverdue,
                )
              : false,
        );
      }),
      generation: generation,
    );
  }

  static bool _nativeContentChanged(Reminder a, Reminder b) =>
      _scheduleChanged(a, b) ||
      a.taskTitle != b.taskTitle ||
      a.taskSummary != b.taskSummary ||
      a.quadrantLevel != b.quadrantLevel;

  /// Runs inside the mutation queue and its database admission, after commit.
  /// A native failure never turns a saved row into a failed database write.
  Future<bool> _synchronizeReminder(
    Reminder reminder,
    DataGeneration generation, {
    bool cancelOverdue = false,
  }) async {
    _dbHelper.checkGeneration(generation);
    if (!mounted) throw StateError('Reminder state is no longer active.');
    final cancel =
        reminder.isCompleted ||
        reminder.noticeAcknowledgedAt != null ||
        reminder.triggerTime == null;
    if (!cancel && !reminder.triggerTime!.isAfter(DateTime.now())) {
      // Do not replay an overdue occurrence or erase its delivered banner.
      // Moving a future alarm into the past must still remove its old request.
      return cancelOverdue ||
              _pendingNotificationCancellations.contains(reminder.id)
          ? _synchronizeNotification(
              reminder.id,
              generation,
              () => _notifications.cancelReminderStrict(reminder.id),
              cancellation: true,
            )
          : false;
    }
    return _synchronizeNotification(
      reminder.id,
      generation,
      () => cancel
          ? _notifications.cancelReminderStrict(reminder.id)
          : _notifications.scheduleReminderStrict(reminder),
      cancellation: cancel,
    );
  }

  Future<bool> _synchronizeNotification(
    String id,
    DataGeneration generation,
    Future<void> Function() action, {
    bool cancellation = false,
  }) async {
    _dbHelper.checkGeneration(generation);
    if (!mounted) throw StateError('Reminder state is no longer active.');
    var failed = false;
    try {
      await action();
      _pendingNotificationRetries.remove(id);
      _pendingNotificationCancellations.remove(id);
    } catch (_) {
      failed = true;
      _pendingNotificationRetries.add(id);
      if (cancellation) {
        _pendingNotificationCancellations.add(id);
      } else {
        _pendingNotificationCancellations.remove(id);
      }
    }
    _dbHelper.checkGeneration(generation);
    if (!mounted) throw StateError('Reminder state is no longer active.');
    return failed;
  }

  static const _noticeMetadata = {
    'notice_revision',
    'notice_acknowledged_at',
    'upcoming_dismissed_at',
    'snoozed_at',
    'recurrence_anchor_time',
  };

  static bool _sameTime(DateTime? a, DateTime? b) =>
      a == null ? b == null : b != null && a.isAtSameMomentAs(b);

  static bool _scheduleChanged(Reminder a, Reminder b) =>
      !_sameTime(a.triggerTime, b.triggerTime) ||
      a.isCompleted != b.isCompleted ||
      a.isRecurring != b.isRecurring ||
      a.recurrenceRule != b.recurrenceRule;

  void _publish(Iterable<Reminder> saved) {
    if (!mounted) return;
    final changes = {for (final reminder in saved) reminder.id: reminder};
    state = [for (final item in state) changes[item.id] ?? item];
  }

  Future<ReminderActionResult> acknowledgeOccurrence(
    Reminder expected, {
    required ReminderNoticePhase phase,
    DateTime? now,
  }) => _actOnOccurrences(
    [expected],
    [
      phase == ReminderNoticePhase.upcoming
          ? _ReminderAction.acknowledgeUpcoming
          : _ReminderAction.acknowledgeDue,
    ],
    now ?? DateTime.now(),
  ).then((results) => results.single);

  Future<List<ReminderActionResult>> acknowledgeOccurrences(
    List<Reminder> expected, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final snapshot = List<Reminder>.of(expected);
    return _actOnOccurrences(snapshot, [
      for (final item in snapshot)
        item.triggerTime?.isAfter(at) ?? false
            ? _ReminderAction.acknowledgeUpcoming
            : _ReminderAction.acknowledgeDue,
    ], at);
  }

  Future<ReminderActionResult> snoozeOccurrence(
    Reminder expected, {
    DateTime? now,
    Duration duration = const Duration(minutes: 5),
  }) {
    if (duration <= Duration.zero) {
      return Future.error(ArgumentError.value(duration, 'duration'));
    }
    return _actOnOccurrences(
      [expected],
      [_ReminderAction.snooze],
      now ?? DateTime.now(),
      snoozeDuration: duration,
    ).then((results) => results.single);
  }

  Future<ReminderActionResult> completeOccurrence(
    Reminder expected, {
    DateTime? now,
  }) => _actOnOccurrences(
    [expected],
    [_ReminderAction.complete],
    now ?? DateTime.now(),
  ).then((results) => results.single);

  Future<List<ReminderActionResult>> _actOnOccurrences(
    List<Reminder> expected,
    List<_ReminderAction> actions,
    DateTime now, {
    Duration snoozeDuration = const Duration(minutes: 5),
  }) => _enqueue(
    (generation) => _dbHelper.runOperation(generation, () async {
      if (!mounted) {
        return [
          for (final _ in expected)
            const ReminderActionResult(ReminderActionDisposition.stale),
        ];
      }
      final results = await _dbHelper.writeTransaction(generation, (txn) async {
        final saved = <ReminderActionResult>[];
        for (var index = 0; index < expected.length; index++) {
          final wanted = expected[index];
          final action = actions[index];
          final rows = await txn.query(
            'Reminders',
            where: 'id = ?',
            whereArgs: [wanted.id],
          );
          final current = rows.isEmpty ? null : Reminder.fromJson(rows.single);
          if (current == null ||
              current.isCompleted ||
              current.occurrenceIdentity != wanted.occurrenceIdentity ||
              (action == _ReminderAction.snooze &&
                  current.noticeAcknowledgedAt != null) ||
              (action != _ReminderAction.complete &&
                  current.triggerTime == null) ||
              ((action == _ReminderAction.snooze ||
                      action == _ReminderAction.acknowledgeDue) &&
                  current.triggerTime!.isAfter(now))) {
            saved.add(
              const ReminderActionResult(ReminderActionDisposition.stale),
            );
            continue;
          }
          Reminder next;
          if (action == _ReminderAction.acknowledgeUpcoming ||
              action == _ReminderAction.acknowledgeDue) {
            final upcoming = action == _ReminderAction.acknowledgeUpcoming;
            if ((upcoming
                    ? current.upcomingDismissedAt
                    : current.noticeAcknowledgedAt) !=
                null) {
              saved.add(
                ReminderActionResult(
                  ReminderActionDisposition.alreadyApplied,
                  reminder: current,
                ),
              );
              continue;
            }
            next = upcoming
                ? current.copyWith(upcomingDismissedAt: now)
                : current.copyWith(noticeAcknowledgedAt: now);
          } else {
            final snooze = action == _ReminderAction.snooze;
            // A retained calendar anchor can precede the current occurrence.
            // Completing that occurrence early must still advance past it.
            final cutoff = current.triggerTime?.isAfter(now) ?? false
                ? current.triggerTime!
                : now;
            final nextTime = snooze
                ? now.add(snoozeDuration)
                : current.getNextOccurrence(after: cutoff);
            next = current.copyWith(
              triggerTime: nextTime ?? current.triggerTime,
              isCompleted: nextTime == null,
              noticeRevision: current.noticeRevision + 1,
              noticeAcknowledgedAt: null,
              upcomingDismissedAt: null,
              snoozedAt: snooze ? now : null,
              recurrenceAnchorTime: snooze || nextTime != null
                  ? current.recurrenceAnchorTime ?? current.triggerTime
                  : null,
            );
          }
          await txn.update(
            'Reminders',
            next.toJson()..remove('id'),
            where: 'id = ?',
            whereArgs: [next.id],
          );
          saved.add(
            ReminderActionResult(
              ReminderActionDisposition.applied,
              reminder: next,
            ),
          );
        }
        return saved;
      });
      _dbHelper.checkGeneration(generation);
      _publish(results.map((r) => r.reminder).whereType<Reminder>());
      final reconciled = <ReminderActionResult>[];
      for (var index = 0; index < results.length; index++) {
        final result = results[index];
        if (!result.accepted ||
            actions[index] == _ReminderAction.acknowledgeUpcoming) {
          reconciled.add(result);
          continue;
        }
        final saved = result.reminder!;
        final failed = await _synchronizeNotification(
          saved.id,
          generation,
          () => saved.isCompleted || saved.noticeAcknowledgedAt != null
              ? _notifications.cancelReminderStrict(saved.id)
              : _notifications.scheduleReminderStrict(saved),
          cancellation: saved.isCompleted || saved.noticeAcknowledgedAt != null,
        );
        _dbHelper.checkGeneration(generation);
        reconciled.add(
          ReminderActionResult(
            result.disposition,
            reminder: result.reminder,
            nativeSyncFailed: failed,
          ),
        );
      }
      return reconciled;
    }),
  );

  Future<void> linkTwoTasks(String id1, String id2) =>
      _enqueue((generation) async {
        if (id1 == id2 || !mounted) {
          return;
        }
        final byId = {for (final item in state) item.id: item};
        final task1 = byId[id1], task2 = byId[id2];
        if (task1 == null || task2 == null) {
          return;
        }
        final replacements = <String, Reminder>{
          if (!task1.linkedTaskIds.contains(id2))
            id1: task1.copyWith(linkedTaskIds: [...task1.linkedTaskIds, id2]),
          if (!task2.linkedTaskIds.contains(id1))
            id2: task2.copyWith(linkedTaskIds: [...task2.linkedTaskIds, id1]),
        };
        await _dbHelper.writeTransaction(generation, (txn) async {
          for (final item in replacements.values) {
            await txn.update(
              'Reminders',
              {'linked_task_ids': item.toJson()['linked_task_ids']},
              where: 'id = ?',
              whereArgs: [item.id],
            );
          }
        });
        _dbHelper.checkGeneration(generation);
        if (mounted && replacements.isNotEmpty) {
          state = [for (final item in state) replacements[item.id] ?? item];
        }
      });

  Future<void> unlinkTwoTasks(String id1, String id2) =>
      _enqueue((generation) async {
        if (!mounted) {
          return;
        }
        final replacements = <String, Reminder>{};
        for (final item in state) {
          final otherId = item.id == id1 ? id2 : (item.id == id2 ? id1 : null);
          if (otherId != null && item.linkedTaskIds.contains(otherId)) {
            replacements[item.id] = item.copyWith(
              linkedTaskIds: item.linkedTaskIds
                  .where((id) => id != otherId)
                  .toList(),
            );
          }
        }
        await _dbHelper.writeTransaction(generation, (txn) async {
          for (final item in replacements.values) {
            await txn.update(
              'Reminders',
              {'linked_task_ids': item.toJson()['linked_task_ids']},
              where: 'id = ?',
              whereArgs: [item.id],
            );
          }
        });
        _dbHelper.checkGeneration(generation);
        if (mounted && replacements.isNotEmpty) {
          state = [for (final item in state) replacements[item.id] ?? item];
        }
      });

  Future<ReminderBatchResult> scanAndApplyDynamicUrgency() =>
      _enqueue(_applyDynamicUrgency);

  Future<ReminderBatchResult> _applyDynamicUrgency(
    DataGeneration generation, {
    bool synchronize = true,
  }) {
    _dbHelper.checkGeneration(generation);
    if (!mounted) {
      throw StateError('Reminder state is no longer active.');
    }
    // Most heartbeats have no candidate. Avoid a whole-table SQL read/write
    // transaction in that case; a LAN refresh evaluates its newly loaded rows.
    final candidates = const DynamicUrgencyService().evaluatePromotions(state);
    if (identical(candidates, state)) {
      return Future.value(const ReminderBatchResult());
    }
    return _dbHelper.runOperation(generation, () async {
      final result = await _dbHelper.writeTransaction(generation, (txn) async {
        // LAN writes may have changed a row since the last provider refresh.
        final original = (await txn.query(
          'Reminders',
        )).map(Reminder.fromJson).toList();
        final updated = const DynamicUrgencyService().evaluatePromotions(
          original,
        );
        final promoted = [
          for (var i = 0; i < updated.length; i++)
            if (!identical(updated[i], original[i])) updated[i],
        ];
        for (final item in promoted) {
          await txn.update(
            'Reminders',
            {
              'quadrant_level': item.quadrantLevel,
              'original_quadrant_level': item.originalQuadrantLevel,
              'is_dynamically_promoted': item.isDynamicallyPromoted ? 1 : 0,
            },
            where: 'id = ?',
            whereArgs: [item.id],
          );
        }
        return (updated: updated, promoted: promoted);
      });
      _dbHelper.checkGeneration(generation);
      if (mounted) state = result.updated;
      var failures = 0;
      if (synchronize) {
        for (final item in result.promoted) {
          if (await _synchronizeReminder(item, generation)) failures++;
        }
      }
      return ReminderBatchResult(
        changed: result.promoted.length,
        nativeSyncFailures: failures,
      );
    });
  }

  Future<ReminderActionResult> deleteReminder(String id) =>
      _enqueue((generation) => _deleteReminder(id, generation));

  Future<ReminderActionResult> deleteReminderForGeneration(
    String id,
    DataGeneration generation,
  ) =>
      _enqueue((ticket) => _deleteReminder(id, ticket), generation: generation);

  Future<ReminderActionResult> _deleteReminder(
    String id,
    DataGeneration generation,
  ) => _dbHelper.runOperation(generation, () async {
    if (!mounted) {
      throw StateError('Reminder state is no longer active.');
    }
    final deleted = await _dbHelper.writeTransaction(generation, (txn) async {
      final rows = await txn.query(
        'Reminders',
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.delete('Reminders', where: 'id = ?', whereArgs: [id]);
      return rows.isEmpty ? null : Reminder.fromJson(rows.single);
    });
    _dbHelper.checkGeneration(generation);
    if (mounted) {
      state = state.where((r) => r.id != id).toList();
    }
    return ReminderActionResult(
      deleted == null
          ? ReminderActionDisposition.alreadyApplied
          : ReminderActionDisposition.applied,
      reminder: deleted,
      nativeSyncFailed: await _synchronizeNotification(
        id,
        generation,
        () => _notifications.cancelReminderStrict(id),
        cancellation: true,
      ),
    );
  });

  Future<ReminderBatchResult> clearCompletedReminders() => _enqueue(
    (generation) => _dbHelper.runOperation(generation, () async {
      if (!mounted) {
        throw StateError('Reminder state is no longer active.');
      }
      final ids = await _dbHelper.writeTransaction(generation, (txn) async {
        final rows = await txn.query(
          'Reminders',
          columns: ['id'],
          where: 'is_completed = 1',
        );
        await txn.delete('Reminders', where: 'is_completed = 1');
        return rows.map((row) => row['id'] as String).toList();
      });
      _dbHelper.checkGeneration(generation);
      if (mounted) {
        state = state.where((r) => !r.isCompleted).toList();
      }
      var failures = 0;
      for (final id in ids) {
        if (await _synchronizeNotification(
          id,
          generation,
          () => _notifications.cancelReminderStrict(id),
          cancellation: true,
        )) {
          failures++;
        }
      }
      return ReminderBatchResult(
        changed: ids.length,
        nativeSyncFailures: failures,
      );
    }),
  );

  Future<void> refreshReminders() =>
      _enqueue(_loadReminders, requiresCurrentState: false);
}

final mediaRecordsProvider =
    StateNotifierProvider<MediaRecordsNotifier, List<MediaRecord>>((ref) {
      return MediaRecordsNotifier(ref.read(databaseHelperProvider));
    });

class MediaRecordsNotifier extends StateNotifier<List<MediaRecord>> {
  final DatabaseHelper _dbHelper;
  late final Future<void> ready;
  DataGeneration? _stateGeneration;

  MediaRecordsNotifier(this._dbHelper) : super([]) {
    ready = _loadRecords();
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<void> _loadRecords() async {
    final generation = _dbHelper.captureGeneration();
    final rows = await _dbHelper.read(
      generation,
      (db) => db.query('MediaRecords'),
    );
    _dbHelper.checkGeneration(generation);
    _stateGeneration = generation;
    if (mounted) {
      state = rows.map(MediaRecord.fromJson).toList();
    }
  }

  Future<void> addRecord(MediaRecord record) async {
    final generation = _dbHelper.captureGeneration();
    await addRecordForGeneration(record, generation);
  }

  Future<void> addRecordForGeneration(
    MediaRecord record,
    DataGeneration generation,
  ) async {
    _dbHelper.checkGeneration(generation);
    if (_stateGeneration != null) {
      _dbHelper.checkGeneration(_stateGeneration!);
    }
    await ready;
    _dbHelper.checkGeneration(generation);
    _dbHelper.checkGeneration(_stateGeneration!);
    await _dbHelper.writeTransaction(
      generation,
      (txn) => txn.insert('MediaRecords', record.toJson()),
    );
    _dbHelper.checkGeneration(generation);
    if (mounted) {
      state = [...state, record];
    }
  }
}

final llmServiceProvider = Provider<LLMService>((ref) {
  final service = LLMService();
  ref.onDispose(service.dispose);
  return service;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.forDatabase(ref.read(databaseHelperProvider));
});

final lanSyncServiceProvider = Provider<LanSyncService>((ref) {
  return LanSyncService.instance;
});

final dpSchedulerServiceProvider = Provider<DPSchedulerService>((ref) {
  return const DPSchedulerService();
});

final multiAgentServiceProvider = Provider<MultiAgentService>((ref) {
  final service = MultiAgentService(
    llmService: ref.read(llmServiceProvider),
    dpScheduler: ref.read(dpSchedulerServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final spacedRepetitionServiceProvider = Provider<SpacedRepetitionService>((
  ref,
) {
  return const SpacedRepetitionService();
});

final dataExportServiceProvider = Provider<DataExportService>((ref) {
  return const DataExportService();
});

class ImmersiveModeNotifier extends StateNotifier<bool> {
  final NotificationService _notificationService;
  ImmersiveModeNotifier(this._notificationService) : super(false);

  void toggle() {
    state = !state;
    _notificationService.isImmersiveModeActive = state;
  }

  void setMode(bool enabled) {
    state = enabled;
    _notificationService.isImmersiveModeActive = enabled;
  }
}

final immersiveModeProvider =
    StateNotifierProvider<ImmersiveModeNotifier, bool>((ref) {
      return ImmersiveModeNotifier(ref.read(notificationServiceProvider));
    });

final dynamicUrgencyServiceProvider = Provider<DynamicUrgencyService>((ref) {
  return const DynamicUrgencyService();
});

final biDirectionalLinkServiceProvider = Provider<BiDirectionalLinkService>((
  ref,
) {
  return const BiDirectionalLinkService();
});

final contextTriggerServiceProvider = Provider<ContextTriggerService>((ref) {
  return ContextTriggerService();
});

class ContextProfileNotifier extends StateNotifier<ContextProfile> {
  final ContextTriggerService _service;
  final DatabaseHelper _database;
  final NotificationService _notifications;
  ContextProfileNotifier(this._service, this._database, this._notifications)
    : super(_service.currentProfile);

  Future<void> setProfile(ContextProfile profile) async {
    final generation = _database.captureGeneration();
    await _database.runOperation(generation, () async {
      _database.checkGeneration(generation);
      _service.switchProfile(profile);
      await _notifications.reconcileNotificationPolicy();
    });
    _database.checkGeneration(generation);
    if (mounted) {
      state = profile;
    }
  }
}

final contextProfileProvider =
    StateNotifierProvider<ContextProfileNotifier, ContextProfile>((ref) {
      return ContextProfileNotifier(
        ref.read(contextTriggerServiceProvider),
        ref.read(databaseHelperProvider),
        ref.read(notificationServiceProvider),
      );
    });
