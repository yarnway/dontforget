// Synthetic acceptance data only. No user data or provider credentials.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show DatabaseFactory;

const attachmentFixturePassword = 'SyntheticAttachments-2026';
const attachmentFixtureMarker = 'dontforget.synthetic.attachments.v1';
final fixtureTime = DateTime.utc(2026, 11, 1, 8);

void requireFixture(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

String canonicalFixture(Object? value) {
  Object? sort(Object? item) {
    if (item is Map) {
      return {
        for (final key in item.keys.cast<String>().toList()..sort())
          key: sort(item[key]),
      };
    }
    if (item is List) return item.map(sort).toList();
    return item;
  }

  return jsonEncode(sort(value));
}

Future<String> fixtureHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Map<String, ({String name, String type, List<int> bytes})> fixtureAssets({
  bool desktop = false,
}) {
  const sampleRate = 16000, samples = sampleRate * 2;
  final wav = ByteData(44 + samples * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      wav.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  wav.setUint32(4, wav.lengthInBytes - 8, Endian.little);
  text(8, 'WAVEfmt ');
  wav.setUint32(16, 16, Endian.little);
  wav.setUint16(20, 1, Endian.little);
  wav.setUint16(22, 1, Endian.little);
  wav.setUint32(24, sampleRate, Endian.little);
  wav.setUint32(28, sampleRate * 2, Endian.little);
  wav.setUint16(32, 2, Endian.little);
  wav.setUint16(34, 16, Endian.little);
  text(36, 'data');
  wav.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    wav.setInt16(
      44 + i * 2,
      (((i % 160 < 80 ? i % 160 : 159 - i % 160) - 40) * 96),
      Endian.little,
    );
  }
  return {
    'fixture-audio': (
      name: '语音 sample.wav',
      type: 'audio',
      bytes: wav.buffer.asUint8List(),
    ),
    'fixture-image': (
      name: '图像示例.png',
      type: 'image',
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jNioAAAAASUVORK5CYII=',
      ),
    ),
    'fixture-file': (
      name: '附件说明.txt',
      type: 'file',
      bytes: utf8.encode(
        List.filled(128, 'Synthetic 中文 · English · 日本語 📎\n').join(),
      ),
    ),
    if (desktop)
      'fixture-desktop': (
        name: 'Desktop note.txt',
        type: 'file',
        bytes: utf8.encode(
          'Added on Windows; restored on Android.\n新增附件，保留原始三份文件。\n',
        ),
      ),
  };
}

List<Reminder> fixtureReminders({bool desktop = false}) => [
  Reminder(
    id: 'fixture-active',
    taskTitle: '附件往返 · 活跃事项',
    quadrantLevel: 2,
    recordId: 'fixture-audio',
    createdAt: fixtureTime,
    detailsJson: const TaskDetails(
      attachmentIds: ['fixture-image', 'fixture-file'],
      tags: ['synthetic'],
      project: '附件验收',
    ).encode(),
  ),
  Reminder(
    id: 'fixture-archive',
    taskTitle: '附件往返 · 已归档',
    quadrantLevel: 4,
    recordId: 'fixture-file',
    createdAt: fixtureTime,
    detailsJson: TaskDetails(archivedAt: fixtureTime).encode(),
  ),
  Reminder(
    id: 'fixture-trash',
    taskTitle: '附件往返 · 回收站',
    quadrantLevel: 3,
    recordId: 'fixture-image',
    createdAt: fixtureTime,
    detailsJson: TaskDetails(deletedAt: fixtureTime).encode(),
  ),
  Reminder(
    id: 'fixture-study',
    taskTitle: '附件往返 · 暂停学习',
    taskSummary: 'apple — fruit',
    quadrantLevel: 2,
    recordId: 'fixture-audio',
    createdAt: fixtureTime,
    nextReviewAt: DateTime.utc(2030, 1, 8, 8),
    spacedRepetitionLevel: 1,
    reviewNotificationsEnabled: true,
    wordProgressJson: jsonEncode({
      'apple': {
        'level': 1,
        'due': '2030-01-08T08:00:00.000Z',
        'reviewed': '2026-11-01T08:00:00.000Z',
        'first': '2026-11-01T08:00:00.000Z',
        'reviews': 1,
        'grade': 1,
      },
    }),
    detailsJson: const TaskDetails(
      kind: 'study',
      paused: true,
      data: {'study_plan_id': 'fixture-study-plan'},
    ).encode(),
  ),
  if (desktop)
    Reminder(
      id: 'fixture-desktop-task',
      taskTitle: 'Windows 新增附件事项',
      quadrantLevel: 3,
      recordId: 'fixture-desktop',
      createdAt: fixtureTime,
      detailsJson: const TaskDetails(attachmentIds: ['fixture-image']).encode(),
    ),
];

Future<void> seedAttachmentFixture(
  DatabaseHelper database,
  Directory root, {
  bool desktopOnly = false,
}) async {
  await root.create(recursive: true);
  final assets = fixtureAssets(desktop: desktopOnly);
  final rows = <MediaRecord>[];
  for (final entry in assets.entries) {
    if (desktopOnly && entry.key != 'fixture-desktop') continue;
    final directory = await Directory(
      p.join(root.path, entry.key),
    ).create(recursive: true);
    final file = File(p.join(directory.path, entry.value.name));
    requireFixture(
      !await file.exists(),
      'Never overwrite a synthetic original',
    );
    await file.writeAsBytes(entry.value.bytes, flush: true);
    rows.add(
      MediaRecord(
        id: entry.key,
        type: entry.value.type,
        contentOrPath: file.absolute.path,
        createdAt: fixtureTime,
      ),
    );
  }
  await database.writeTransaction(database.captureGeneration(), (db) async {
    for (final row in rows) {
      await db.insert('MediaRecords', row.toJson());
    }
    for (final row in fixtureReminders(desktop: desktopOnly)) {
      if (desktopOnly && row.id != 'fixture-desktop-task') continue;
      await db.insert('Reminders', row.toJson());
    }
    if (!desktopOnly) {
      // Public sentinel, deliberately not a real credential. Exports must redact it.
      await db.update('Settings', {
        'api_key': 'synthetic-attachment-sentinel',
        'language': 'zh',
      });
    }
  });
}

Future<Map<String, dynamic>> verifyAttachmentFixture(
  DatabaseHelper database, {
  required bool desktop,
  Directory? restoredRoot,
}) async {
  final data = await database.read(
    database.captureGeneration(),
    (db) async => {
      'reminders': await db.query('Reminders', orderBy: 'id'),
      'media': await db.query('MediaRecords', orderBy: 'id'),
      'settings': await db.query('Settings'),
    },
  );
  final reminders = data['reminders']!, media = data['media']!;
  final expectedRows =
      fixtureReminders(desktop: desktop).map((r) => r.toJson()).toList()
        ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  requireFixture(
    canonicalFixture(reminders) == canonicalFixture(expectedRows),
    'Reminder fields, lifecycle, references or word progress differ',
  );
  final assets = fixtureAssets(desktop: desktop);
  requireFixture(media.length == assets.length, 'Attachment count differs');
  final hashes = <String, String>{};
  for (final row in media) {
    final id = row['id'] as String, path = row['content_or_path'] as String;
    final expected = assets[id];
    requireFixture(expected != null, 'Unexpected media id');
    requireFixture(
      row['type'] == expected!.type &&
          row['created_at'] == fixtureTime.toIso8601String(),
      'Media metadata differs',
    );
    final name = p.basename(path);
    final generated =
        (restoredRoot != null || desktop) &&
        RegExp(r'^attachment-[0-9]+\.[a-z0-9]{1,10}$').hasMatch(name) &&
        p.extension(name) == p.extension(expected.name).toLowerCase();
    requireFixture(
      p.isAbsolute(path) && (name == expected.name || generated),
      'Attachment extension, safe name or path differs',
    );
    if (restoredRoot != null) {
      requireFixture(
        p.isWithin(restoredRoot.absolute.path, File(path).absolute.path),
        'Attachment did not rebase into destination',
      );
    }
    final file = File(path), hash = await fixtureHash(File(path));
    requireFixture(
      await file.length() == expected.bytes.length &&
          hash == sha256.convert(expected.bytes).toString(),
      'Attachment bytes differ',
    );
    hashes[id] = hash;
  }
  requireFixture(data['settings']!.length == 1, 'Settings row count differs');
  return {
    'reminders': reminders.length,
    'media': media.length,
    'all_reminder_fields_equal': true,
    'attachment_hashes': hashes,
    'attachment_bytes': {
      for (final e in assets.entries) e.key: e.value.bytes.length,
    },
    'lifecycle_and_word_progress_preserved': true,
    'restored_filename_policy':
        'Generated safe name; extension retained; original display name not preserved',
    'schema': DatabaseHelper.schemaVersion,
  };
}

Future<void> restoreAttachmentFixture(
  DatabaseHelper database,
  DatabaseFactory factory,
  File source,
  Directory mediaRoot, {
  required bool encrypted,
  required int mediaCount,
}) async {
  const service = StreamingBackupService();
  final password = encrypted ? attachmentFixturePassword : null;
  final preview = await service.inspect(source, password: password);
  requireFixture(
    preview.encrypted == encrypted &&
        preview.mediaCount == mediaCount &&
        preview.missingMedia.isEmpty,
    'Backup preview differs',
  );
  final snapshot = await service.prepareRestore(
    source,
    mediaRoot,
    expectedDigest: preview.digest,
    isCurrent: () => true,
    password: password,
  );
  final data = jsonDecode(await snapshot.readAsString()) as Map;
  final settings = (data['settings'] as List).single as Map;
  requireFixture(
    settings['api_key'] == '',
    'Source credential was not excluded',
  );
  final inspector = BackupInspector(factory),
      inspected = await BackupInspector(factory).inspect(snapshot);
  requireFixture(
    !inspected.containsCredentials &&
        inspected.missingMedia == 0 &&
        inspected.unresolvedReferences == 0,
    'Restored snapshot contains missing references or credentials',
  );
  await DatabaseRecovery(
    database,
    inspector: inspector,
    // ignore: invalid_use_of_visible_for_testing_member
    notifications: NotificationService.forTesting(
      FlutterLocalNotificationsPlugin(),
      usesNativeNotifications: false,
    ),
  ).restore(snapshot, expectedDigest: inspected.digest);
}
