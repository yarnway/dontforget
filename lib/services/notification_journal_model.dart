import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/notification_payload.dart';

class NotificationJournalFormat {
  static const fileName = 'notification-journal.json';
  static const storageSelectorFileName = 'notification-storage.json';
  static const maxBytes = 16 * 1024 * 1024;
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
