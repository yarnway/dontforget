// Child process for abrupt termination tests; uses only its supplied temp dir.
import 'dart:io';
import 'package:dont_forget/services/notification_journal.dart';
import '../../benchmark/incremental_journal_experiment.dart';

Future<void> boundary() async {
  stdout.writeln('DURABLE_BOUNDARY');
  await stdout.flush();
  await stdin.first; // Parent kills this child; no finally cleanup runs.
}

Future<void> main(List<String> args) async {
  final dir = Directory(args[0]);
  final mode = args[1];
  const epoch = '00000000-0000-4000-8000-000000000001';
  if (mode.startsWith('segment:')) {
    final log = IncrementalJournalExperiment(dir, checkpointEveryFrames: 2);
    final old = await log.open();
    final point = mode.substring('segment:'.length);
    Future<void> at(String boundaryName) async {
      if (point == boundaryName) await boundary();
    }

    log.appendHook = at;
    log.checkpointHook = at;
    await log.append(old.epoch, [
      NotificationJournalEntry.decode({
        ...old.entries.values.single.toJson(),
        'status': 'submitted',
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
