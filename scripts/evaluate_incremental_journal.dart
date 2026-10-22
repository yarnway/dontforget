// Run with the pinned Dart SDK. Uses only a new temporary directory.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dont_forget/services/notification_journal.dart';
import '../benchmark/incremental_journal_experiment.dart';

const usage =
    '''Usage: dart run scripts/evaluate_incremental_journal.dart --fixture PATH
Reads a closed synthetic ha_snapshot.json (10000 tasks), preserving its rows.
Compares v1 replacement and an evaluation-only append log using identical
256-entry pending/submitted batches, once empty and once already submitted.
Output is JSON on stdout. No OS notification or application data is changed.
--help prints this help; no files are created until arguments/fixture validate.
''';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--help') {
    stdout.write(usage);
    return;
  }
  if (args.length != 2 || args.first != '--fixture') {
    stderr.write(usage);
    exitCode = 64;
    return;
  }
  final fixtureBytes = await File(args[1]).readAsBytes();
  final rows =
      (jsonDecode(utf8.decode(fixtureBytes)) as Map)['reminders'] as List;
  if (rows.length != 10000 ||
      rows.asMap().entries.any((e) => e.value['id'] != 'synthetic-${e.key}')) {
    throw StateError('Expected ordered synthetic 10000-task fixture');
  }
  const epoch = '00000000-0000-4000-8000-000000000001';
  final now = DateTime.utc(2026, 10, 22);
  final root = Directory(
    await (await Directory.systemTemp.createTemp(
      'dontforget-log-experiment-',
    )).resolveSymbolicLinks(),
  );
  final reports = <Map<String, Object>>[];
  try {
    final currentDir = await Directory('${root.path}/current').create();
    final experimentDir = await Directory('${root.path}/experiment').create();
    var current = NotificationJournal(currentDir);
    var experiment = IncrementalJournalExperiment(experimentDir);
    await current.reset(epoch);
    await experiment.checkpoint(NotificationJournalSnapshot(epoch, {}));
    for (final mode in ['first', 'reopen']) {
      current = NotificationJournal(currentDir);
      experiment = IncrementalJournalExperiment(experimentDir);
      final open = Stopwatch()..start();
      await experiment.open();
      final replayMicros = open.elapsedMicroseconds;
      final batches = <List<NotificationJournalEntry>>[];
      final watch = Stopwatch()..start();
      for (var offset = 0; offset < rows.length; offset += 256) {
        final chunk = rows.sublist(offset, math.min(offset + 256, rows.length));
        final pending = await Future.wait([
          for (final row in chunk)
            current.begin(
              epoch,
              row['id'] as String,
              action: 'schedule',
              triggerUtcMicros: DateTime.utc(2099).microsecondsSinceEpoch,
              noticeRevision: 0,
              attemptedAt: now,
            ),
        ]);
        batches.add(pending);
        await Future.wait([
          for (final entry in pending)
            current.record(
              epoch,
              entry.reminderId,
              action: 'schedule',
              status: 'submitted',
              triggerUtcMicros: entry.triggerUtcMicros,
              noticeRevision: entry.noticeRevision,
              attemptedAt: now,
            ),
        ]);
        batches.add([
          for (final entry in pending)
            NotificationJournalEntry.decode({
              ...entry.toJson(),
              'status': 'submitted',
            }),
        ]);
      }
      final currentMicros = watch.elapsedMicroseconds;
      final expected = (await current.read())!;
      watch.reset();
      for (final batch in batches) {
        await experiment.append(epoch, batch);
      }
      final appendMicros = watch.elapsedMicroseconds;
      watch.reset();
      final recovered = await IncrementalJournalExperiment(
        experimentDir,
      ).open();
      final fullReplayMicros = watch.elapsedMicroseconds;
      if (jsonEncode(recovered.toJson()) != jsonEncode(expected.toJson())) {
        throw StateError('Recovered experiment does not equal v1');
      }
      final bytesBeforeCheckpoint = experiment.writtenBytes;
      watch.reset();
      await experiment.checkpoint(recovered);
      final compactMicros = watch.elapsedMicroseconds;
      final reopened = IncrementalJournalExperiment(experimentDir);
      watch.reset();
      final compacted = await reopened.open();
      final compactOpenMicros = watch.elapsedMicroseconds;
      if (jsonEncode(compacted.toJson()) != jsonEncode(expected.toJson())) {
        throw StateError('Checkpoint state differs');
      }
      reports.add({
        'mode': mode,
        'entries': rows.length,
        'batch_size': 256,
        'v1_us': currentMicros,
        'v1_writes': current.writeStatistics.replacements,
        'v1_bytes': current.writeStatistics.bytes,
        'append_us': appendMicros,
        'uncompacted_replay_us': fullReplayMicros,
        'append_bytes': bytesBeforeCheckpoint,
        'append_flushes': experiment.flushes - 3,
        'checkpoint_us': compactMicros,
        'checkpoint_bytes': experiment.writtenBytes - bytesBeforeCheckpoint,
        'prior_checkpoint_open_us': replayMicros,
        'compacted_open_us': compactOpenMicros,
        'equivalent_after_replay_and_checkpoint': true,
      });
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'scope':
            'Dart JIT journal-only experiment; sequential implementations; no OS effects; not product startup',
        'fixture_file_sha256': IncrementalJournalExperiment.digest(
          fixtureBytes,
        ),
        'task_rows_sha256': IncrementalJournalExperiment.digest(
          utf8.encode(jsonEncode(rows)),
        ),
        'runtime': Platform.version,
        'results': reports,
      }),
    );
  } finally {
    await root.delete(recursive: true);
  }
}
