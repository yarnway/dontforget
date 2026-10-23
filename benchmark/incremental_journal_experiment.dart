// Evaluation only: never imported by lib/. No production migration or generation reclamation.
// Caller owns an isolated directory and serializes operations. A failed write
// poisons the writer until open() establishes the selected durable generation.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/services/notification_journal.dart';
import 'package:uuid/uuid.dart';

class JournalSegmentFull extends StateError {
  JournalSegmentFull()
    : super('Checkpoint required before reaching the log byte limit');
}

class IncrementalJournalExperiment {
  IncrementalJournalExperiment(
    this.directory, {
    this.checkpointEveryFrames = 0,
    this.maxCheckpointBytes = 16 * 1024 * 1024,
    this.maxLogBytes = 64 * 1024 * 1024,
    this.maxFrameBytes = 4 * 1024 * 1024,
  }) {
    if (checkpointEveryFrames < 0 || checkpointEveryFrames > 1024) {
      throw ArgumentError.value(checkpointEveryFrames, 'checkpointEveryFrames');
    }
    if (maxCheckpointBytes <= 0 ||
        maxCheckpointBytes > 16 * 1024 * 1024 ||
        maxLogBytes <= 0 ||
        maxLogBytes > 64 * 1024 * 1024 ||
        maxFrameBytes <= 0 ||
        maxFrameBytes > 4 * 1024 * 1024) {
      throw ArgumentError(
        'Journal limits must be positive and within ceilings',
      );
    }
  }
  final Directory directory;
  final int checkpointEveryFrames;
  final int maxCheckpointBytes;
  final int maxLogBytes;
  final int maxFrameBytes;
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

  Future<void> _requireDirectory() async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException(
        'An owned directory, not a link, is required',
      );
    }
  }

  Future<void> _regularOrMissing(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const FormatException('Journal target is not a regular file');
    }
  }

  Future<int> _regularSize(File file, int limit) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('Missing journal input', file.path);
    }
    if (type != FileSystemEntityType.file) {
      throw const FormatException('Journal input is not a regular file');
    }
    final size = await file.length();
    if (size > limit) throw const FormatException('Journal file exceeds limit');
    return size;
  }

  Future<List<int>> _readBounded(File file, int limit) async {
    await _regularSize(file, limit);
    final bytes = await file.readAsBytes();
    if (bytes.length > limit) {
      throw const FormatException('Journal file grew beyond limit');
    }
    return bytes;
  }

  Future<void> _write(File file, List<int> bytes, int limit) async {
    if (bytes.length > limit) throw StateError('Journal write exceeds limit');
    await _regularOrMissing(file);
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
    await _requireDirectory();
    await _regularOrMissing(_manifest);
    final watch = Stopwatch()..start();
    final validated = NotificationJournalSnapshot.decode(state.toJson());
    if (_epoch == state.epoch &&
        _entries.entries.any(
          (old) => state.entries[old.key]?.nativeId != old.value.nativeId,
        )) {
      throw const FormatException('Checkpoint lost a reserved identity');
    }
    final bytes = utf8.encode(jsonEncode(validated.toJson()));
    if (bytes.length > maxCheckpointBytes) {
      throw StateError('Checkpoint exceeds byte limit');
    }
    _failed = true;
    final generation = const Uuid().v4();
    final head = digest(bytes);
    await _write(
      File('${directory.path}/$generation.json'),
      bytes,
      maxCheckpointBytes,
    );
    await checkpointHook?.call('snapshot_flushed');
    await _write(File('${directory.path}/$generation.log'), [], maxLogBytes);
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
      4096,
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
    await _requireDirectory();
    final manifest =
        jsonDecode(utf8.decode(await _readBounded(_manifest, 4096))) as Map;
    final generation = manifest['generation'];
    if (manifest.length != 3 ||
        manifest['format'] != 'incremental-experiment-1' ||
        generation is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(generation)) {
      throw const FormatException('Invalid experiment manifest');
    }
    final bytes = await _readBounded(
      File('${directory.path}/$generation.json'),
      maxCheckpointBytes,
    );
    var head = digest(bytes);
    if (head != manifest['sha256']) {
      throw const FormatException('Checkpoint checksum mismatch');
    }
    _load(NotificationJournalSnapshot.decode(jsonDecode(utf8.decode(bytes))));
    final log = await _readBounded(
      File('${directory.path}/$generation.log'),
      maxLogBytes,
    );
    var sequence = 0;
    var start = 0;
    for (var end = 0; end < log.length; end++) {
      if (log[end] != 10) continue;
      if (end - start + 1 > maxFrameBytes) {
        throw const FormatException('Delta frame exceeds limit');
      }
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
    if (ignoredTailBytes > maxFrameBytes) {
      throw const FormatException('Uncommitted tail exceeds frame limit');
    }
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
    await _requireDirectory();
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
    if (bytes.length > maxFrameBytes || bytes.length > maxLogBytes) {
      throw StateError('Delta frame exceeds byte limit');
    }
    late final int logSize;
    try {
      logSize = await _regularSize(delta, maxLogBytes);
    } catch (_) {
      _failed = true;
      rethrow;
    }
    if (logSize + bytes.length > maxLogBytes) {
      // No write occurred. A checkpoint can rotate the segment safely.
      throw JournalSegmentFull();
    }
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
