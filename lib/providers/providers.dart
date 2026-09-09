import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/database_helper.dart';
import '../models/settings.dart';
import '../models/reminder.dart';
import '../models/media_record.dart';
import '../services/llm_service.dart';
import '../services/notification_service.dart';

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
  }

  Future<void> updateSettings(AppSettings newSettings) async {
    final db = await _dbHelper.database;
    await db.update(
      'Settings',
      newSettings.toJson(),
      where: 'id = ?',
      whereArgs: ['default'],
    );
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
  }

  Future<void> addReminder(Reminder reminder) async {
    final db = await _dbHelper.database;
    await db.insert('Reminders', reminder.toJson());
    state = [...state, reminder];
  }

  Future<void> updateReminder(Reminder reminder) async {
    final db = await _dbHelper.database;
    await db.update('Reminders', reminder.toJson(), where: 'id = ?', whereArgs: [reminder.id]);
    state = [
      for (final r in state)
        if (r.id == reminder.id) reminder else r
    ];
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
