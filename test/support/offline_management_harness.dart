import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class OfflineTestNotifications implements NotificationService {
  final scheduled = <String>[], cancelled = <String>[];
  bool fail = false;
  @override
  bool get isPausedForMaintenance => false;
  @override
  Future<void> scheduleReminderStrict(Reminder task) async {
    if (fail) throw StateError('Synthetic notification failure');
    scheduled.add(task.id);
  }

  @override
  Future<void> cancelReminderStrict(String id) async {
    if (fail) throw StateError('Synthetic notification failure');
    cancelled.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfflineManagementHarness {
  OfflineManagementHarness({this.model});
  final LLMService? model;
  late final Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late OfflineTestNotifications notifications;
  RemindersNotifier get notifier => container.read(remindersProvider.notifier);
  Future<void> create() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'dontforget-offline-management-',
    );
    await open();
  }

  Future<void> open() async {
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = OfflineTestNotifications();
    container = ProviderContainer(
      overrides: [
        if (model != null) llmServiceProvider.overrideWithValue(model!),
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        remindersProvider.overrideWith(
          (_) => RemindersNotifier(
            database,
            notifications: notifications,
            runLoadEffects: false,
          ),
        ),
        routineScheduleStatusReaderProvider.overrideWith(
          (ref) =>
              (planId) async => NotificationScheduleStatus.fromSaved(
                ref.read(remindersProvider),
                {},
                DateTime.now(),
                nativePendingLimit: 50,
                planId: planId,
              ),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await notifier.ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
  }

  Future<void> close() async {
    // Widget tests drain writes inside their fake-clock body. Awaiting a
    // completed fake-zone Future again from real-time teardown can deadlock.
    container.dispose();
    await database.close(createBackup: false);
  }

  Future<void> dispose() async {
    await close();
    await directory.delete(recursive: true);
  }

  Future<void> seed(Reminder row) async {
    await notifier.addReminderForGeneration(row, database.captureGeneration());
  }

  Future<List<Reminder>> rows() async => (await database.read(
    database.captureGeneration(),
    (db) => db.query('Reminders'),
  )).map(Reminder.fromJson).toList();
  Future<Reminder> row(String id) async =>
      (await rows()).singleWhere((e) => e.id == id);
  Future<String?> drafts() async =>
      (await database.read(
            database.captureGeneration(),
            (db) => db.query('Settings'),
          )).single['workspace_drafts_json']
          as String?;
}
