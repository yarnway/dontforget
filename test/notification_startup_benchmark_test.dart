import 'dart:io';

import 'package:dont_forget/models/reminder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../benchmark/notification_startup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'startup measurement includes durable scheduling and ID-preserving reopen',
    () async {
      sqfliteFfiInit();
      final root = await Directory.systemTemp.createTemp(
        'startup-profile-test-',
      );
      try {
        final results = await measureNotificationStartup(root, [
          for (var i = 0; i < 12; i++)
            Reminder(
              id: 'task-$i',
              taskTitle: 'Synthetic $i',
              quadrantLevel: i % 4 + 1,
              createdAt: DateTime.utc(2026, 10, 22),
              triggerTime: DateTime.utc(2099, 1, 1),
            ),
        ]);
        expect(results.length, 3);
        for (final result in results) {
          expect(result['journal_entries'], 12);
          expect(result['native_schedule_calls'], 12);
          expect(result['native_cancel_calls'], 12);
          expect(result['elapsed_us'], greaterThan(0));
        }
        expect(results.first['native_reset_calls'], 1);
        expect(results[1]['native_reset_calls'], 0);
        expect(results.last['mode'], 'maintenance_rebuild');
        expect(results.last['native_reset_calls'], 2);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
