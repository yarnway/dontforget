// Evaluation only: never imported by lib/. No production migration or GC.
// Caller owns an isolated directory, serializes operations and stops after any
// failed append. Generations are retained to inspect interrupted compaction.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:uuid/uuid.dart';

class IncrementalJournalExperiment {
  IncrementalJournalExperiment(this.directory);
  final Directory directory;
  NotificationJournalSnapshot? snapshot;
  String? _generation;
  String? _head;
  int _sequence = 0;
  int ignoredTailBytes = 0;
  int writtenBytes = 0;
  int flushes = 0;
  bool _failed = false;
  Future<void> Function(String point)? checkpointHook;

  static String digest(List<int> bytes) => sha256.convert(bytes).toString();
  File get _manifest => File('${directory.path}/current.json');
  File get delta => File('${directory.path}/$_generation.log');

  Future<void> _write(File file, List<int> bytes) async {
    await file.writeAsBytes(bytes, flush: true);
    writtenBytes += bytes.length;
    flushes++;
  }

  Future<void> checkpoint(NotificationJournalSnapshot state) async {
    final validated = NotificationJournalSnapshot.decode(state.toJson());
    final generation = const Uuid().v4();
    final bytes = utf8.encode(jsonEncode(validated.toJson()));
    final head = digest(bytes);
    await _write(File('${directory.path}/$generation.json'), bytes);
    await checkpointHook?.call('snapshot_flushed');
    await _write(File('${directory.path}/$generation.log'), []);
    final temporary = File('${directory.path}/$generation.manifest.tmp');
    await _write(
      temporary,
      utf8.encode(
        jsonEncode({
          'format': 'incremental-experiment-1',
          'generation': generation,
          'sha256': head,
        }),
      ),
    );
    await checkpointHook?.call('before_publish');
    await temporary.rename(_manifest.path);
    await checkpointHook?.call('after_publish');
    snapshot = validated;
    _generation = generation;
    _head = head;
    _sequence = 0;
    ignoredTailBytes = 0;
    _failed = false;
  }

  Future<NotificationJournalSnapshot> open() async {
    final manifest = jsonDecode(await _manifest.readAsString()) as Map;
    final generation = manifest['generation'];
    if (manifest.length != 3 ||
        manifest['format'] != 'incremental-experiment-1' ||
        generation is! String ||
        !RegExp(r'^[0-9a-f-]{36}$').hasMatch(generation)) {
      throw const FormatException('Invalid experiment manifest');
    }
    final bytes = await File(
      '${directory.path}/$generation.json',
    ).readAsBytes();
    var head = digest(bytes);
    if (head != manifest['sha256']) {
      throw const FormatException('Checkpoint checksum mismatch');
    }
    var state = NotificationJournalSnapshot.decode(
      jsonDecode(utf8.decode(bytes)),
    );
    final log = await File('${directory.path}/$generation.log').readAsBytes();
    var sequence = 0;
    var start = 0;
    for (var end = 0; end < log.length; end++) {
      if (log[end] != 10) continue;
      final frame = jsonDecode(utf8.decode(log.sublist(start, end))) as Map;
      final payload = frame['payload'] as String;
      final hash = digest(utf8.encode(payload));
      if (frame.length != 2 || hash != frame['sha256']) {
        throw const FormatException('Delta checksum mismatch');
      }
      final change = jsonDecode(payload) as Map;
      if (change.length != 4 ||
          change['sequence'] != sequence + 1 ||
          change['previous'] != head ||
          change['epoch'] != state.epoch) {
        throw const FormatException('Delta chain or epoch mismatch');
      }
      state = _apply(state, change['entries'] as List);
      sequence++;
      head = hash;
      start = end + 1;
    }
    // Only a non-terminated final frame may be uncommitted. Complete malformed
    // frames fail closed, including the last frame; no mid-log salvage.
    ignoredTailBytes = log.length - start;
    _generation = generation;
    snapshot = state;
    _head = head;
    _sequence = sequence;
    _failed = false;
    return state;
  }

  static NotificationJournalSnapshot _apply(
    NotificationJournalSnapshot state,
    List<dynamic> changes,
  ) {
    final entries = {...state.entries};
    for (final row in changes) {
      final entry = NotificationJournalEntry.decode(row);
      final previous = entries[entry.reminderId];
      if (previous != null && previous.nativeId != entry.nativeId) {
        throw const FormatException('Reserved native ID changed');
      }
      entries[entry.reminderId] = entry;
    }
    return NotificationJournalSnapshot.decode(
      NotificationJournalSnapshot(state.epoch, entries).toJson(),
    );
  }

  Future<void> append(
    String epoch,
    List<NotificationJournalEntry> changes,
  ) async {
    if (_failed || snapshot == null || snapshot!.epoch != epoch) {
      throw StateError('Journal must be opened in the current epoch');
    }
    if (ignoredTailBytes != 0) {
      throw StateError('Publish a checkpoint before writing after a torn tail');
    }
    final rows = changes.map((e) => e.toJson()).toList();
    final next = _apply(snapshot!, rows);
    final payload = jsonEncode({
      'sequence': _sequence + 1,
      'previous': _head,
      'epoch': epoch,
      'entries': rows,
    });
    final hash = digest(utf8.encode(payload));
    final bytes = utf8.encode(
      '${jsonEncode({'payload': payload, 'sha256': hash})}\n',
    );
    try {
      final file = await delta.open(mode: FileMode.append);
      try {
        await file.writeFrom(bytes);
        await file.flush();
      } finally {
        await file.close();
      }
      writtenBytes += bytes.length;
      flushes++;
      snapshot = next;
      _sequence++;
      _head = hash;
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }
}
