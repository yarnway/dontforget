// Evaluation only: never imported by lib/. No production migration or GC.
// Caller owns an isolated directory and serializes operations. A failed write
// poisons the writer until open() establishes the selected durable generation.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:uuid/uuid.dart';

class IncrementalJournalExperiment {
  IncrementalJournalExperiment(
    this.directory, {
    this.checkpointEveryFrames = 0,
  }) {
    if (checkpointEveryFrames < 0 || checkpointEveryFrames > 1024) {
      throw ArgumentError.value(checkpointEveryFrames, 'checkpointEveryFrames');
    }
  }
  final Directory directory;
  final int checkpointEveryFrames;
  final _entries = <String, NotificationJournalEntry>{};
  final _owners = <int, String>{};
  String? _epoch;
  String? _generation;
  String? _head;
  int _sequence = 0;
  int get segmentFrames => _sequence;
  int ignoredTailBytes = 0;
  int writtenBytes = 0;
  int flushes = 0;
  int checkpoints = 0;
  int checkpointMicroseconds = 0;
  int replayedFrames = 0;
  bool _failed = false;
  Future<void> Function(String point)? checkpointHook;
  Future<void> Function(String point)? appendHook;

  NotificationJournalSnapshot? get snapshot => _failed || _epoch == null
      ? null
      : NotificationJournalSnapshot(_epoch!, _entries);
  static String digest(List<int> bytes) => sha256.convert(bytes).toString();
  File get _manifest => File('${directory.path}/current.json');
  File get delta => File('${directory.path}/$_generation.log');

  Future<void> _write(File file, List<int> bytes) async {
    await file.writeAsBytes(bytes, flush: true);
    writtenBytes += bytes.length;
    flushes++;
  }

  void _load(NotificationJournalSnapshot state) {
    _epoch = state.epoch;
    _entries
      ..clear()
      ..addAll(state.entries);
    _owners
      ..clear()
      ..addEntries(
        state.entries.values.map((e) => MapEntry(e.nativeId, e.reminderId)),
      );
  }

  Future<void> checkpoint(NotificationJournalSnapshot state) async {
    if (_failed) {
      throw StateError('Reopen the failed writer before checkpointing');
    }
    final watch = Stopwatch()..start();
    final validated = NotificationJournalSnapshot.decode(state.toJson());
    if (_epoch == state.epoch &&
        _entries.entries.any(
          (old) => state.entries[old.key]?.nativeId != old.value.nativeId,
        )) {
      throw const FormatException('Checkpoint lost a reserved identity');
    }
    _failed = true;
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
    _load(validated);
    _generation = generation;
    _head = head;
    _sequence = 0;
    ignoredTailBytes = 0;
    _failed = false;
    checkpoints++;
    checkpointMicroseconds += watch.elapsedMicroseconds;
  }

  Future<NotificationJournalSnapshot> open() async {
    _failed = true;
    replayedFrames = 0;
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
    _load(NotificationJournalSnapshot.decode(jsonDecode(utf8.decode(bytes))));
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
          change['epoch'] != _epoch) {
        throw const FormatException('Delta chain or epoch mismatch');
      }
      _apply(_prepare(change['entries'] as List));
      sequence++;
      head = hash;
      start = end + 1;
    }
    // Only a non-terminated final frame may be uncommitted. Complete malformed
    // frames fail closed; no mid-log salvage or appending behind a torn tail.
    ignoredTailBytes = log.length - start;
    _generation = generation;
    _head = head;
    _sequence = sequence;
    replayedFrames = sequence;
    _failed = false;
    return snapshot!;
  }

  Map<String, NotificationJournalEntry> _prepare(List<dynamic> changes) {
    final staged = <String, NotificationJournalEntry>{};
    final owners = <int, String>{};
    for (final row in changes) {
      final entry = NotificationJournalEntry.decode(row);
      final previous = staged[entry.reminderId] ?? _entries[entry.reminderId];
      final owner = owners[entry.nativeId] ?? _owners[entry.nativeId];
      if ((previous != null && previous.nativeId != entry.nativeId) ||
          (owner != null && owner != entry.reminderId)) {
        throw const FormatException('Reserved native ID changed or collided');
      }
      staged[entry.reminderId] = entry;
      owners[entry.nativeId] = entry.reminderId;
    }
    return staged;
  }

  void _apply(Map<String, NotificationJournalEntry> staged) {
    _entries.addAll(staged);
    for (final entry in staged.values) {
      _owners[entry.nativeId] = entry.reminderId;
    }
  }

  Future<void> append(
    String epoch,
    List<NotificationJournalEntry> changes,
  ) async {
    if (_failed || _epoch != epoch) {
      throw StateError('Journal must be opened in the current epoch');
    }
    if (ignoredTailBytes != 0) {
      throw StateError('Publish a checkpoint before writing after a torn tail');
    }
    final rows = changes.map((e) => e.toJson()).toList();
    final staged = _prepare(rows);
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
        if (appendHook != null) {
          final cut = bytes.length ~/ 2;
          await file.writeFrom(bytes, 0, cut);
          await file.flush();
          await appendHook!('half_frame_written');
          await file.writeFrom(bytes, cut);
        } else {
          await file.writeFrom(bytes);
        }
        await file.flush();
        await appendHook?.call('frame_flushed');
      } finally {
        await file.close();
      }
      writtenBytes += bytes.length;
      flushes++;
      _apply(staged);
      _sequence++;
      _head = hash;
      if (checkpointEveryFrames != 0 && _sequence >= checkpointEveryFrames) {
        await checkpoint(snapshot!);
      }
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }
}
