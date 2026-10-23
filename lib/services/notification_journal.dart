import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/notification_payload.dart';

/// Platform-local operational state. Never imported from business backups.
/// Every operation must run under the database directory's ownership gate.
class NotificationJournal {
  NotificationJournal(this.directory) : _beforeReplace = null;

  /// Fault injection at the staging boundary; production callers use the
  /// ordinary constructor and retain the database ownership gate.
  NotificationJournal.forTesting(this.directory, this._beforeReplace);
  static const fileName = 'notification-journal.json';
  static const storageSelectorFileName = 'notification-storage.json';
  static const maxBytes = 16 * 1024 * 1024;
  final Directory directory;
  Future<void> _tail = Future.value();
  final Future<void> Function()? _beforeReplace;
  _JournalCache? _cache;
  List<_JournalChange>? _pendingChanges;
  static const _maxBatchSize = 256;
  int _replacements = 0;
  int _writtenBytes = 0;
  int _writeMicros = 0;

  /// Process-local diagnostics for successful replacements; contains no task
  /// content and is neither persisted nor used to decide notification state.
  ({int replacements, int bytes, int elapsedMicros}) get writeStatistics => (
    replacements: _replacements,
    bytes: _writtenBytes,
    elapsedMicros: _writeMicros,
  );

  Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
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
      final encoded = Map<String, String>.of(_cache!.encodedEntries);
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
          encoded[change.id] = jsonEncode(entry.toJson());
          modified = true;
        }
        results.add(entry);
      }
      if (modified) {
        await _write(
          NotificationJournalSnapshot(state.epoch, entries),
          encoded,
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
    Map<String, String> encodedEntries,
  ) async {
    final watch = Stopwatch()..start();
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
  final Uint8List bytes;
  final NotificationJournalSnapshot snapshot;
  Map<String, String>? _encodedEntries;
  Map<String, String> get encodedEntries => _encodedEntries ??= {
    for (final entry in snapshot.entries.values)
      entry.reminderId: jsonEncode(entry.toJson()),
  };
}

/// Stable across Dart processes and platforms; persisted allocation resolves
/// collisions. JSON escaping distinguishes even unpaired UTF-16 surrogates.
int stableNotificationId(String reminderId) {
  final digest = sha256.convert(
    utf8.encode('dontforget-native-id-v1:${jsonEncode(reminderId)}'),
  );
  final id =
      int.parse(digest.toString().substring(0, 8), radix: 16) & 0x7fffffff;
  return id == 0 ? 1 : id;
}

class NotificationJournalSnapshot {
  NotificationJournalSnapshot(
    this.epoch,
    Map<String, NotificationJournalEntry> entries,
  ) : entries = Map.unmodifiable(entries);
  final String epoch;
  final Map<String, NotificationJournalEntry> entries;
  Map<String, Object?> toJson() => {
    'version': 1,
    'epoch': epoch,
    'entries': entries.values.map((e) => e.toJson()).toList(),
  };
  factory NotificationJournalSnapshot.decode(dynamic value) {
    if (value is! Map ||
        value.length != 3 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['epoch'] is! String ||
        !NotificationPayload.isValidDatasetEpoch(value['epoch'] as String) ||
        value['entries'] is! List) {
      throw const FormatException('Invalid notification journal.');
    }
    final entries = <String, NotificationJournalEntry>{};
    final ids = <int>{};
    for (final row in value['entries'] as List) {
      final entry = NotificationJournalEntry.decode(row);
      if (entries.containsKey(entry.reminderId) || !ids.add(entry.nativeId)) {
        throw const FormatException('Duplicate notification identity.');
      }
      entries[entry.reminderId] = entry;
    }
    return NotificationJournalSnapshot(value['epoch'] as String, entries);
  }
}

class NotificationJournalEntry {
  const NotificationJournalEntry({
    required this.reminderId,
    required this.nativeId,
    required this.action,
    required this.status,
    required this.attempts,
    this.triggerUtcMicros,
    this.noticeRevision,
    this.attemptedAt,
  });
  final String reminderId;
  final int nativeId;
  final String action;
  // submitted means the plugin call returned, never a delivery receipt.
  final String status;
  final int attempts;
  final int? triggerUtcMicros;
  final int? noticeRevision;
  final String? attemptedAt;
  bool get needsCancellation => action != 'cancel' || status != 'submitted';
  bool get unfinished => status == 'pending' || status == 'failed';
  Map<String, Object?> toJson() => {
    'reminderId': reminderId,
    'nativeId': nativeId,
    'action': action,
    'status': status,
    'attempts': attempts,
    'triggerUtcMicros': triggerUtcMicros,
    'noticeRevision': noticeRevision,
    'attemptedAt': attemptedAt,
  };
  factory NotificationJournalEntry.decode(dynamic row) {
    if (row is! Map ||
        row.length != 8 ||
        row.keys.any(
          (key) => !const {
            'reminderId',
            'nativeId',
            'action',
            'status',
            'attempts',
            'triggerUtcMicros',
            'noticeRevision',
            'attemptedAt',
          }.contains(key),
        ) ||
        row['reminderId'] is! String ||
        (row['reminderId'] as String).isEmpty ||
        row['nativeId'] is! int ||
        (row['nativeId'] as int) < 1 ||
        (row['nativeId'] as int) > 0x7fffffff ||
        !['schedule', 'cancel'].contains(row['action']) ||
        ![
          'reserved',
          'pending',
          'submitted',
          'failed',
        ].contains(row['status']) ||
        row['attempts'] is! int ||
        (row['attempts'] as int) < 0 ||
        (row['triggerUtcMicros'] != null && row['triggerUtcMicros'] is! int) ||
        (row['noticeRevision'] != null &&
            (row['noticeRevision'] is! int ||
                (row['noticeRevision'] as int) < 0)) ||
        (row['attemptedAt'] != null &&
            (row['attemptedAt'] is! String ||
                DateTime.tryParse(row['attemptedAt'] as String) == null))) {
      throw const FormatException('Invalid notification journal entry.');
    }
    return NotificationJournalEntry(
      reminderId: row['reminderId'] as String,
      nativeId: row['nativeId'] as int,
      action: row['action'] as String,
      status: row['status'] as String,
      attempts: row['attempts'] as int,
      triggerUtcMicros: row['triggerUtcMicros'] as int?,
      noticeRevision: row['noticeRevision'] as int?,
      attemptedAt: row['attemptedAt'] as String?,
    );
  }
}
