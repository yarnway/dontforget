import 'dart:async';
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
      );
    });

class RemindersNotifier extends StateNotifier<List<Reminder>> {
  final DatabaseHelper _dbHelper;
  final NotificationService _notifications;
  late final Future<void> ready;
  Future<void> _operations = Future<void>.value();
  DataGeneration? _stateGeneration;

  RemindersNotifier(this._dbHelper, {NotificationService? notifications})
    : _notifications = notifications ?? NotificationService(),
      super([]) {
    ready = _enqueue(
      (generation) => _loadReminders(generation, startup: true),
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
      _stateGeneration = generation;
      state = list;
      final now = DateTime.now();
      for (final reminder in list) {
        _dbHelper.checkGeneration(generation);
        if (!mounted) {
          return;
        }
        if (!reminder.isCompleted &&
            reminder.triggerTime != null &&
            reminder.triggerTime!.isAfter(now)) {
          await _dbHelper.runOperation(generation, () async {
            _dbHelper.checkGeneration(generation);
            await _notifications.scheduleReminder(reminder);
          });
        }
      }
      await _applyDynamicUrgency(generation);
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

  Future<void> addReminder(Reminder reminder) async {
    final generation = _dbHelper.captureGeneration();
    await addReminderForGeneration(reminder, generation);
  }

  Future<void> addReminderForGeneration(
    Reminder reminder,
    DataGeneration generation,
  ) => _enqueue((ticket) async {
    if (!mounted) {
      return;
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
      state = [for (final item in state) replacements[item.id] ?? item, toAdd];
    }
  }, generation: generation);

  Future<void> updateReminder(Reminder reminder) async {
    final generation = _dbHelper.captureGeneration();
    await updateReminderForGeneration(reminder, generation);
  }

  Future<void> updateReminderForGeneration(
    Reminder reminder,
    DataGeneration generation,
  ) async {
    _dbHelper.checkGeneration(generation);
    if (_stateGeneration != null) {
      _dbHelper.checkGeneration(_stateGeneration!);
    }
    // Preserve field changes requested before waiting behind another edit.
    final changes = reminder.toJson()..remove('id');
    if (mounted) {
      for (final existing in state) {
        if (existing.id == reminder.id) {
          final before = existing.toJson();
          changes.removeWhere((key, value) => before[key] == value);
          break;
        }
      }
    }
    await _enqueue((ticket) async {
      if (!mounted || changes.isEmpty) {
        return;
      }
      final matches = state.where((item) => item.id == reminder.id);
      if (matches.isEmpty) {
        return;
      }
      final updated = Reminder.fromJson({
        ...matches.first.toJson(),
        ...changes,
      });
      final count = await _dbHelper.writeTransaction(
        ticket,
        (txn) => txn.update(
          'Reminders',
          changes,
          where: 'id = ?',
          whereArgs: [reminder.id],
        ),
      );
      _dbHelper.checkGeneration(ticket);
      if (mounted && count > 0) {
        state = [
          for (final item in state)
            if (item.id == reminder.id) updated else item,
        ];
      }
    }, generation: generation);
  }

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

  Future<int> scanAndApplyDynamicUrgency() => _enqueue(_applyDynamicUrgency);

  Future<int> _applyDynamicUrgency(DataGeneration generation) async {
    _dbHelper.checkGeneration(generation);
    if (!mounted) {
      return 0;
    }
    final original = state;
    final updatedList = const DynamicUrgencyService().evaluatePromotions(
      original,
    );
    if (identical(updatedList, original)) {
      return 0;
    }
    final promoted = [
      for (var i = 0; i < updatedList.length; i++)
        if (!identical(updatedList[i], original[i])) updatedList[i],
    ];
    await _dbHelper.writeTransaction(generation, (txn) async {
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
    });
    _dbHelper.checkGeneration(generation);
    if (mounted) {
      state = updatedList;
    }
    return promoted.length;
  }

  Future<void> deleteReminder(String id) => _enqueue((generation) async {
    await _deleteReminder(id, generation);
  });

  Future<void> deleteReminderForGeneration(
    String id,
    DataGeneration generation,
  ) =>
      _enqueue((ticket) => _deleteReminder(id, ticket), generation: generation);

  Future<void> _deleteReminder(String id, DataGeneration generation) async {
    if (!mounted) {
      return;
    }
    await _dbHelper.writeTransaction(
      generation,
      (txn) => txn.delete('Reminders', where: 'id = ?', whereArgs: [id]),
    );
    _dbHelper.checkGeneration(generation);
    if (mounted) {
      state = state.where((r) => r.id != id).toList();
    }
  }

  Future<int> clearCompletedReminders() => _enqueue((generation) async {
    if (!mounted) {
      return 0;
    }
    final count = await _dbHelper.writeTransaction(
      generation,
      (txn) => txn.delete('Reminders', where: 'is_completed = 1'),
    );
    _dbHelper.checkGeneration(generation);
    if (mounted) {
      state = state.where((r) => !r.isCompleted).toList();
    }
    return count;
  });

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
  return LLMService();
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

final lanSyncServiceProvider = Provider<LanSyncService>((ref) {
  return LanSyncService.instance;
});

final dpSchedulerServiceProvider = Provider<DPSchedulerService>((ref) {
  return const DPSchedulerService();
});

final multiAgentServiceProvider = Provider<MultiAgentService>((ref) {
  return MultiAgentService(
    llmService: ref.read(llmServiceProvider),
    dpScheduler: ref.read(dpSchedulerServiceProvider),
  );
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
