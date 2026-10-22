// Isolated local journal measurements, not OS notification or UI timings.
import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_journal.dart';

const usage =
    '''Usage: dart run scripts/benchmark_notification_journal.dart [--samples N]

Measures synthetic journals with 100, 1000 and 10000 records.
--samples N  Measured runs per size (3..30, default 7); two warmups precede each.
--help       Print this help without creating files.

Uses a new temporary directory and removes only that directory on completion.
No user database, platform notification service, credentials or recordings are accessed.
Output: JSON with journal bytes, read/status timings, an eight-record cancel
journal roundtrip (pending + submitted), p50/p95 in microseconds, and process RSS.
These are Dart JIT filesystem/CPU samples, not startup, delivery or frame timings.
''';

Future<Map<String, int>> measure(
  int samples,
  Future<void> Function() work,
) async {
  for (var i = 0; i < 2; i++) {
    await work();
  }
  final times = <int>[];
  for (var i = 0; i < samples; i++) {
    final watch = Stopwatch()..start();
    await work();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return {
    'p50_us': times[(samples * .5).ceil() - 1],
    'p95_us': times[(samples * .95).ceil() - 1],
  };
}

Future<void> main(List<String> args) async {
  var samples = 7;
  if (args.length == 1 && args.single == '--help') {
    stdout.write(usage);
    return;
  }
  if (args.isNotEmpty) {
    final parsed = args.length == 2 && args[0] == '--samples'
        ? int.tryParse(args[1])
        : null;
    if (parsed == null || parsed < 3 || parsed > 30) {
      stderr.write(usage);
      exitCode = 64;
      return;
    }
    samples = parsed;
  }
  final temporary = await Directory.systemTemp.createTemp(
    'dontforget-journal-bench-',
  );
  final root = Directory(await temporary.resolveSymbolicLinks());
  const epoch = '00000000-0000-4000-8000-000000000001';
  final now = DateTime.utc(2026, 10, 22);
  final results = <Map<String, Object>>[];
  try {
    for (final count in [100, 1000, 10000]) {
      final directory = await Directory('${root.path}/$count').create();
      final reminders = List.generate(
        count,
        (i) => Reminder(
          id: 'synthetic-$i',
          taskTitle: 'Synthetic task $i',
          quadrantLevel: 3,
          triggerTime: now.add(const Duration(days: 1)),
        ),
      );
      final entries = <String, NotificationJournalEntry>{
        for (var i = 0; i < count; i++)
          reminders[i].id: NotificationJournalEntry(
            reminderId: reminders[i].id,
            nativeId: i + 1,
            action: 'schedule',
            status: 'submitted',
            attempts: 1,
            triggerUtcMicros: reminders[i].triggerTime!.microsecondsSinceEpoch,
            noticeRevision: 0,
            attemptedAt: now.toIso8601String(),
          ),
      };
      // Preallocated fixture avoids measuring quadratic ID seeding as setup.
      final file = File('${directory.path}/${NotificationJournal.fileName}');
      await file.writeAsString(
        jsonEncode(NotificationJournalSnapshot(epoch, entries).toJson()),
        flush: true,
      );
      final journal = NotificationJournal(directory);
      final read = await measure(samples, () async {
        if ((await journal.read())!.entries.length != count) {
          throw StateError('Journal count changed');
        }
      });
      final status = await measure(samples, () async {
        final snapshot = (await journal.read())!;
        final summary = NotificationScheduleStatus.fromSaved(
          reminders,
          snapshot.entries,
          now,
        );
        if (summary.upcoming != count || summary.submitted != count) {
          throw StateError('Unexpected status summary');
        }
      });
      final batch = await measure(samples, () async {
        for (final reminder in reminders.take(8)) {
          for (final status in ['pending', 'submitted']) {
            await journal.record(
              epoch,
              reminder.id,
              action: 'cancel',
              status: status,
              attemptedAt: now,
            );
          }
        }
      });
      results.add({
        'records': count,
        'journal_bytes': await file.length(),
        'read': read,
        'read_and_summary': status,
        'eight_cancel_journal_roundtrips': batch,
        'process_rss_bytes_after_size': ProcessInfo.currentRss,
      });
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'scope':
            'Synthetic local journal only; no SQLite, native calls, startup or frames',
        'runtime': Platform.version,
        'os': Platform.operatingSystemVersion,
        'warmups': 2,
        'samples': samples,
        'results': results,
      }),
    );
  } finally {
    await root.delete(recursive: true);
  }
}
