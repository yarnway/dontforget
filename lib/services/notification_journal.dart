import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/notification_payload.dart';
import 'notification_journal_model.dart';
import 'selected_notification_journal.dart';
import 'storage_directory_lease.dart';
export 'notification_journal_model.dart';

/// Platform-local operational state. Never imported from business backups.
/// Every operation must run under the database directory's ownership gate.
class NotificationJournal {
  NotificationJournal(this.directory) : _beforeReplace = null;

  static Future<NotificationJournal> openOwned(
    StorageDirectoryLease lease, {
    required bool migrateLegacy,
  }) async {
    final journal = NotificationJournal(lease.directory);
    journal._lease = lease;
    journal._migrateLegacy = migrateLegacy;
    journal._selected = await LeasedIncrementalJournal.attach(lease);
    await journal.read();
    return journal;
  }

  StorageDirectoryLease? _lease;
  LeasedIncrementalJournal? _selected;
  bool _migrateLegacy = false;
  bool _closed = false;
  int _scheduledOperations = 0;
  Future<void>? _closeFuture;
  bool get usesIncrementalStorage => _selected?.isIncremental ?? false;

  /// Call while the owning database maintenance gate has drained operations.
  Future<void> rollbackToV1() {
    _pendingChanges = null;
    return _serialize(() async {
      _lease?.checkHeld();
      if (_selected == null) throw StateError('An owned journal is required');
      await _selected!.rollback();
      _cache = null;
    });
  }

  Future<void> close() {
    _closed = true;
    _pendingChanges = null;
    Future<void> finish() async {
      await _selected?.close();
    }

    return _closeFuture ??= _scheduledOperations == 0
        ? finish()
        : _tail.then((_) => finish());
  }

  /// Fault injection at the staging boundary; production callers use the
  /// ordinary constructor and retain the database ownership gate.
  NotificationJournal.forTesting(this.directory, this._beforeReplace);
  static const fileName = NotificationJournalFormat.fileName;
  static const storageSelectorFileName =
      NotificationJournalFormat.storageSelectorFileName;
  static const maxBytes = NotificationJournalFormat.maxBytes;
  final Directory directory;
  Future<void> _tail = Future.value();
  final Future<void> Function()? _beforeReplace;
  _JournalCache? _cache;
  List<_JournalChange>? _pendingChanges;
  static const _maxBatchSize = 256;
  int _replacements = 0;
  int _writtenBytes = 0;
  int _writeMicros = 0;

  /// Process-local payload/checkpoint diagnostics for successful mutations.
  /// The legacy replacements field counts flushes on incremental storage;
  /// migration and selection/retention metadata are excluded. No task content,
  /// persistence or notification decisions depend on these counters.
  ({int replacements, int bytes, int elapsedMicros}) get writeStatistics => (
    replacements: _replacements,
    bytes: _writtenBytes,
    elapsedMicros: _writeMicros,
  );

  Future<T> _serialize<T>(Future<T> Function() action) {
    if (_closed) {
      return Future.error(StateError('Notification journal is closed'));
    }
    _scheduledOperations++;
    final next = _tail.then((_) async {
      try {
        return await action();
      } finally {
        _scheduledOperations--;
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<NotificationJournalSnapshot?> read() {
    _pendingChanges = null; // A read is an ordering barrier for queued writes.
    return _serialize(_read);
  }

  Future<void> reset(String epoch) {
    _pendingChanges = null; // Never combine mutations across an epoch reset.
    return _serialize(() async {
      await _read(); // Refuse corrupt/symlink state; never silently discard it.
      if (!NotificationPayload.isValidDatasetEpoch(epoch)) {
        throw const FormatException('Invalid notification journal epoch.');
      }
      await _write(NotificationJournalSnapshot(epoch, {}), {});
    });
  }

  Future<NotificationJournalEntry> reserve(String epoch, String reminderId) =>
      _change(
        epoch,
        reminderId,
        (previous, used) => previous ?? _allocate(reminderId, used),
      );

  NotificationJournalEntry _allocate(String reminderId, Set<int> used) {
    var id = stableNotificationId(reminderId);
    while (used.contains(id)) {
      id = id == 0x7fffffff ? 1 : id + 1;
    }
    return NotificationJournalEntry(
      reminderId: reminderId,
      nativeId: id,
      action: 'cancel',
      status: 'reserved',
      attempts: 0,
    );
  }

  /// Allocate (or retain) the ID and persist its pending intent in one commit.
  /// The native caller receives no ID until that commit succeeds.
  Future<NotificationJournalEntry> begin(
    String epoch,
    String reminderId, {
    required String action,
    int? triggerUtcMicros,
    int? noticeRevision,
    required DateTime attemptedAt,
  }) => _change(epoch, reminderId, (previous, used) {
    final entry = previous ?? _allocate(reminderId, used);
    return NotificationJournalEntry(
      reminderId: reminderId,
      nativeId: entry.nativeId,
      action: action,
      status: 'pending',
      attempts: entry.attempts + 1,
      triggerUtcMicros: triggerUtcMicros,
      noticeRevision: noticeRevision,
      attemptedAt: attemptedAt.toUtc().toIso8601String(),
    );
  });

  Future<void> record(
    String epoch,
    String reminderId, {
    required String action,
    required String status,
    int? triggerUtcMicros,
    int? noticeRevision,
    DateTime? attemptedAt,
  }) => _change(epoch, reminderId, (previous, _) {
    if (previous == null) throw StateError('Notification ID not reserved.');
    return NotificationJournalEntry(
      reminderId: reminderId,
      nativeId: previous.nativeId,
      action: action,
      status: status,
      attempts: previous.attempts + (status == 'pending' ? 1 : 0),
      triggerUtcMicros: triggerUtcMicros,
      noticeRevision: noticeRevision,
      attemptedAt:
          attemptedAt?.toUtc().toIso8601String() ?? previous.attemptedAt,
    );
  }).then<void>((_) {});

  Future<NotificationJournalEntry> _change(
    String epoch,
    String id,
    NotificationJournalEntry Function(NotificationJournalEntry?, Set<int>)
    apply,
  ) {
    if (_closed) {
      return Future.error(StateError('Notification journal is closed'));
    }
    var batch = _pendingChanges;
    if (batch == null ||
        batch.length >= _maxBatchSize ||
        batch.first.epoch != epoch) {
      batch = [];
      _pendingChanges = batch;
      final queued = batch;
      // The queued operation owns all caller admissions until its durable
      // write finishes. Results never complete from an in-memory intent.
      unawaited(_serialize(() => _commitChanges(queued)));
    }
    final change = _JournalChange(epoch, id, apply);
    batch.add(change);
    return change.result.future;
  }

  Future<void> _commitChanges(List<_JournalChange> changes) async {
    // Collect callers admitted during this event turn, without delaying a
    // pending intent behind any native effect. Reads/resets seal the batch.
    await Future<void>.delayed(Duration.zero);
    if (identical(_pendingChanges, changes)) _pendingChanges = null;
    try {
      final state = await _require(changes.first.epoch);
      final entries = Map<String, NotificationJournalEntry>.of(state.entries);
      final encoded = usesIncrementalStorage
          ? <String, String>{}
          : Map<String, String>.of(_cache!.encodedEntries);
      final used = entries.values.map((e) => e.nativeId).toSet();
      final results = <NotificationJournalEntry>[];
      var modified = false;
      for (final change in changes) {
        final previous = entries[change.id];
        final entry = change.apply(previous, used);
        if (!identical(previous, entry)) {
          NotificationJournalEntry.decode(entry.toJson());
          entries[change.id] = entry;
          used.add(entry.nativeId);
          if (!usesIncrementalStorage) {
            encoded[change.id] = jsonEncode(entry.toJson());
          }
          modified = true;
        }
        results.add(entry);
      }
      if (modified) {
        await _write(
          NotificationJournalSnapshot(state.epoch, entries),
          encoded,
          updates: {
            for (final entry in results) entry.reminderId: entry,
          }.values.toList(),
        );
      }
      for (var i = 0; i < changes.length; i++) {
        changes[i].result.complete(results[i]);
      }
    } catch (error, stack) {
      // One atomic replacement, one outcome. On any validation/staging error
      // every caller observes failure and the previous durable file survives.
      for (final change in changes) {
        change.result.completeError(error, stack);
      }
    }
  }

  Future<NotificationJournalSnapshot> _require(String epoch) async {
    final state = await _read();
    if (state == null || state.epoch != epoch) {
      throw StateError('Notification journal epoch is not ready.');
    }
    return state;
  }

  Future<void> _checkDirectory() async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await directory.resolveSymbolicLinks() != directory.path) {
      throw const FormatException('Unsafe notification journal directory.');
    }
  }

  File get _file => File(p.join(directory.path, fileName));
  Future<Uint8List?> _readBytes() async {
    await _checkDirectory();
    final type = await FileSystemEntity.type(_file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file || await _file.length() > maxBytes) {
      throw const FormatException('Invalid notification journal file.');
    }
    final bytes = await _file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw const FormatException('Invalid notification journal file.');
    }
    return bytes;
  }

  Future<NotificationJournalSnapshot?> _read() async {
    _lease?.checkHeld();
    final selected = _selected;
    if (selected != null) {
      if (!selected.isIncremental &&
          _migrateLegacy &&
          await selected.permitsAutomaticMigration &&
          await selected.read() != null) {
        await selected.migrate();
      }
      if (selected.isIncremental) {
        final snapshot = (await selected.read())!;
        _cache = _JournalCache(null, snapshot);
        return snapshot;
      }
    }
    final bytes = await _readBytes();
    if (bytes == null) {
      _cache = null;
      return null;
    }
    final cached = _cache;
    // Check content, not mtime/length: equal-size external edits must be seen.
    if (cached != null && _sameBytes(cached.bytes, bytes)) {
      return cached.snapshot;
    }
    final snapshot = NotificationJournalSnapshot.decode(
      jsonDecode(utf8.decode(bytes)),
    );
    _cache = _JournalCache(bytes, snapshot);
    return snapshot;
  }

  Future<void> _write(
    NotificationJournalSnapshot state,
    Map<String, String> encodedEntries, {
    List<NotificationJournalEntry>? updates,
  }) async {
    final watch = Stopwatch()..start();
    _lease?.checkHeld();
    if (usesIncrementalStorage) {
      final selected = _selected!;
      final before = selected.writeStatistics;
      if (updates == null) {
        await selected.reset(state.epoch);
      } else {
        await selected.append(state.epoch, updates);
      }
      final after = selected.writeStatistics;
      _cache = _JournalCache(null, state);
      _replacements += after.flushes - before.flushes;
      _writtenBytes += after.bytes - before.bytes;
      _writeMicros += watch.elapsedMicroseconds;
      return;
    }
    final expected = _cache?.bytes;
    // Reuse validated per-record encodings while retaining one atomic file.
    // Keep encoding order/format compatible with version 1 journals.
    final bytes = utf8.encode(
      '{"version":1,"epoch":${jsonEncode(state.epoch)},'
      '"entries":[${encodedEntries.values.join(',')}]}',
    );
    if (bytes.length > maxBytes) {
      throw const FormatException('Notification journal size limit reached.');
    }
    final temporary = File('${_file.path}.${const Uuid().v4()}.tmp');
    await _checkDirectory();
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FormatException('Notification journal staging file exists.');
    }
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await _beforeReplace?.call();
      final current = await _readBytes();
      if (!_sameBytes(expected, current)) {
        // Includes valid external edits and removal. Do not overwrite them.
        throw const FormatException(
          'Notification journal changed during write.',
        );
      }
      // Never unlink the last valid target to make replacement succeed.
      await temporary.rename(_file.path);
      _cache = _JournalCache(bytes, state, encodedEntries);
      _replacements++;
      _writtenBytes += bytes.length;
      _writeMicros += watch.elapsedMicroseconds;
    } finally {
      // Only our random staging file is disposable; preserve the target.
      if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await temporary.delete();
      }
    }
  }
}

bool _sameBytes(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _JournalChange {
  _JournalChange(this.epoch, this.id, this.apply);
  final String epoch;
  final String id;
  final NotificationJournalEntry Function(NotificationJournalEntry?, Set<int>)
  apply;
  final result = Completer<NotificationJournalEntry>();
}

class _JournalCache {
  _JournalCache(this.bytes, this.snapshot, [this._encodedEntries]);
  final Uint8List? bytes;
  final NotificationJournalSnapshot snapshot;
  Map<String, String>? _encodedEntries;
  Map<String, String> get encodedEntries => _encodedEntries ??= {
    for (final entry in snapshot.entries.values)
      entry.reminderId: jsonEncode(entry.toJson()),
  };
}
