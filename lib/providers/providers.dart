import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' show DatabaseExecutor;
import '../services/recovery/runtime_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database_helper.dart';
import '../models/settings.dart';
import '../models/reminder.dart';
import '../models/task_details.dart';
import '../models/notification_schedule_status.dart';
import '../services/notification_schedule_reader.dart';
import '../services/notification_permission_service.dart';
import '../models/media_record.dart';
import '../services/llm_service.dart';
import '../services/notification_service.dart';
import '../services/notification_journal.dart';
import '../services/startup_trace.dart';
import '../services/lan_sync_service.dart';
import '../services/dp_scheduler_service.dart';
import '../services/multi_agent_service.dart';
import '../services/spaced_repetition_service.dart';
import '../services/study_plan_service.dart';
import '../services/learning_queue_service.dart';
import '../models/vocabulary_entry.dart';
import '../services/data_export_service.dart';
import '../services/dynamic_urgency_service.dart';
import '../services/bidirectional_link_service.dart';
import '../services/context_trigger_service.dart';

part 'task_management.dart';

final databaseHelperProvider = Provider<DatabaseHelper>((ref) {
  return DatabaseHelper.instance;
});

final studyPlanServiceProvider = Provider<StudyPlanService>((ref) {
  final service = StudyPlanService();
  ref.onDispose(service.dispose);
  return service;
});

/// Reading settings must not instantiate the reminder scheduling controller.
final notificationScheduleStatusReaderProvider =
    Provider<Future<NotificationScheduleStatus> Function()>((ref) {
      return NotificationScheduleReader(
        ref.read(databaseHelperProvider),
        isSuppressed: (task) =>
            ref.read(notificationServiceProvider).isSuppressed(task),
      ).read;
    });

final reminderScheduleReaderProvider =
    Provider<Future<ReminderSchedulePhase> Function(Reminder)>((ref) {
      return NotificationScheduleReader(
        ref.read(databaseHelperProvider),
        isSuppressed: (task) =>
            ref.read(notificationServiceProvider).isSuppressed(task),
      ).readReminder;
    });

final notificationPermissionReaderProvider =
    Provider<Future<NotificationPermissionSnapshot> Function()>((ref) {
      return NotificationPermissionService().refresh;
    });

final runtimeRecoveryGateProvider = Provider<RuntimeRecoveryGate>((ref) {
  return RuntimeRecoveryGate();
});

/// Synchronous registration by the visible workspace; native menu calls do not
/// navigate over an editor or replay into a new recovery session.
final workspaceToolsCommandProvider = Provider(
  (ref) => WorkspaceToolsCommand(),
);

class WorkspaceToolsCommand {
  bool Function()? open;
  bool Function()? search;
}

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
    StartupTrace.mark('settings_loaded');
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
    final saved = AppSettings.fromJson(newSettings.toJson());
    String? drafts;
    await _dbHelper.writeTransaction(generation, (txn) async {
      final current = await txn.query(
        'Settings',
        where: 'id = ?',
        whereArgs: ['default'],
      );
      drafts = current.firstOrNull?['workspace_drafts_json'] as String?;
      await txn.delete('Settings', where: 'id = ?', whereArgs: ['default']);
      await txn.insert('Settings', {
        ...saved.toJson(),
        'id': 'default',
        'workspace_drafts_json': drafts,
      });
    });
    _dbHelper.checkGeneration(generation);
    if (mounted) {
      state = AppSettings.fromJson({
        ...saved.toJson(),
        'id': 'default',
        'workspace_drafts_json': drafts,
      });
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

class PinLimitException implements Exception {
  const PinLimitException();
}

enum _ReminderAction {
  acknowledgeUpcoming,
  acknowledgeDue,
  snooze,
  complete,
  skip,
}

class RemindersNotifier extends StateNotifier<List<Reminder>> {
  final DatabaseHelper _dbHelper;
  final NotificationService _notifications;
  late final Future<void> ready;
  Future<void> _operations = Future<void>.value();
  DataGeneration? _stateGeneration;
  final Map<String, DateTime?> _pendingNotificationRetries = {};
  final Set<String> _pendingNotificationCancellations = {};
  String? _notificationRetryCursor;

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
      StartupTrace.mark('tasks_loaded');
      // Recovery already rebuilt notifications from the committed database.
      // Loading UI state must not reschedule or mutate it a second time.
      if (!runEffects) return;
      // Promote before scheduling so startup uses the final saved priority.
      await _applyDynamicUrgency(generation, synchronize: false);
      final journal = await _notificationEntries(generation);
      _rememberUnfinished(journal.values);
      // A process can exit between deleting a row and cancelling its OS
      // request. Retained ID allocations let startup find those orphaned
      // requests even when no failed-cancel result was written.
      final existingIds = state.map((r) => r.id).toSet();
      await _startupBatches(
        journal.values.where(
          (entry) =>
              !existingIds.contains(entry.reminderId) &&
              entry.needsCancellation,
        ),
        (entry) async {
          await _dbHelper.runOperation(
            generation,
            () => _synchronizeNotification(
              entry.reminderId,
              generation,
              () => _notifications.cancelReminderStrict(entry.reminderId),
              cancellation: true,
            ),
          );
        },
      );
      final now = DateTime.now();
      await _startupBatches(state, (reminder) async {
        _dbHelper.checkGeneration(generation);
        if (!mounted) {
          return;
        }
        if (!reminder.canNotify ||
            reminder.noticeAcknowledgedAt != null ||
            reminder.triggerTime == null ||
            _requiresPastCancellation(reminder, journal[reminder.id], now)) {
          await _dbHelper.runOperation(generation, () async {
            _dbHelper.checkGeneration(generation);
            await _synchronizeReminder(
              reminder,
              generation,
              cancelOverdue: true,
            );
          });
        } else if (reminder.canNotify &&
            reminder.triggerTime != null &&
            reminder.triggerTime!.isAfter(now)) {
          // Restart must not bypass the persisted quiet-retry cooldown for
          // the SAME failed occurrence. Edits, pending crash intents and old
          // failures still reconcile immediately; manual rebuild is immediate.
          final entry = journal[reminder.id];
          if (entry != null &&
              entry.status == 'failed' &&
              entry.action == 'schedule' &&
              entry.triggerUtcMicros ==
                  reminder.triggerTime!.toUtc().microsecondsSinceEpoch &&
              entry.noticeRevision == reminder.noticeRevision) {
            final attempted = DateTime.tryParse(entry.attemptedAt ?? '');
            if (attempted != null &&
                now.difference(attempted).abs() < const Duration(minutes: 1)) {
              if (StartupTrace.retryEnabled) {
                StartupTrace.notificationEvent('startup_failure_cooldown', {
                  'native_id': entry.nativeId,
                  'attempts': entry.attempts,
                });
              }
              return;
            }
          }
          await _dbHelper.runOperation(generation, () async {
            _dbHelper.checkGeneration(generation);
            await _synchronizeReminder(reminder, generation);
          });
        }
      });
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

  // Bound admitted work while the service separately caps native calls.
  // Allow independent intents/results to share a
  // durable journal replacement. Future.wait drains the batch before recovery
  // or a following batch can proceed, even when one operation throws.
  Future<void> _startupBatches<T>(
    Iterable<T> values,
    Future<void> Function(T) operation,
  ) async {
    final pending = <Future<void>>[];
    for (final value in values) {
      pending.add(operation(value));
      if (pending.length == NotificationService.reconciliationBatchSize) {
        await Future.wait(pending);
        pending.clear();
      }
    }
    await Future.wait(pending);
  }

  Future<Map<String, NotificationJournalEntry>> _notificationEntries(
    DataGeneration generation,
  ) async {
    final snapshot = await _dbHelper.withNotificationJournal((j) => j.read());
    _dbHelper.checkGeneration(generation);
    if (snapshot == null) return {};
    final epoch = await _dbHelper.readNotificationEpoch();
    _dbHelper.checkGeneration(generation);
    return snapshot.epoch == epoch ? snapshot.entries : {};
  }

  void _rememberUnfinished(Iterable<NotificationJournalEntry> entries) {
    for (final entry in entries.where((e) => e.unfinished)) {
      _pendingNotificationRetries[entry.reminderId] = DateTime.tryParse(
        entry.attemptedAt ?? '',
      );
      if (entry.action == 'cancel') {
        _pendingNotificationCancellations.add(entry.reminderId);
      }
    }
  }

  bool _requiresPastCancellation(
    Reminder reminder,
    NotificationJournalEntry? entry,
    DateTime now,
  ) {
    if (reminder.triggerTime == null || reminder.triggerTime!.isAfter(now)) {
      return false;
    }
    if (_pendingNotificationCancellations.contains(reminder.id) ||
        (entry?.action == 'cancel' && (entry?.unfinished ?? false))) {
      return true;
    }
    // Preserve a delivered current occurrence. Cancel a previous occurrence
    // when a time edit committed but the process exited before native sync.
    return entry?.action == 'schedule' &&
        (entry!.triggerUtcMicros !=
                reminder.triggerTime!.toUtc().microsecondsSinceEpoch ||
            entry.noticeRevision != reminder.noticeRevision);
  }

  Future<ReminderActionResult> addReminder(Reminder reminder) async {
    final generation = _dbHelper.captureGeneration();
    return addReminderForGeneration(reminder, generation);
  }

  /// A confirmed plan commits all rows before scheduling. Stable preview IDs
  /// make a retry after an uncertain result safe without duplicating tasks.
  Future<ReminderBatchResult> addStudyPlan(
    List<Reminder> reminders,
    DataGeneration generation,
  ) {
    final planned = List<Reminder>.unmodifiable(reminders);
    if (planned.isEmpty ||
        planned.length > 7 ||
        planned.map((r) => r.id).toSet().length != planned.length ||
        planned.any(
          (r) =>
              !r.reviewNotificationsEnabled ||
              r.spacedRepetitionLevel != 1 ||
              r.isCompleted ||
              r.isRecurring ||
              r.recordId != null ||
              r.linkedTaskIds.isNotEmpty ||
              r.triggerTime == null ||
              r.triggerTime != r.nextReviewAt,
        )) {
      throw ArgumentError('Invalid study batch');
    }
    return _enqueue(
      (ticket) => _dbHelper.runOperation(ticket, () async {
        if (!mounted) throw StateError('Study workspace closed');
        final inserted = await _dbHelper.writeTransaction(ticket, (txn) async {
          final existing = <Reminder>[];
          for (final task in planned) {
            final rows = await txn.query(
              'Reminders',
              where: 'id = ?',
              whereArgs: [task.id],
            );
            if (rows.isNotEmpty) existing.add(Reminder.fromJson(rows.single));
          }
          if (existing.isNotEmpty) {
            if (existing.length != planned.length ||
                existing.any(
                  (r) => !mapEquals(
                    r.toJson(),
                    planned.firstWhere((p) => p.id == r.id).toJson(),
                  ),
                )) {
              throw StateError('Study plan already changed');
            }
            return false;
          }
          final now = DateTime.now();
          if (planned.any((r) => !r.triggerTime!.isAfter(now))) {
            throw StateError('Study plan time expired');
          }
          for (final task in planned) {
            await txn.insert('Reminders', task.toJson());
          }
          return true;
        });
        _dbHelper.checkGeneration(ticket);
        if (mounted) {
          final ids = planned.map((r) => r.id).toSet();
          state = [...state.where((r) => !ids.contains(r.id)), ...planned];
        }
        var failures = 0;
        for (final task in planned) {
          if (await _synchronizeReminder(task, ticket)) failures++;
        }
        return ReminderBatchResult(
          changed: inserted ? planned.length : 0,
          nativeSyncFailures: failures,
        );
      }),
      generation: generation,
    );
  }

  /// Quiet foreground retries process durable unfinished work and failures
  /// observed before an intent could be persisted (for example plugin init).
  /// A manual rebuild remains immediate and reconciles all saved occurrences.
  Future<({int attempted, int failed})> retryFailedNotificationDelivery({
    required bool canSchedule,
    required bool Function() isActive,
    DateTime? now,
  }) => _enqueue(
    (generation) => _dbHelper.runOperation(generation, () async {
      void checkCurrent() {
        _dbHelper.checkGeneration(generation);
        if (!mounted || _notifications.isPausedForMaintenance) {
          throw StateError('Reminder runtime is unavailable.');
        }
      }

      checkCurrent();
      if (!isActive()) return (attempted: 0, failed: 0);
      final instant = now ?? DateTime.now();
      final entries = await _notificationEntries(generation);
      checkCurrent();
      final failureTimes = <String, DateTime?>{
        for (final entry in entries.values)
          if (entry.unfinished)
            entry.reminderId: DateTime.tryParse(entry.attemptedAt ?? ''),
        for (final failure in _pendingNotificationRetries.entries)
          if (!(entries[failure.key]?.unfinished ?? false))
            failure.key: failure.value,
      };
      final candidates =
          failureTimes.keys.where((id) {
            final attempted = failureTimes[id];
            // A clock moved backwards must not strand a retry indefinitely.
            return attempted == null ||
                instant.difference(attempted).abs() >=
                    const Duration(minutes: 1);
          }).toList()..sort(
            (a, b) => (failureTimes[a]?.microsecondsSinceEpoch ?? 0).compareTo(
              failureTimes[b]?.microsecondsSinceEpoch ?? 0,
            ),
          );
      var attempted = 0;
      var failed = 0;
      final cursor = candidates.indexOf(_notificationRetryCursor ?? '');
      final start = cursor < 0 ? 0 : cursor + 1;
      // Bound both native calls and SQL reads. Rotate so permission-blocked
      // schedules cannot starve cancellation work later in the journal.
      final batch = [
        ...candidates.skip(start),
        ...candidates.take(start),
      ].take(8);
      for (final id in batch) {
        checkCurrent();
        if (!isActive()) break;
        _notificationRetryCursor = id;
        final rows = await _dbHelper.read(
          generation,
          (db) =>
              db.query('Reminders', where: 'id = ?', whereArgs: [id], limit: 1),
        );
        checkCurrent();
        if (!isActive()) break;
        final reminder = rows.isEmpty ? null : Reminder.fromJson(rows.single);
        final cancel =
            reminder == null ||
            !reminder.canNotify ||
            reminder.noticeAcknowledgedAt != null ||
            reminder.triggerTime == null ||
            _requiresPastCancellation(reminder, entries[id], instant);
        // Do not replay an expired current occurrence, even after a failure.
        if (!cancel &&
            (!canSchedule || !reminder.triggerTime!.isAfter(instant))) {
          continue;
        }
        attempted++;
        if (await _synchronizeNotification(
          id,
          generation,
          () => cancel
              ? _notifications.cancelReminderStrict(id)
              : _notifications.scheduleReminderStrict(reminder),
          cancellation: cancel,
        )) {
          failed++;
        }
      }
      return (attempted: attempted, failed: failed);
    }),
  );

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
      await _notifications.init();
      checkCurrent();
      final journal = await _notificationEntries(generation);
      _rememberUnfinished(journal.values);
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
            !reminder.canNotify ||
            reminder.noticeAcknowledgedAt != null ||
            reminder.triggerTime == null ||
            _requiresPastCancellation(
              reminder,
              journal[reminder.id],
              now ?? DateTime.now(),
            );
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
          _pendingNotificationRetries[reminder.id] = DateTime.now();
          if (cancel) _pendingNotificationCancellations.add(reminder.id);
          failed++;
        }
        // Recovery/disposal is not a native failure to collect and continue.
        checkCurrent();
      }
      // A failed cancellation can outlive the saved row in this session.
      // Retain that ID until cancellation succeeds; do not recreate the task.
      final orphaned = <String>{
        ..._pendingNotificationRetries.keys.toSet().difference(existingIds),
        for (final entry in journal.values)
          if (!existingIds.contains(entry.reminderId) &&
              entry.needsCancellation)
            entry.reminderId,
      };
      for (final id in orphaned) {
        checkCurrent();
        attempted++;
        try {
          await _notifications.cancelReminderStrict(id);
          _pendingNotificationRetries.remove(id);
          _pendingNotificationCancellations.remove(id);
        } catch (_) {
          _pendingNotificationRetries[id] = DateTime.now();
          _pendingNotificationCancellations.add(id);
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
  ) => _insertReminderForGeneration(reminder, generation, suggestLinks: true);

  /// Undo restores the saved row without treating it as newly authored content.
  /// The deletion generation also prevents old Undo actions crossing recovery.
  Future<ReminderActionResult> restoreDeletedReminder(
    Reminder reminder,
    DataGeneration generation,
  ) => _insertReminderForGeneration(reminder, generation, suggestLinks: false);

  Future<ReminderActionResult> _insertReminderForGeneration(
    Reminder reminder,
    DataGeneration generation, {
    required bool suggestLinks,
  }) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      if (!mounted) {
        throw StateError('Reminder state is no longer active.');
      }
      Reminder toAdd = reminder;
      final replacements = <String, Reminder>{};
      if (suggestLinks && toAdd.linkedTaskIds.isEmpty && state.isNotEmpty) {
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
            _pendingNotificationRetries.containsKey(toAdd.id) ||
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
          if (changes.containsKey('details_json') &&
              before != null &&
              current.detailsJson != before.detailsJson) {
            throw const StaleReminderOccurrenceException();
          }
          var saved = Reminder.fromJson({...current.toJson(), ...changes});
          if (changes.isNotEmpty) {
            final at = DateTime.now();
            final statusChanged = saved.isCompleted != current.isCompleted;
            final medication = current.details.kind == 'medication';
            saved = saved.copyWith(
              detailsJson: saved.details
                  .record(
                    statusChanged
                        ? saved.isCompleted
                              ? medication
                                    ? 'taken'
                                    : 'completed'
                              : 'reopened'
                        : 'edited',
                    at,
                    scheduled: current.eventTime ?? current.triggerTime,
                  )
                  .patch({
                    if (statusChanged)
                      'completed_at': saved.isCompleted
                          ? at.toIso8601String()
                          : null,
                    if (statusChanged && medication)
                      'dose_outcome': saved.isCompleted ? 'taken' : null,
                  })
                  .encode(),
            );
          }
          if (saved.isPinned &&
              (!current.isPinned || current.isCompleted) &&
              !saved.isCompleted) {
            final pinned = await txn.query(
              'Reminders',
              columns: ['id'],
              where: 'is_pinned = 1 AND is_completed = 0',
            );
            if (pinned.length >= 3) throw const PinLimitException();
          }
          if (current.details.kind == 'medication' &&
              (saved.isRecurring ||
                  saved.spacedRepetitionLevel > 0 ||
                  saved.eventTime != current.eventTime ||
                  saved.triggerTime != current.triggerTime)) {
            throw StateError(
              'Change medication timing through its course preview',
            );
          }
          // Editing a learning alarm also edits its review date. Clearing the
          // alarm returns it to an app-only review card instead of resurrecting
          // notifications on the next answer.
          if (saved.reviewNotificationsEnabled &&
              changes.containsKey('trigger_time') &&
              !changes.containsKey('next_review_at')) {
            saved = saved.copyWith(
              nextReviewAt: saved.triggerTime ?? saved.nextReviewAt,
              reviewNotificationsEnabled: saved.triggerTime != null,
            );
          }
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
              recurrenceEventAnchorTime: null,
            );
          }
          if (!_sameTime(current.eventTime, saved.eventTime)) {
            saved = saved.copyWith(recurrenceEventAnchorTime: null);
          }
          needsNotificationSync =
              _nativeContentChanged(current, saved) ||
              (changes.isEmpty &&
                  _pendingNotificationRetries.containsKey(saved.id));
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

  /// Model output is a durable proposal. Only explicit confirmation applies it.
  Future<ReminderBatchResult> enrichCapture(
    Reminder baseline,
    List<Reminder> extracted,
    DataGeneration generation,
  ) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final saved = await _dbHelper.writeTransaction(ticket, (txn) async {
        final rows = await txn.query(
          'Reminders',
          where: 'id = ?',
          whereArgs: [baseline.id],
        );
        if (rows.isEmpty) return null;
        final current = Reminder.fromJson(rows.single);
        if (!current.capturePending || current.isCompleted) return null;
        if (extracted.length > 32) {
          throw const FormatException('Too many extracted tasks');
        }
        final saved = current.copyWith(
          capturePending: false,
          captureProposalJson:
              current.sourceText == baseline.sourceText && extracted.isNotEmpty
              ? jsonEncode(extracted.map((r) => r.toJson()).toList())
              : null,
        );
        await txn.update(
          'Reminders',
          saved.toJson(),
          where: 'id = ?',
          whereArgs: [saved.id],
        );
        return saved;
      });
      _dbHelper.checkGeneration(ticket);
      if (saved != null) _publish([saved]);
      return ReminderBatchResult(changed: saved == null ? 0 : 1);
    }),
    generation: generation,
  );

  Future<ReminderBatchResult> applyCaptureProposal(
    Reminder expected,
    List<Reminder> edited, {
    DataGeneration? generation,
  }) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      if (edited.isEmpty ||
          edited.length > 32 ||
          edited.any(
            (r) =>
                r.taskTitle.trim().isEmpty ||
                (r.triggerTime != null &&
                    !r.triggerTime!.isAfter(DateTime.now())),
          )) {
        throw const FormatException(
          'Review the extracted tasks and their reminder times',
        );
      }
      final saved = await _dbHelper.writeTransaction(ticket, (txn) async {
        final rows = await txn.query(
          'Reminders',
          where: 'id = ?',
          whereArgs: [expected.id],
        );
        if (rows.isEmpty) throw const StaleReminderOccurrenceException();
        final current = Reminder.fromJson(rows.single);
        final expectedFields = expected.toJson();
        final unchanged = current.toJson().entries.every(
          (entry) =>
              _noticeMetadata.contains(entry.key) ||
              expectedFields[entry.key] == entry.value,
        );
        if (current.isCompleted ||
            current.captureProposalJson == null ||
            current.captureProposalJson != expected.captureProposalJson ||
            current.noticeRevision != expected.noticeRevision ||
            !unchanged) {
          throw const StaleReminderOccurrenceException();
        }
        final result = <Reminder>[];
        for (var i = 0; i < edited.length; i++) {
          final item = Reminder.fromJson({
            ...edited[i].toJson(),
            'id': i == 0 ? current.id : '${current.id}:capture:$i',
            'source_text': current.sourceText,
            'record_id': current.recordId,
            'created_at': current.createdAt?.toIso8601String(),
            'capture_pending': 0,
            'capture_proposal_json': null,
            'details_json': i == 0 ? current.detailsJson : null,
            'is_pinned': i == 0 && current.isPinned ? 1 : 0,
            'notice_revision': i == 0 ? current.noticeRevision + 1 : 0,
            'notice_acknowledged_at': null,
            'upcoming_dismissed_at': null,
            'snoozed_at': null,
            'recurrence_anchor_time': null,
            'recurrence_event_anchor_time': null,
          });
          if (i == 0) {
            await txn.update(
              'Reminders',
              item.toJson(),
              where: 'id = ?',
              whereArgs: [item.id],
            );
          } else {
            await txn.insert('Reminders', item.toJson());
          }
          result.add(item);
        }
        return result;
      });
      _dbHelper.checkGeneration(ticket);
      if (mounted) {
        final byId = {for (final item in saved) item.id: item};
        state = [
          for (final item in state) byId.remove(item.id) ?? item,
          ...byId.values,
        ];
      }
      var failures = 0;
      for (final item in saved) {
        if (await _synchronizeReminder(item, ticket, cancelOverdue: true)) {
          failures++;
        }
      }
      return ReminderBatchResult(
        changed: saved.length,
        nativeSyncFailures: failures,
      );
    }),
    generation: generation,
  );

  Future<ReminderBatchResult> gradeWord(
    Reminder expected,
    String key,
    int grade, {
    DateTime? now,
    DataGeneration? generation,
    int dailyLimit = 20,
    int newLimit = 10,
    List<int> intervals = const [1, 2, 4, 7, 15],
  }) => _enqueue(
    (ticket) => _dbHelper.runOperation(ticket, () async {
      final at = now ?? DateTime.now();
      final saved = await _dbHelper.writeTransaction(ticket, (txn) async {
        final tasks = (await txn.query(
          'Reminders',
        )).map(Reminder.fromJson).toList();
        final target = tasks.where((t) => t.id == expected.id).firstOrNull;
        if (target == null ||
            target.isCompleted ||
            target.taskSummary != expected.taskSummary ||
            target.spacedRepetitionLevel <= 0) {
          throw const StaleReminderOccurrenceException();
        }
        final queue = LearningQueueService.queue(
          tasks,
          now: at,
          dailyLimit: dailyLimit,
          newLimit: newLimit,
        );
        if (!queue.items.any(
          (item) => item.key == key && item.task.id == expected.id,
        )) {
          throw const StaleReminderOccurrenceException();
        }
        final all = LearningQueueService.progress(tasks);
        final progress = LearningQueueService.grade(
          all[key],
          grade,
          at,
          target.nextReviewAt ?? target.triggerTime ?? at,
          intervals: intervals,
        );
        all[key] = progress;
        final changed = <Reminder>[];
        for (final task in tasks.where(
          (t) => !t.isCompleted && t.spacedRepetitionLevel > 0,
        )) {
          final words = VocabularyEntry.parseNotes(task.taskSummary ?? '');
          if (!words.any(
            (word) => LearningQueueService.wordKey(word.word) == key,
          )) {
            continue;
          }
          final local = LearningQueueService.decode(task.wordProgressJson)
            ..removeWhere(
              (storedKey, _) => !words.any(
                (word) => LearningQueueService.wordKey(word.word) == storedKey,
              ),
            )
            ..[key] = progress;
          final dates = [
            for (final word in words)
              all[LearningQueueService.wordKey(word.word)]?.due ??
                  task.nextReviewAt ??
                  at,
          ]..sort();
          final due = dates.first;
          final clock = (task.nextReviewAt ?? task.triggerTime ?? at).toLocal();
          final day = at.toLocal();
          final alarm = due.isAfter(at)
              ? due
              : DateTime(
                  day.year,
                  day.month,
                  day.day + 1,
                  clock.hour,
                  clock.minute,
                );
          final next = task.copyWith(
            detailsJson: task.details
                .record(
                  'word_review',
                  at,
                  scheduled: task.nextReviewAt,
                  note: '$key:$grade',
                )
                .encode(),
            wordProgressJson: jsonEncode({
              for (final entry in local.entries)
                entry.key: entry.value.toJson(),
            }),
            nextReviewAt: due,
            triggerTime: task.reviewNotificationsEnabled
                ? alarm
                : task.triggerTime,
            noticeRevision: task.noticeRevision + 1,
            noticeAcknowledgedAt: null,
            upcomingDismissedAt: null,
          );
          await txn.update(
            'Reminders',
            next.toJson(),
            where: 'id = ?',
            whereArgs: [next.id],
          );
          changed.add(next);
        }
        return changed;
      });
      _dbHelper.checkGeneration(ticket);
      _publish(saved);
      var failures = 0;
      for (final task in saved) {
        if (await _synchronizeReminder(task, ticket, cancelOverdue: true)) {
          failures++;
        }
      }
      return ReminderBatchResult(
        changed: saved.length,
        nativeSyncFailures: failures,
      );
    }),
    generation: generation,
  );

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
        !reminder.canNotify ||
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
      _pendingNotificationRetries[id] = DateTime.now();
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

  static DateTime _eventForTrigger(Reminder current, DateTime trigger) {
    final event = current.recurrenceEventAnchorTime ?? current.eventTime!;
    final alarm = current.recurrenceAnchorTime ?? current.triggerTime!;
    final dayOffset = DateTime.utc(
      event.year,
      event.month,
      event.day,
    ).difference(DateTime.utc(alarm.year, alarm.month, alarm.day)).inDays;
    return event.isUtc
        ? DateTime.utc(
            trigger.year,
            trigger.month,
            trigger.day + dayOffset,
            event.hour,
            event.minute,
            event.second,
            event.millisecond,
            event.microsecond,
          )
        : DateTime(
            trigger.year,
            trigger.month,
            trigger.day + dayOffset,
            event.hour,
            event.minute,
            event.second,
            event.millisecond,
            event.microsecond,
          );
  }

  static const _noticeMetadata = {
    'notice_revision',
    'notice_acknowledged_at',
    'upcoming_dismissed_at',
    'snoozed_at',
    'recurrence_anchor_time',
    'recurrence_event_anchor_time',
  };

  static bool _sameTime(DateTime? a, DateTime? b) =>
      a == null ? b == null : b != null && a.isAtSameMomentAs(b);

  static bool _scheduleChanged(Reminder a, Reminder b) =>
      !_sameTime(a.triggerTime, b.triggerTime) ||
      a.isCompleted != b.isCompleted ||
      a.isRecurring != b.isRecurring ||
      a.recurrenceRule != b.recurrenceRule ||
      a.canNotify != b.canNotify ||
      a.details.paused != b.details.paused ||
      a.isVisible != b.isVisible ||
      jsonEncode(a.details.repeat?.toJson()) !=
          jsonEncode(b.details.repeat?.toJson());

  void _publishManaged(Iterable<Reminder> saved) {
    if (!mounted) return;
    final updates = {for (final item in saved) item.id: item};
    state = [
      for (final item in state) updates.remove(item.id) ?? item,
      ...updates.values,
    ];
  }

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

  Future<ReminderActionResult> skipOccurrence(
    Reminder expected, {
    DateTime? now,
  }) => _actOnOccurrences(
    [expected],
    [_ReminderAction.skip],
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
              (!current.isVisible ||
                  current.details.paused ||
                  current.isCompleted ||
                  current.details.kind == 'medicationPlan') ||
              (action == _ReminderAction.skip && !current.isRecurring) ||
              current.occurrenceIdentity != wanted.occurrenceIdentity ||
              (action == _ReminderAction.snooze &&
                  (!current.canNotify ||
                      current.noticeAcknowledgedAt != null)) ||
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
              timeOrigin: snooze
                  ? ReminderTimeOrigin.manual
                  : ReminderTimeOrigin.unknown,
              eventTime:
                  !snooze &&
                      nextTime != null &&
                      current.details.kind == 'departure'
                  ? nextTime.add(
                      Duration(minutes: current.details.data['lead'] as int),
                    )
                  : !snooze &&
                        nextTime != null &&
                        current.eventTime != null &&
                        current.details.repeat != null &&
                        !const {
                          'monthly',
                          'yearly',
                        }.contains(current.recurrenceRule)
                  ? _eventForTrigger(current, nextTime)
                  : !snooze && nextTime != null && current.eventTime != null
                  ? current
                        .copyWith(
                          triggerTime:
                              current.recurrenceEventAnchorTime ??
                              current.eventTime,
                          recurrenceAnchorTime:
                              current.recurrenceEventAnchorTime ??
                              current.eventTime,
                        )
                        .getNextOccurrence(
                          after: current.eventTime!.isAfter(now)
                              ? current.eventTime
                              : now,
                        )
                  : current.eventTime,
              detailsJson:
                  current.detailsJson == null &&
                      current.details.kind == 'task' &&
                      current.details.history.isEmpty
                  ? const TaskDetails()
                        .record(
                          snooze
                              ? 'snoozed'
                              : action == _ReminderAction.skip
                              ? 'skipped'
                              : 'completed',
                          now,
                          scheduled: current.eventTime ?? current.triggerTime,
                        )
                        .patch({
                          'completed_at': nextTime == null
                              ? now.toIso8601String()
                              : null,
                        })
                        .encode()
                  : current.details
                        .record(
                          snooze
                              ? 'snoozed'
                              : action == _ReminderAction.skip
                              ? 'skipped'
                              : current.details.kind == 'medication'
                              ? 'taken'
                              : 'completed',
                          now,
                          scheduled: current.eventTime ?? current.triggerTime,
                        )
                        .patch({
                          'completed_at': nextTime == null
                              ? now.toIso8601String()
                              : null,
                          if (!snooze && current.details.kind == 'medication')
                            'dose_outcome': 'taken',
                          if (!snooze && nextTime != null)
                            'checklist': [
                              for (final item in current.details.checklist)
                                item
                                    .copyWith(done: item.once && item.done)
                                    .toJson(),
                            ],
                        })
                        .encode(),
              isCompleted: nextTime == null,
              isPinned: snooze ? current.isPinned : false,
              noticeRevision: current.noticeRevision + 1,
              noticeAcknowledgedAt: null,
              upcomingDismissedAt: null,
              snoozedAt: snooze ? now : null,
              recurrenceAnchorTime: snooze || nextTime != null
                  ? current.recurrenceAnchorTime ?? current.triggerTime
                  : null,
              recurrenceEventAnchorTime: snooze || nextTime != null
                  ? current.recurrenceEventAnchorTime ?? current.eventTime
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

  Future<ReminderActionResult> trashTask(
    Reminder expected,
    DataGeneration generation,
  ) => _lifecycleResult(expected, 'trash', generation);
  Future<ReminderActionResult> restoreTrashedTask(
    Reminder expected,
    DataGeneration generation,
  ) => _lifecycleResult(expected, 'restore', generation);

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
      if (rows.isNotEmpty) {
        await _archiveLearning(txn, Reminder.fromJson(rows.single));
      }
      await txn.delete('Reminders', where: 'id = ?', whereArgs: [id]);
      return rows.isEmpty ? null : Reminder.fromJson(rows.single);
    });
    _dbHelper.checkGeneration(generation);
    await _loadReminders(generation, runEffects: false);
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
        final rows = (await txn.query('Reminders', where: 'is_completed = 1'))
            .map(Reminder.fromJson)
            .where((row) => row.details.data['learning_archive'] != true)
            .toList();
        for (final row in rows) {
          await _archiveLearning(txn, row);
          await txn.delete('Reminders', where: 'id = ?', whereArgs: [row.id]);
        }
        return rows.map((row) => row.id).toList();
      });
      _dbHelper.checkGeneration(generation);
      await _loadReminders(generation, runEffects: false);
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

  /// Reparse floating local dates and rebuild timers/native requests together.
  /// Propagate read/reconciliation errors so the timezone observer retries.
  Future<void> refreshForTimeZoneChange() => _enqueue(
    (generation) => _loadReminders(generation, startup: true),
    requiresCurrentState: false,
  );
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

  Future<({int attempted, int failed})> apply(bool enabled) {
    final operation = _notificationService.applyFocusMode(enabled);
    state = enabled;
    return operation;
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
