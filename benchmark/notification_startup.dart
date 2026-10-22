// The database, journal, providers and timers are real. Only the OS transport
// is replaced: never submit thousands of synthetic notifications to macOS.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class RecordingNotificationTransport
    implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
  int cancellations = 0;
  int schedules = 0;
  int resets = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #initialize:
        return Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        return Future.value(const NotificationAppLaunchDetails(false));
      case #cancelAll:
        resets++;
        pending.clear();
        return Future<void>.value();
      case #cancel:
        cancellations++;
        pending.remove(invocation.positionalArguments.first as int);
        return Future<void>.value();
      case #zonedSchedule:
        schedules++;
        pending[invocation.positionalArguments.first as int] =
            invocation.namedArguments[#payload] as String;
        return Future<void>.value();
      default:
        throw UnsupportedError('${invocation.memberName}');
    }
  }
}

Future<List<Map<String, Object>>> measureNotificationStartup(
  Directory directory,
  List<Reminder> tasks,
) async {
  await directory.create();
  final seed = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
  try {
    final db = await seed.database;
    final batch = db.batch();
    for (final task in tasks) {
      batch.insert('Reminders', task.toJson());
    }
    await batch.commit(noResult: true);
  } finally {
    await seed.close(createBackup: false);
  }
  final transport = RecordingNotificationTransport();
  final results = <Map<String, Object>>[];
  Map<String, int>? previousIds;
  for (final mode in ['new_journal', 'reopen_submitted_journal']) {
    final helper = DatabaseHelper.forTesting(
      directory.path,
      databaseFactoryFfi,
    );
    final service = NotificationService.forTesting(
      transport,
      usesNativeNotifications: true,
      database: helper,
    );
    final watch = Stopwatch()..start();
    final container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(helper),
        remindersProvider.overrideWith(
          (_) => RemindersNotifier(helper, notifications: service),
        ),
      ],
    );
    try {
      await Future.wait([
        container.read(settingsProvider.notifier).ready,
        container.read(remindersProvider.notifier).ready,
      ]);
      watch.stop();
      final snapshot = (await helper.withNotificationJournal((j) => j.read()))!;
      if (snapshot.entries.length != tasks.length ||
          transport.pending.length != tasks.length ||
          snapshot.entries.values.any(
            (entry) =>
                entry.status != 'submitted' || entry.action != 'schedule',
          )) {
        throw StateError('Incomplete startup notification reconciliation');
      }
      final ids = {
        for (final entry in snapshot.entries.values)
          entry.reminderId: entry.nativeId,
      };
      if (previousIds != null &&
          ids.entries.any((e) => previousIds![e.key] != e.value)) {
        throw StateError('Notification ID changed across reopen');
      }
      previousIds = ids;
      final writes = await helper.withNotificationJournal(
        (journal) async => journal.writeStatistics,
      );
      results.add({
        'mode': mode,
        'elapsed_us': watch.elapsedMicroseconds,
        'scope':
            'Full provider.ready including real SQL, urgency, journal, '
            'ID allocation and timers; recording OS transport, no OS delivery',
        'tasks': tasks.length,
        'journal_entries': snapshot.entries.length,
        'native_schedule_calls': transport.schedules,
        'native_cancel_calls': transport.cancellations,
        'native_reset_calls': transport.resets,
        'journal_atomic_replacements': writes.replacements,
        'journal_bytes_written': writes.bytes,
        'journal_successful_write_us': writes.elapsedMicros,
      });
    } finally {
      // Emulate process exit: stop timers, retain the OS model and journal.
      final retained = Map<int, String>.of(transport.pending);
      await service.pauseForMaintenance();
      transport.pending.addAll(retained);
      container.dispose();
      await helper.close(createBackup: false);
      transport.cancellations = transport.schedules = transport.resets = 0;
    }
  }
  return results;
}
