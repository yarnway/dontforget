import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/database_helper.dart';
import '../../models/legacy_credentials.dart';
import '../../models/reminder.dart';
import '../notification_service.dart';
import 'backup_inspector.dart';

enum RecoveryCheckpoint {
  candidateReady,
  rollbackReady,
  journalPrepared,
  originalMoved,
  candidateInstalled,
  candidateOpened,
  committed,
  rollbackStarted,
  rollbackInstalled,
}

/// Test fault injection models termination, which must leave the journal intact.
class RecoveryInterruption implements Exception {
  const RecoveryInterruption();
}

class DatabaseRecoveryException implements Exception {
  const DatabaseRecoveryException({required this.rolledBack});
  final bool rolledBack;

  @override
  String toString() => rolledBack
      ? 'DatabaseRecoveryException(rolledBack)'
      : 'DatabaseRecoveryException(recoveryRequired)';
}

class DatabaseRecoveryResult {
  const DatabaseRecoveryResult(this.operationId, this.rollbackDirectory);
  final String operationId;
  final String rollbackDirectory;
}

/// Internal recovery engine. The UI must not expose replacement until it can
/// coordinate producer shutdown, notification reconciliation and confirmation.
/// Files are retained per operation; fixed mirror/JSON backups are never used
/// as rollback material. Flush + rename covers process interruption, not a
/// claim of directory-fsync durability during sudden device power loss.
class DatabaseRecovery {
  DatabaseRecovery(
    this.database, {
    BackupInspector? inspector,
    NotificationService? notifications,
    this.checkpoint,
  }) : inspector = inspector ?? BackupInspector.platform(),
       notifications = notifications ?? NotificationService();

  final DatabaseHelper database;
  final BackupInspector inspector;
  final NotificationService notifications;
  final Future<void> Function(RecoveryCheckpoint)? checkpoint;
  static const journalName = 'recovery.pending.json';

  Future<void> _at(RecoveryCheckpoint point) async => checkpoint?.call(point);

  Future<DatabaseRecoveryResult> restore(
    File source, {
    required String expectedDigest,
  }) async {
    if (!_hashPattern.hasMatch(expectedDigest)) {
      throw const DatabaseRecoveryException(rolledBack: false);
    }
    final preview = await inspector.inspect(source);
    if (preview.digest != expectedDigest) {
      throw const BackupInspectionException(
        BackupInspectionError.sourceChanged,
      );
    }
    // Ensure the old database exists and is readable before taking maintenance.
    final generation = database.captureGeneration();
    await database.read(
      generation,
      (db) => db.rawQuery('PRAGMA integrity_check'),
    );
    final lease = await database.beginMaintenance();
    _RecoveryJournal? journal;
    var committed = false;
    var paused = false;
    try {
      await notifications.pauseForMaintenance();
      paused = true;
      final pending = File(p.join(lease.directory, journalName));
      if (await pending.exists()) throw const FormatException();
      final id = const Uuid().v4();
      final operation = Directory(p.join(lease.directory, 'recovery-$id'));
      await operation.create();
      final input = File(p.join(operation.path, 'source.backup'));
      await _copyBounded(source, input, inspector.maxBytes);
      if (await _digest(input) != expectedDigest) {
        throw const BackupInspectionException(
          BackupInspectionError.sourceChanged,
        );
      }
      await inspector.inspect(input);
      final candidate = File(p.join(operation.path, 'candidate.db'));
      final header = await input.open();
      late final List<int> prefix;
      try {
        prefix = await header.read(16);
      } finally {
        await header.close();
      }
      if (ascii.decode(prefix, allowInvalid: true) == 'SQLite format 3\u0000') {
        await _copyBounded(input, candidate, inspector.maxBytes);
      } else {
        final decoded = jsonDecode(await input.readAsString()) as Map;
        if (preview.version < 8) {
          for (final row in decoded['settings'] as List) {
            if (isLegacyBundledCredential(row['api_key'] as String? ?? '')) {
              row['api_key'] = '';
            }
          }
        }
        await lease.createCandidateFromRows(candidate.path, {
          for (final pair in const {
            'Settings': 'settings',
            'MediaRecords': 'media_records',
            'Reminders': 'reminders',
          }.entries)
            pair.key: [
              for (final row in decoded[pair.value] as List)
                Map<String, Object?>.from(row as Map),
            ],
        });
      }
      await lease.validateCandidate(candidate.path);
      await inspector.inspect(candidate);
      await _requireRollbackJournal(candidate);
      await _at(RecoveryCheckpoint.candidateReady);
      await lease.closeWithoutBackup();
      await _requireStandalone(lease.path);
      final original = File(lease.path);
      await _requireRollbackJournal(original);
      final rollback = File(p.join(operation.path, 'rollback.db'));
      await _copyBounded(original, rollback, null);
      final oldDigest = await _digest(original);
      if (await _digest(rollback) != oldDigest) throw const FormatException();
      await _at(RecoveryCheckpoint.rollbackReady);
      journal = _RecoveryJournal(
        id,
        oldDigest,
        await _digest(candidate),
        'prepared',
      );
      await _writeJournal(pending, journal);
      await _at(RecoveryCheckpoint.journalPrepared);
      await original.rename(p.join(operation.path, 'displaced.db'));
      await _at(RecoveryCheckpoint.originalMoved);
      await _install(candidate, original, operation);
      await _at(RecoveryCheckpoint.candidateInstalled);
      await lease.validateAndOpen();
      await _at(RecoveryCheckpoint.candidateOpened);
      journal = journal.withState('committed');
      await _writeJournal(pending, journal);
      committed = true;
      await _at(RecoveryCheckpoint.committed);
      // External notifications cannot be rolled back after delivery. Record
      // the durable data decision before any candidate notification is enabled.
      // A later rebuild failure keeps this committed journal for startup retry.
      await _resumeNotifications(lease);
      await _archiveJournal(pending, operation, 'completed.json');
      await lease.resume();
      return DatabaseRecoveryResult(id, operation.path);
    } on RecoveryInterruption {
      lease.fail();
      rethrow;
    } catch (_) {
      try {
        if (committed || !paused) {
          // The durable commit is the decision. Never roll it back because
          // notification rebuilding or archival failed; startup must finish
          // that same decision.
          throw const DatabaseRecoveryException(rolledBack: false);
        }
        if (journal != null) {
          await _rollback(lease, journal);
        } else {
          await lease.validateAndOpen();
          await _resumeNotifications(lease);
          await lease.resume();
        }
      } catch (_) {
        await _keepNotificationsPaused();
        lease.fail();
        throw const DatabaseRecoveryException(rolledBack: false);
      }
      throw const DatabaseRecoveryException(rolledBack: true);
    }
  }

  /// Called before ProviderScope, CLI queries, migrations or scheduling.
  /// An incomplete operation rolls back; a durable committed operation finishes
  /// its commit. Unknown/corrupt identities block startup and preserve files.
  Future<void> recoverInterrupted() async {
    final directory = await database.acquireOwnership();
    final pending = File(p.join(directory, journalName));
    if (await FileSystemEntity.type(pending.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final lease = await database.beginMaintenance();
    try {
      await notifications.pauseForMaintenance();
      final journal = await _readJournal(pending);
      final operation = Directory(p.join(directory, 'recovery-${journal.id}'));
      await _requireDirectory(operation);
      await lease.closeWithoutBackup();
      if (journal.state == 'committed') {
        await _requireDigest(File(lease.path), journal.newDigest);
        await _requireRollbackJournal(File(lease.path));
        await _requireStandalone(lease.path);
        await lease.validateAndOpen();
        await _resumeNotifications(lease);
        await _archiveJournal(pending, operation, 'completed.json');
        await lease.resume();
      } else {
        await _rollback(lease, journal);
      }
    } catch (_) {
      await _keepNotificationsPaused();
      lease.fail();
      throw const DatabaseRecoveryException(rolledBack: false);
    }
  }

  Future<void> _rollback(
    DatabaseMaintenanceLease lease,
    _RecoveryJournal journal,
  ) async {
    // Retry native cancellation even when already paused: a failed rebuild
    // may have left candidate-only requests after its cleanup also failed.
    await notifications.pauseForMaintenance();
    await lease.closeWithoutBackup();
    final operation = Directory(
      p.join(lease.directory, 'recovery-${journal.id}'),
    );
    await _requireDirectory(operation);
    final rollback = File(p.join(operation.path, 'rollback.db'));
    await _requireDigest(rollback, journal.oldDigest);
    await _requireRollbackJournal(rollback);
    await _requireStandalone(lease.path);
    final current = File(lease.path);
    final currentType = await FileSystemEntity.type(
      current.path,
      followLinks: false,
    );
    if (currentType != FileSystemEntityType.notFound) {
      if (currentType != FileSystemEntityType.file) {
        throw const FormatException();
      }
      await _requireRollbackJournal(current);
      final hash = await _digest(current);
      if (hash != journal.oldDigest && hash != journal.newDigest) {
        throw const FormatException();
      }
    }
    final pending = File(p.join(lease.directory, journalName));
    await _writeJournal(pending, journal.withState('rollingBack'));
    await _at(RecoveryCheckpoint.rollbackStarted);
    if (await current.exists()) {
      // Unique preservation file also makes interrupted rollback retryable.
      await current.rename(
        p.join(operation.path, 'rejected-${const Uuid().v4()}.db'),
      );
    }
    await _install(rollback, current, operation);
    await _at(RecoveryCheckpoint.rollbackInstalled);
    await _requireDigest(current, journal.oldDigest);
    await lease.validateAndOpen();
    await _resumeNotifications(lease);
    await _archiveJournal(pending, operation, 'rolled-back.json');
    await lease.resume();
  }

  Future<void> _resumeNotifications(DatabaseMaintenanceLease lease) async {
    final rows = await lease.read((db) => db.query('Reminders'));
    await notifications.resumeFromReminders(rows.map(Reminder.fromJson));
  }

  Future<void> _keepNotificationsPaused() async {
    if (!notifications.isPausedForMaintenance) {
      try {
        await notifications.pauseForMaintenance();
      } catch (_) {
        // Its paused flag is retained even if native cancellation fails.
      }
    }
  }
}

final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
final _idPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class _RecoveryJournal {
  const _RecoveryJournal(this.id, this.oldDigest, this.newDigest, this.state);
  final String id;
  final String oldDigest;
  final String newDigest;
  final String state;
  _RecoveryJournal withState(String value) =>
      _RecoveryJournal(id, oldDigest, newDigest, value);
  Map<String, Object> toJson() => {
    'version': 1,
    'operationId': id,
    'oldDigest': oldDigest,
    'newDigest': newDigest,
    'state': state,
  };
}

Future<_RecoveryJournal> _readJournal(File file) async {
  await _requireRegular(file);
  if (await file.length() > 4096) throw const FormatException();
  final map = jsonDecode(await file.readAsString());
  if (map is! Map ||
      map.length != 5 ||
      map['version'] != 1 ||
      map['operationId'] is! String ||
      !_idPattern.hasMatch(map['operationId']) ||
      map['oldDigest'] is! String ||
      !_hashPattern.hasMatch(map['oldDigest']) ||
      map['newDigest'] is! String ||
      !_hashPattern.hasMatch(map['newDigest']) ||
      !const ['prepared', 'rollingBack', 'committed'].contains(map['state'])) {
    throw const FormatException();
  }
  return _RecoveryJournal(
    map['operationId'],
    map['oldDigest'],
    map['newDigest'],
    map['state'],
  );
}

Future<void> _writeJournal(File file, _RecoveryJournal journal) async {
  final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
  await temporary.writeAsString(jsonEncode(journal.toJson()), flush: true);
  await temporary.rename(file.path);
}

Future<void> _archiveJournal(
  File pending,
  Directory operation,
  String name,
) async {
  final target = File(p.join(operation.path, name));
  if (await target.exists()) throw const FormatException();
  await pending.rename(target.path);
}

Future<void> _install(File source, File target, Directory operation) async {
  final staging = File(
    p.join(operation.path, 'install-${const Uuid().v4()}.db'),
  );
  await _copyBounded(source, staging, null);
  if (await _digest(staging) != await _digest(source)) {
    throw const FormatException();
  }
  await staging.rename(target.path);
}

Future<void> _copyBounded(File source, File target, int? limit) async {
  await _requireRegular(source);
  final output = await target.open(mode: FileMode.write);
  var total = 0;
  try {
    await for (final bytes in source.openRead()) {
      total += bytes.length;
      if (limit != null && total > limit) {
        throw const BackupInspectionException(BackupInspectionError.tooLarge);
      }
      await output.writeFrom(bytes);
    }
    await output.flush();
  } finally {
    await output.close();
  }
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _requireRegular(File file) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException();
  }
}

Future<void> _requireDirectory(Directory directory) async {
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException();
  }
}

Future<void> _requireDigest(File file, String digest) async {
  await _requireRegular(file);
  if (await _digest(file) != digest) throw const FormatException();
}

Future<void> _requireStandalone(String path) async {
  for (final suffix in ['-wal', '-shm', '-journal']) {
    if (await FileSystemEntity.type('$path$suffix', followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FormatException();
    }
  }
}

/// This file-replacement protocol does not yet own or recover WAL bundles.
/// A checkpointed WAL database can have no sidecars but recreate them on open.
/// Refuse both candidate and live WAL headers before any replacement begins.
Future<void> _requireRollbackJournal(File file) async {
  await _requireRegular(file);
  final handle = await file.open();
  try {
    final header = await handle.read(20);
    if (header.length != 20 || header[18] != 1 || header[19] != 1) {
      throw const FormatException('WAL recovery is not supported yet.');
    }
  } finally {
    await handle.close();
  }
}
