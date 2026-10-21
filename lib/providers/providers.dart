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

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier(ref.read(databaseHelperProvider));
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  final DatabaseHelper _dbHelper;
  late final Future<void> ready;

  SettingsNotifier(this._dbHelper) : super(AppSettings.defaults()) {
    ready = _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final db = await _dbHelper.database;
      final res = await db.query('Settings', where: 'id = ?', whereArgs: ['default']);
      if (res.isNotEmpty && mounted) {
        state = AppSettings.fromJson(res.first);
      }
    } catch (_) {
      debugPrint('Settings could not be loaded; using unconfigured defaults.');
    }
  }

  Future<void> updateSettings(AppSettings newSettings) async {
    // Do not allow a delayed startup read to overwrite a user's saved values.
    await ready;
    final db = await _dbHelper.database;
    final saved = newSettings.copyWith();
    await db.transaction((txn) async {
      await txn.delete('Settings', where: 'id = ?', whereArgs: ['default']);
      await txn.insert('Settings', {...saved.toJson(), 'id': 'default'});
    });
    if (mounted) state = AppSettings.fromJson({...saved.toJson(), 'id': 'default'});
  }
}

final remindersProvider = StateNotifierProvider<RemindersNotifier, List<Reminder>>((ref) {
  return RemindersNotifier(ref.read(databaseHelperProvider));
});

class RemindersNotifier extends StateNotifier<List<Reminder>> {
  final DatabaseHelper _dbHelper;
  late final Future<void> ready;
  Future<void> _operations = Future<void>.value();

  RemindersNotifier(this._dbHelper) : super([]) {
    ready = _enqueue(_loadReminders);
  }

  // Startup reads, refreshes and mutations share one order. A failed operation
  // reaches its caller but does not prevent the next operation from running.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _loadReminders() async {
    try {
      final db = await _dbHelper.database;
      final res = await db.query('Reminders');
      if (!mounted) return;
      final list = res.map((r) => Reminder.fromJson(r)).toList();
      state = list;
      final now = DateTime.now();
      for (final reminder in list) {
        if (!reminder.isCompleted &&
            reminder.triggerTime != null &&
            reminder.triggerTime!.isAfter(now)) {
          NotificationService().scheduleReminder(reminder);
        }
      }
      // Already inside the queue: do not enqueue and await ourselves.
      await _applyDynamicUrgency();
    } catch (e, stack) {
      // A failed refresh or promotion must not erase already loaded tasks.
      if (mounted) debugPrint('Warning: Reminders load error: $e\n$stack');
    }
  }

  Future<void> addReminder(Reminder reminder) => _enqueue(() async {
    final db = await _dbHelper.database;
    if (!mounted) return;
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

    await db.transaction((txn) async {
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
    if (mounted) {
      state = [for (final item in state) replacements[item.id] ?? item, toAdd];
    }
  });

  Future<void> updateReminder(Reminder reminder) {
    // Capture the requested field changes before waiting. This preserves an
    // unrelated edit or promotion committed by an earlier queued operation.
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
    return _enqueue(() async {
      final db = await _dbHelper.database;
      if (!mounted || changes.isEmpty) return;
      final matches = state.where((item) => item.id == reminder.id);
      if (matches.isEmpty) return;
      final updated = Reminder.fromJson({
        ...matches.first.toJson(),
        ...changes,
      });
      final count = await db.update(
        'Reminders',
        changes,
        where: 'id = ?',
        whereArgs: [reminder.id],
      );
      if (mounted && count > 0) {
        state = [
          for (final item in state)
            if (item.id == reminder.id) updated else item,
        ];
      }
    });
  }

  Future<void> linkTwoTasks(String id1, String id2) => _enqueue(() async {
    if (id1 == id2) return;
    final db = await _dbHelper.database;
    if (!mounted) return;
    final byId = {for (final item in state) item.id: item};
    final task1 = byId[id1];
    final task2 = byId[id2];
    if (task1 == null || task2 == null) return;
    final replacements = <String, Reminder>{
      if (!task1.linkedTaskIds.contains(id2))
        id1: task1.copyWith(linkedTaskIds: [...task1.linkedTaskIds, id2]),
      if (!task2.linkedTaskIds.contains(id1))
        id2: task2.copyWith(linkedTaskIds: [...task2.linkedTaskIds, id1]),
    };
    await db.transaction((txn) async {
      for (final item in replacements.values) {
        await txn.update(
          'Reminders',
          {'linked_task_ids': item.toJson()['linked_task_ids']},
          where: 'id = ?',
          whereArgs: [item.id],
        );
      }
    });
    if (mounted && replacements.isNotEmpty) {
      state = [for (final item in state) replacements[item.id] ?? item];
    }
  });

  Future<void> unlinkTwoTasks(String id1, String id2) => _enqueue(() async {
    final db = await _dbHelper.database;
    if (!mounted) return;
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
    await db.transaction((txn) async {
      for (final item in replacements.values) {
        await txn.update(
          'Reminders',
          {'linked_task_ids': item.toJson()['linked_task_ids']},
          where: 'id = ?',
          whereArgs: [item.id],
        );
      }
    });
    if (mounted && replacements.isNotEmpty) {
      state = [for (final item in state) replacements[item.id] ?? item];
    }
  });

  Future<int> scanAndApplyDynamicUrgency() => _enqueue(_applyDynamicUrgency);

  Future<int> _applyDynamicUrgency() async {
    if (!mounted) return 0;
    final original = state;
    final updatedList = const DynamicUrgencyService().evaluatePromotions(
      original,
    );
    if (identical(updatedList, original)) return 0;
    final promoted = [
      for (var i = 0; i < updatedList.length; i++)
        if (!identical(updatedList[i], original[i])) updatedList[i],
    ];
    final db = await _dbHelper.database;
    if (!mounted) return 0;
    await db.transaction((txn) async {
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
    if (mounted) state = updatedList;
    return promoted.length;
  }

  Future<void> deleteReminder(String id) => _enqueue(() async {
    final db = await _dbHelper.database;
    if (!mounted) return;
    await db.delete('Reminders', where: 'id = ?', whereArgs: [id]);
    if (mounted) state = state.where((r) => r.id != id).toList();
  });

  Future<int> clearCompletedReminders() => _enqueue(() async {
    final db = await _dbHelper.database;
    if (!mounted) return 0;
    final count = await db.delete('Reminders', where: 'is_completed = 1');
    if (mounted) state = state.where((r) => !r.isCompleted).toList();
    return count;
  });

  Future<void> refreshReminders() => _enqueue(_loadReminders);
}

final mediaRecordsProvider = StateNotifierProvider<MediaRecordsNotifier, List<MediaRecord>>((ref) {
  return MediaRecordsNotifier(ref.read(databaseHelperProvider));
});

class MediaRecordsNotifier extends StateNotifier<List<MediaRecord>> {
  final DatabaseHelper _dbHelper;
  late final Future<void> ready;

  MediaRecordsNotifier(this._dbHelper) : super([]) {
    ready = _loadRecords();
  }

  Future<void> _loadRecords() async {
    try {
      final db = await _dbHelper.database;
      final rows = await db.query('MediaRecords');
      if (mounted) state = rows.map(MediaRecord.fromJson).toList();
    } catch (error) {
      debugPrint('Media records could not be loaded: $error');
    }
  }

  Future<void> addRecord(MediaRecord record) async {
    // A late startup read must not replace a newly captured attachment.
    await ready;
    final db = await _dbHelper.database;
    await db.insert('MediaRecords', record.toJson());
    if (mounted) state = [...state, record];
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

final spacedRepetitionServiceProvider = Provider<SpacedRepetitionService>((ref) {
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

final immersiveModeProvider = StateNotifierProvider<ImmersiveModeNotifier, bool>((ref) {
  return ImmersiveModeNotifier(ref.read(notificationServiceProvider));
});

final dynamicUrgencyServiceProvider = Provider<DynamicUrgencyService>((ref) {
  return const DynamicUrgencyService();
});

final biDirectionalLinkServiceProvider = Provider<BiDirectionalLinkService>((ref) {
  return const BiDirectionalLinkService();
});

final contextTriggerServiceProvider = Provider<ContextTriggerService>((ref) {
  return ContextTriggerService();
});

class ContextProfileNotifier extends StateNotifier<ContextProfile> {
  final ContextTriggerService _service;
  ContextProfileNotifier(this._service) : super(_service.currentProfile);

  void setProfile(ContextProfile profile) {
    _service.switchProfile(profile);
    NotificationService().reconcileNotificationPolicy();
    state = profile;
  }
}

final contextProfileProvider = StateNotifierProvider<ContextProfileNotifier, ContextProfile>((ref) {
  return ContextProfileNotifier(ref.read(contextTriggerServiceProvider));
});

