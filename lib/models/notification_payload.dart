import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'reminder.dart';

/// A native notification identifies one occurrence in one local data set.
/// Restoring a backup must rotate [datasetEpoch], even when every reminder row
/// is identical, so previously delivered notifications cannot reopen it.
final class NotificationPayload {
  const NotificationPayload._({
    required this.datasetEpoch,
    required this.reminderKey,
    required this.triggerUtcMicros,
    required this.noticeRevision,
  });

  static const version = 1;
  static const maxEncodedLength = 2048;
  static final _epochPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _keyPattern = RegExp(r'^[0-9a-f]{64}$');
  static const _fields = {
    'version',
    'kind',
    'datasetEpoch',
    'reminderKey',
    'triggerUtcMicros',
    'noticeRevision',
  };

  final String datasetEpoch;
  final String reminderKey;
  final int triggerUtcMicros;
  final int noticeRevision;

  static bool isValidDatasetEpoch(String value) =>
      _epochPattern.hasMatch(value);

  factory NotificationPayload.forReminder(
    Reminder reminder, {
    required String datasetEpoch,
  }) {
    if (!isValidDatasetEpoch(datasetEpoch) ||
        reminder.id.trim().isEmpty ||
        reminder.triggerTime == null ||
        reminder.isCompleted ||
        reminder.noticeAcknowledgedAt != null) {
      throw ArgumentError('A notification requires an active occurrence.');
    }
    return NotificationPayload._(
      datasetEpoch: datasetEpoch,
      reminderKey: _keyForReminderId(reminder.id),
      triggerUtcMicros: reminder.triggerTime!.toUtc().microsecondsSinceEpoch,
      noticeRevision: reminder.noticeRevision,
    );
  }

  /// Old, malformed and future formats fail closed. A task ID alone cannot
  /// establish that the click still belongs to the current data set.
  static NotificationPayload? tryParse(String? encoded) {
    if (encoded == null ||
        encoded.isEmpty ||
        encoded.length > maxEncodedLength) {
      return null;
    }
    try {
      final value = jsonDecode(encoded);
      if (value is! Map ||
          value.length != _fields.length ||
          value.keys.any((key) => !_fields.contains(key)) ||
          value['version'] is! int ||
          value['version'] != version ||
          value['kind'] != 'reminder' ||
          value['datasetEpoch'] is! String ||
          !isValidDatasetEpoch(value['datasetEpoch'] as String) ||
          value['reminderKey'] is! String ||
          !_keyPattern.hasMatch(value['reminderKey'] as String) ||
          value['triggerUtcMicros'] is! int ||
          value['noticeRevision'] is! int ||
          (value['noticeRevision'] as int) < 0) {
        return null;
      }
      final micros = value['triggerUtcMicros'] as int;
      // DateTime rejects instants outside its supported calendar range.
      DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
      return NotificationPayload._(
        datasetEpoch: value['datasetEpoch'] as String,
        reminderKey: value['reminderKey'] as String,
        triggerUtcMicros: micros,
        noticeRevision: value['noticeRevision'] as int,
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  // Existing databases and valid backups allow long IDs and embedded NULs.
  // Keep the native payload bounded without rejecting those business rows.
  // JSON first escapes unpaired UTF-16 surrogates so UTF-8 replacement cannot
  // map distinct Dart IDs onto the same input bytes.
  static String _keyForReminderId(String value) => sha256
      .convert(utf8.encode('dontforget-reminder-key-v1:${jsonEncode(value)}'))
      .toString();

  bool matches(Reminder reminder, {required String currentDatasetEpoch}) =>
      datasetEpoch == currentDatasetEpoch &&
      reminderKey == _keyForReminderId(reminder.id) &&
      triggerUtcMicros ==
          reminder.triggerTime?.toUtc().microsecondsSinceEpoch &&
      noticeRevision == reminder.noticeRevision &&
      !reminder.isCompleted &&
      reminder.noticeAcknowledgedAt == null;

  String encode() => jsonEncode({
    'version': version,
    'kind': 'reminder',
    'datasetEpoch': datasetEpoch,
    'reminderKey': reminderKey,
    'triggerUtcMicros': triggerUtcMicros,
    'noticeRevision': noticeRevision,
  });

  String get identity =>
      jsonEncode([datasetEpoch, reminderKey, triggerUtcMicros, noticeRevision]);
}
