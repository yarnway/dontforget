import 'dart:convert';
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

final String _kDefaultKey = utf8.decode(base64.decode('c2stZDdmZmNiNTAzMGMzNDI5OGExZTQ3NDEzN2JmODNmYjk='));

class SettingsNotifier extends StateNotifier<AppSettings> {
  final DatabaseHelper _dbHelper;

  SettingsNotifier(this._dbHelper) : super(AppSettings(
    id: 'default',
    apiKey: _kDefaultKey,
    baseUrl: 'https://api.deepseek.com',
    modelName: 'deepseek-v4-flash-vision-exp',
    language: 'zh',
  )) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final db = await _dbHelper.database;
      final res = await db.query('Settings', where: 'id = ?', whereArgs: ['default']);
      if (res.isNotEmpty) {
        var loadedSettings = AppSettings.fromJson(res.first);
        // Migrate old deepseek model name if present
        if (loadedSettings.baseUrl.contains('deepseek.com') &&
            (loadedSettings.modelName == 'deepseek-v4-flash' || loadedSettings.modelName.isEmpty)) {
          loadedSettings = loadedSettings.copyWith(
            apiKey: _kDefaultKey,
            baseUrl: 'https://api.deepseek.com',
            modelName: 'deepseek-v4-flash-vision-exp',
          );
          await updateSettings(loadedSettings);
        }
        state = loadedSettings;
      } else {
        // If no settings exist yet, insert the default
        final defaultSettings = AppSettings(
          id: 'default',
          apiKey: _kDefaultKey,
          baseUrl: 'https://api.deepseek.com',
          modelName: 'deepseek-v4-flash-vision-exp',
          language: 'zh',
        );
        await db.insert('Settings', defaultSettings.toJson());
        state = defaultSettings;
      }
    } catch (e, stack) {
      // Fallback gracefully to default in-memory state on any storage issue
      debugPrint('Warning: Settings storage error: $e\n$stack');
    }
  }

  Future<void> updateSettings(AppSettings newSettings) async {
    try {
      final db = await _dbHelper.database;
      await db.update(
        'Settings',
        newSettings.toJson(),
        where: 'id = ?',
        whereArgs: ['default'],
      );
    } catch (e) {
      debugPrint('Warning: updateSettings storage error: $e');
    }
    state = newSettings;
  }
}

final remindersProvider = StateNotifierProvider<RemindersNotifier, List<Reminder>>((ref) {
  return RemindersNotifier(ref.read(databaseHelperProvider));
});

class RemindersNotifier extends StateNotifier<List<Reminder>> {
  final DatabaseHelper _dbHelper;

  RemindersNotifier(this._dbHelper) : super([]) {
    _loadReminders();
  }

  Future<void> _loadReminders() async {
    try {
      final db = await _dbHelper.database;
      final res = await db.query('Reminders');
      final list = res.map((r) => Reminder.fromJson(r)).toList();
      state = list;
      final now = DateTime.now();
      for (final reminder in list) {
        if (!reminder.isCompleted && reminder.triggerTime != null && reminder.triggerTime!.isAfter(now)) {
          NotificationService().scheduleReminder(reminder);
        }
      }
      // 启动时自动执行 Q2 动态跃迁扫描
      await scanAndApplyDynamicUrgency();
    } catch (e, stack) {
      debugPrint('Warning: Reminders load error: $e\n$stack');
      state = [];
    }
  }

  Future<void> addReminder(Reminder reminder) async {
    final db = await _dbHelper.database;
    Reminder toAdd = reminder;

    // 智能双向链接发现：若新任务未指定关联项，自动与语义相关度高的历史任务建立双向互联
    if (toAdd.linkedTaskIds.isEmpty && state.isNotEmpty) {
      final suggestedIds = const BiDirectionalLinkService().findSuggestedLinkedIds(toAdd, state);
      if (suggestedIds.isNotEmpty) {
        toAdd = toAdd.copyWith(linkedTaskIds: suggestedIds);
        // 对被推荐的历史任务也反向添加当前任务 ID
        for (final otherId in suggestedIds) {
          final idx = state.indexWhere((r) => r.id == otherId);
          if (idx != -1) {
            final other = state[idx];
            if (!other.linkedTaskIds.contains(toAdd.id)) {
              final updatedOther = other.copyWith(
                linkedTaskIds: [...other.linkedTaskIds, toAdd.id],
              );
              await db.update('Reminders', updatedOther.toJson(), where: 'id = ?', whereArgs: [other.id]);
              state = [
                for (final r in state)
                  if (r.id == other.id) updatedOther else r
              ];
            }
          }
        }
      }
    }

    await db.insert('Reminders', toAdd.toJson());
    state = [...state, toAdd];
  }

  Future<void> updateReminder(Reminder reminder) async {
    final db = await _dbHelper.database;
    await db.update('Reminders', reminder.toJson(), where: 'id = ?', whereArgs: [reminder.id]);
    state = [
      for (final r in state)
        if (r.id == reminder.id) reminder else r
    ];
  }

  Future<void> linkTwoTasks(String id1, String id2) async {
    if (id1 == id2) return;
    final idx1 = state.indexWhere((r) => r.id == id1);
    final idx2 = state.indexWhere((r) => r.id == id2);
    if (idx1 == -1 || idx2 == -1) return;

    final db = await _dbHelper.database;
    final task1 = state[idx1];
    final task2 = state[idx2];

    Reminder? new1;
    Reminder? new2;

    if (!task1.linkedTaskIds.contains(id2)) {
      new1 = task1.copyWith(linkedTaskIds: [...task1.linkedTaskIds, id2]);
      await db.update('Reminders', new1.toJson(), where: 'id = ?', whereArgs: [id1]);
    }
    if (!task2.linkedTaskIds.contains(id1)) {
      new2 = task2.copyWith(linkedTaskIds: [...task2.linkedTaskIds, id1]);
      await db.update('Reminders', new2.toJson(), where: 'id = ?', whereArgs: [id2]);
    }

    state = [
      for (final r in state)
        if (r.id == id1 && new1 != null)
          new1
        else if (r.id == id2 && new2 != null)
          new2
        else
          r
    ];
  }

  Future<void> unlinkTwoTasks(String id1, String id2) async {
    final idx1 = state.indexWhere((r) => r.id == id1);
    final idx2 = state.indexWhere((r) => r.id == id2);

    final db = await _dbHelper.database;
    Reminder? new1;
    Reminder? new2;

    if (idx1 != -1) {
      final task1 = state[idx1];
      if (task1.linkedTaskIds.contains(id2)) {
        new1 = task1.copyWith(
          linkedTaskIds: task1.linkedTaskIds.where((id) => id != id2).toList(),
        );
        await db.update('Reminders', new1.toJson(), where: 'id = ?', whereArgs: [id1]);
      }
    }
    if (idx2 != -1) {
      final task2 = state[idx2];
      if (task2.linkedTaskIds.contains(id1)) {
        new2 = task2.copyWith(
          linkedTaskIds: task2.linkedTaskIds.where((id) => id != id1).toList(),
        );
        await db.update('Reminders', new2.toJson(), where: 'id = ?', whereArgs: [id2]);
      }
    }

    state = [
      for (final r in state)
        if (r.id == id1 && new1 != null)
          new1
        else if (r.id == id2 && new2 != null)
          new2
        else
          r
    ];
  }

  /// 扫描待办列表，自动执行 Q2 -> Q1 动态跃迁
  Future<int> scanAndApplyDynamicUrgency() async {
    const dynamicService = DynamicUrgencyService();
    final updatedList = dynamicService.evaluatePromotions(state);
    int promotedCount = 0;

    final db = await _dbHelper.database;
    for (int i = 0; i < updatedList.length; i++) {
      final updated = updatedList[i];
      final original = state[i];
      if (updated.quadrantLevel != original.quadrantLevel && updated.isDynamicallyPromoted) {
        promotedCount++;
        await db.update('Reminders', updated.toJson(), where: 'id = ?', whereArgs: [updated.id]);
      }
    }

    if (promotedCount > 0) {
      state = updatedList;
    }
    return promotedCount;
  }

  Future<void> deleteReminder(String id) async {
    final db = await _dbHelper.database;
    await db.delete('Reminders', where: 'id = ?', whereArgs: [id]);
    state = state.where((r) => r.id != id).toList();
  }

  Future<int> clearCompletedReminders() async {
    final db = await _dbHelper.database;
    final count = await db.delete('Reminders', where: 'is_completed = 1');
    state = state.where((r) => !r.isCompleted).toList();
    return count;
  }

  Future<void> refreshReminders() async {
    await _loadReminders();
  }
}

final mediaRecordsProvider = StateNotifierProvider<MediaRecordsNotifier, List<MediaRecord>>((ref) {
  return MediaRecordsNotifier(ref.read(databaseHelperProvider));
});

class MediaRecordsNotifier extends StateNotifier<List<MediaRecord>> {
  final DatabaseHelper _dbHelper;

  MediaRecordsNotifier(this._dbHelper) : super([]);

  Future<void> addRecord(MediaRecord record) async {
    final db = await _dbHelper.database;
    await db.insert('MediaRecords', record.toJson());
    state = [...state, record];
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
    state = profile;
  }
}

final contextProfileProvider = StateNotifierProvider<ContextProfileNotifier, ContextProfile>((ref) {
  return ContextProfileNotifier(ref.read(contextTriggerServiceProvider));
});

