// Run with the pinned Dart SDK. Uses only a new temporary directory.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dont_forget/services/notification_journal.dart';
import '../benchmark/incremental_journal_experiment.dart';
import '../benchmark/leased_incremental_journal.dart';

const usage =
    '''Usage: dart run scripts/evaluate_incremental_journal.dart --fixture PATH
Reads a closed synthetic ha_snapshot.json (10000 tasks), preserving its rows.
Compares v1 replacement, indexed append, and indexed append with a checkpoint
every 24 frames, using identical 256-entry pending/submitted batches. Each
variant runs once empty and once already submitted. Checkpoint costs are included.
Output is JSON on stdout. No OS notification or application data is changed.
The experiment bounds manifests at 4 KiB, checkpoints at 16 MiB, segments at
64 MiB and frames at 4 MiB; links are rejected. Protocol v4 additionally measures
the shared directory lease, v1 migration, latest-state rollback and generation
reclamation with a 256 MiB / 256-file managed directory budget. It does not enable the
incremental backend in the product. No live app directory is opened.
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
    final directories = <String, Directory>{};
    for (final name in ['indexed', 'segmented_24']) {
      final dir = await Directory('${root.path}/$name').create();
      directories[name] = dir;
      await IncrementalJournalExperiment(
        dir,
      ).checkpoint(NotificationJournalSnapshot(epoch, {}));
    }
    var current = NotificationJournal(currentDir);
    await current.reset(epoch);
    final leasedDirectory = await Directory('${root.path}/leased').create();
    await NotificationJournal(leasedDirectory).reset(epoch);
    var leased = await LeasedIncrementalJournal.acquire(leasedDirectory);
    await leased.migrate();
    await leased.close();
    for (final mode in ['first', 'reopen']) {
      current = NotificationJournal(currentDir);
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
      final variants = <Map<String, Object>>[];
      for (final (name, directory) in directories.entries.map(
        (e) => (e.key, e.value),
      )) {
        final experiment = IncrementalJournalExperiment(
          directory,
          checkpointEveryFrames: name == 'indexed' ? 0 : 24,
        );
        watch.reset();
        await experiment.open();
        final priorOpenMicros = watch.elapsedMicroseconds;
        watch.reset();
        for (final batch in batches) {
          await experiment.append(epoch, batch);
        }
        final appendMicros = watch.elapsedMicroseconds;
        final bytesBeforeCheckpoint = experiment.writtenBytes;
        final flushesBeforeCheckpoint = experiment.flushes;
        final periodicCheckpoints = experiment.checkpoints;
        final periodicCheckpointMicros = experiment.checkpointMicroseconds;
        final replay = IncrementalJournalExperiment(directory);
        watch.reset();
        final recovered = await replay.open();
        final fullReplayMicros = watch.elapsedMicroseconds;
        if (jsonEncode(recovered.toJson()) != jsonEncode(expected.toJson())) {
          throw StateError('Recovered $name does not equal v1');
        }
        watch.reset();
        await experiment.checkpoint(recovered);
        final compactMicros = watch.elapsedMicroseconds;
        final reopened = IncrementalJournalExperiment(directory);
        watch.reset();
        final compacted = await reopened.open();
        final compactOpenMicros = watch.elapsedMicroseconds;
        if (jsonEncode(compacted.toJson()) != jsonEncode(expected.toJson())) {
          throw StateError('Checkpoint state differs for $name');
        }
        variants.add({
          'variant': name,
          'append_including_periodic_checkpoint_us': appendMicros,
          'written_including_periodic_checkpoint_bytes': bytesBeforeCheckpoint,
          'flushes_including_periodic_checkpoint': flushesBeforeCheckpoint,
          'periodic_checkpoints': periodicCheckpoints,
          'periodic_checkpoint_us': periodicCheckpointMicros,
          'tail_replay_frames': replay.replayedFrames,
          'open_before_final_checkpoint_us': fullReplayMicros,
          'final_checkpoint_us': compactMicros,
          'final_checkpoint_bytes':
              experiment.writtenBytes - bytesBeforeCheckpoint,
          'compacted_open_us': compactOpenMicros,
          'prior_checkpoint_open_us': priorOpenMicros,
          'equivalent_after_replay_and_checkpoint': true,
        });
      }
      watch.reset();
      leased = await LeasedIncrementalJournal.acquire(leasedDirectory);
      final leasedPriorOpen = watch.elapsedMicroseconds;
      try {
        watch.reset();
        for (final batch in batches) {
          await leased.append(epoch, batch);
        }
        final leasedAppend = watch.elapsedMicroseconds;
        final stats = leased.writeStatistics;
        final usage = await leased.collect();
        await leased.close();
        watch.reset();
        leased = await LeasedIncrementalJournal.acquire(leasedDirectory);
        final leasedReplay = watch.elapsedMicroseconds;
        final state = (await leased.read())!;
        if (jsonEncode(state.toJson()) != jsonEncode(expected.toJson())) {
          throw StateError('Leased replay differs from v1');
        }
        watch.reset();
        await leased.rollback();
        final rollback = watch.elapsedMicroseconds;
        final exported = (await NotificationJournal(leasedDirectory).read())!;
        if (jsonEncode(exported.toJson()) != jsonEncode(expected.toJson())) {
          throw StateError(
            'Rollback export differs from latest incremental state',
          );
        }
        watch.reset();
        await leased.migrate();
        final remigrate = watch.elapsedMicroseconds;
        variants.add({
          'variant': 'leased_segmented_24',
          'prior_lease_and_open_us': leasedPriorOpen,
          'append_including_periodic_checkpoint_us': leasedAppend,
          'written_including_periodic_checkpoint_bytes': stats.bytes,
          'flushes_including_periodic_checkpoint': stats.flushes,
          'periodic_checkpoints': stats.checkpoints,
          'lease_and_replay_us': leasedReplay,
          'managed_bytes_after_reclamation': usage.bytes,
          'rollback_latest_to_v1_us': rollback,
          'remigrate_latest_v1_us': remigrate,
          'equivalent_after_replay_rollback_and_remigration': true,
        });
      } finally {
        await leased.close();
      }
      reports.add({
        'mode': mode,
        'entries': rows.length,
        'batch_size': 256,
        'v1_us': currentMicros,
        'v1_writes': current.writeStatistics.replacements,
        'v1_bytes': current.writeStatistics.bytes,
        'variants': variants,
      });
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'scope':
            'Dart JIT journal-only experiment v4; bounded files, leased migration/rollback and generation reclamation; v1 then indexed then segmented then leased; checkpoint costs included; no OS effects or product startup',
        'protocol_version': 4,
        'experiment_limits': {
          'manifest_bytes': 4096,
          'checkpoint_bytes': 16 * 1024 * 1024,
          'segment_bytes': 64 * 1024 * 1024,
          'frame_bytes': 4 * 1024 * 1024,
          'symlink_inputs_and_targets': 'rejected',
          'caller_exclusive_directory_required': true,
          'leased_variant_directory_budget_bytes': 256 * 1024 * 1024,
          'leased_variant_max_managed_files':
              LeasedIncrementalJournal.maxManagedFiles,
          'leased_variant_uses_database_ownership_lock': true,
        },
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
