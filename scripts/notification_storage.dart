// Offline upgrade/downgrade. Refuses a live owner's lease; never deletes it.
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/services/selected_notification_journal.dart';

const usage =
    '''Usage: dart run scripts/notification_storage.dart --directory ABSOLUTE_DATABASE_DIRECTORY --upgrade|--rollback
Quit the application first. Acquires the same exclusive directory lease as the
product. Unknown/corrupt input or external conflicts are preserved and rejected.
--upgrade preserves v1 and selects incremental storage after its checkpoint.
--rollback exports the latest state/IDs to v1 and pins v1 on future launches.
Reopening finishes a validated interrupted rollback before the requested action.
Business databases, backups and attachments are never changed.
''';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--help') {
    stdout.write(usage);
    return;
  }
  if (args.length != 3 ||
      args[0] != '--directory' ||
      !['--upgrade', '--rollback'].contains(args[2]) ||
      !Directory(args[1]).isAbsolute) {
    stderr.write(usage);
    exitCode = 64;
    return;
  }
  LeasedIncrementalJournal? session;
  try {
    session = await LeasedIncrementalJournal.acquire(Directory(args[1]));
    if (args[2] == '--upgrade') {
      if (!session.isIncremental) await session.migrate();
    } else {
      await session.rollback();
    }
    final state = await session.read();
    stdout.writeln(
      jsonEncode({
        'backend': session.isIncremental ? 'incremental' : 'v1',
        'epoch': state?.epoch,
        'entries': state?.entries.length,
        'scope':
            'Local notification state only; no OS scheduling or business data changes',
      }),
    );
  } catch (error) {
    stderr.writeln('Notification storage operation refused: $error');
    exitCode = 1;
  } finally {
    await session?.close();
  }
}
