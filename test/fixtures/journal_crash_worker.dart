// Child process for abrupt termination tests; uses only its supplied temp dir.
import 'dart:io';
import 'package:dont_forget/services/notification_journal.dart';
import '../../benchmark/incremental_journal_experiment.dart';
import '../../benchmark/leased_incremental_journal.dart';

Future<void> boundary() async {
  stdout.writeln('DURABLE_BOUNDARY');
  await stdout.flush();
  await stdin.first; // Parent kills this child; no finally cleanup runs.
}

Future<void> main(List<String> args) async {
  final dir = Directory(args[0]);
  final mode = args[1];
  const epoch = '00000000-0000-4000-8000-000000000001';
  if (mode.startsWith('leased:')) {
    final session = await LeasedIncrementalJournal.acquire(dir);
    final point = mode.substring('leased:'.length);
    session.hook = (at) async {
      if (at == point) await boundary();
    };
    if (point == 'hold') {
      await boundary();
    } else if (point.startsWith('import_')) {
      await session.migrate();
    } else if (point.startsWith('rollback_')) {
      await session.rollback();
    } else if (point == 'generation_removed') {
      await session.collect();
    } else {
      await session.checkpoint();
    }
    throw StateError('Requested leased boundary was not reached');
  }
  if (mode.startsWith('segment:') || mode.startsWith('segment_bulk:')) {
    final bulk = mode.startsWith('segment_bulk:');
    final log = IncrementalJournalExperiment(
      dir,
      checkpointEveryFrames: bulk ? 1 : 2,
    );
    final old = await log.open();
    final point = mode.substring(mode.indexOf(':') + 1);
    Future<void> at(String boundaryName) async {
      if (point == boundaryName) await boundary();
    }

    log.appendHook = at;
    log.checkpointHook = at;
    await log.append(old.epoch, [
      NotificationJournalEntry.decode({
        ...old.entries.values.first.toJson(),
        'status': bulk ? 'pending' : 'submitted',
        if (bulk) 'attempts': old.entries.values.first.attempts + 1,
      }),
    ]);
    throw StateError('Requested segment boundary was not reached');
  }
  if (mode.startsWith('checkpoint:')) {
    final log = IncrementalJournalExperiment(dir);
    final old = await log.open();
    log.checkpointHook = (point) async {
      if (point == mode.substring('checkpoint:'.length)) await boundary();
    };
    await log.checkpoint(
      NotificationJournalSnapshot(
        '00000000-0000-4000-8000-000000000002',
        old.entries,
      ),
    );
    return;
  }
  final journal = mode == 'staged'
      ? NotificationJournal.forTesting(dir, boundary)
      : NotificationJournal(dir);
  final entry = await journal.begin(
    epoch,
    'task',
    action: 'schedule',
    triggerUtcMicros: 123,
    noticeRevision: 0,
    attemptedAt: DateTime.utc(2026),
  );
  if (mode == 'pending') await boundary();
  // A separate durable recorder stands for an acknowledged external effect.
  // This is not an OS notification: it establishes the uncertain crash window.
  await File(
    '${dir.path}/effect.json',
  ).writeAsString('${entry.nativeId}', flush: true);
  if (mode == 'effect') await boundary();
  await journal.record(
    epoch,
    'task',
    action: 'schedule',
    status: 'submitted',
    triggerUtcMicros: 123,
    noticeRevision: 0,
  );
  await boundary();
}
