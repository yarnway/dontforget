import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/notification_payload.dart';

/// Platform-local operational state. Never imported from business backups.
/// Every operation must run under the database directory's ownership gate.
class NotificationJournal {
  NotificationJournal(this.directory);
  static const fileName = 'notification-journal.json';
  static const maxBytes = 16 * 1024 * 1024;
  final Directory directory;
  Future<void> _tail = Future.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<NotificationJournalSnapshot?> read() => _serialize(_read);

  Future<void> reset(String epoch) => _serialize(() async {
    await _read(); // Refuse corrupt/symlink state; never silently discard it.
    await _write(NotificationJournalSnapshot(epoch, {}));
  });

  Future<NotificationJournalEntry> reserve(String epoch, String reminderId) =>
      _serialize(() async {
        final state = await _require(epoch);
        final existing = state.entries[reminderId];
        if (existing != null) return existing;
        final used = state.entries.values.map((e) => e.nativeId).toSet();
        var id = stableNotificationId(reminderId);
        while (used.contains(id)) {
          id = id == 0x7fffffff ? 1 : id + 1;
        }
        final entry = NotificationJournalEntry(
          reminderId: reminderId,
          nativeId: id,
          action: 'cancel',
          status: 'reserved',
          attempts: 0,
        );
        state.entries[reminderId] = entry;
        await _write(
          state,
        ); // Allocation precedes the first native side effect.
        return entry;
      });

  Future<void> record(
    String epoch,
    String reminderId, {
    required String action,
    required String status,
    int? triggerUtcMicros,
    int? noticeRevision,
    DateTime? attemptedAt,
  }) => _serialize(() async {
    final state = await _require(epoch);
    final previous = state.entries[reminderId];
    if (previous == null) throw StateError('Notification ID not reserved.');
    state.entries[reminderId] = NotificationJournalEntry(
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
    await _write(state);
  });

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
  Future<NotificationJournalSnapshot?> _read() async {
    await _checkDirectory();
    final type = await FileSystemEntity.type(_file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file || await _file.length() > maxBytes) {
      throw const FormatException('Invalid notification journal file.');
    }
    return NotificationJournalSnapshot.decode(
      jsonDecode(await _file.readAsString()),
    );
  }

  Future<void> _write(NotificationJournalSnapshot state) async {
    // Also validate writes, so an invalid caller cannot poison future startup.
    final encoded = jsonEncode(state.toJson());
    NotificationJournalSnapshot.decode(jsonDecode(encoded));
    if (utf8.encode(encoded).length > maxBytes) {
      throw const FormatException('Notification journal size limit reached.');
    }
    final temporary = File('${_file.path}.${const Uuid().v4()}.tmp');
    await _checkDirectory();
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FormatException('Notification journal staging file exists.');
    }
    await temporary.writeAsString(encoded, flush: true);
    await _checkDirectory();
    await _read();
    // Never unlink the last valid target to make replacement succeed.
    await temporary.rename(_file.path);
  }
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
  NotificationJournalSnapshot(this.epoch, this.entries);
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
