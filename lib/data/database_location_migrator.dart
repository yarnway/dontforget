import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/storage_directory_lease.dart';

/// An ambiguous target must not silently select an older database or a new path.
class DatabaseLocationMigrationException implements Exception {
  const DatabaseLocationMigrationException();
}

/// Fault injection models process termination at a durable boundary.
class LocationMigrationInterruption implements Exception {
  const LocationMigrationInterruption();
}

enum LocationMigrationCheckpoint {
  staged,
  prepared,
  sidecarsPublished,
  databasePublished,
}

/// Moves a quiescent legacy store without changing its schema or source bytes.
/// The main DB is the commit marker: publish it after every operational sidecar.
/// A durable intent blocks opening any partially published target after a crash.
class DatabaseLocationMigrator {
  static const databaseFileName = 'dont_forget_v3.db';
  static const pendingName = 'location-migration.pending.json';
  static const receiptName = 'migration.log';
  static const _managed = 'notification-incremental';
  static const _stagePrefix = '.dontforget-location-stage-';
  static const _maxBytes = 1024 * 1024 * 1024;
  static const _maxFiles = 300;
  static const sidecarFiles = [
    databaseFileName,
    'notification-epoch.json',
    'notification-journal.json',
    'notification-journal.log',
    'notification-storage.json',
    'device-window-preferences.json',
  ];
  static const _activeFiles = [
    '$databaseFileName-wal',
    '$databaseFileName-shm',
    '$databaseFileName-journal',
    'recovery.pending.json',
    'notification-rollback.intent.json',
  ];
  static final _resolving = <String, Future<String>>{};

  static Future<String> resolveAndMigrate({
    required String targetDir,
    List<String>? candidateLegacyDirs,
  }) {
    final key = p.normalize(p.absolute(targetDir));
    final existing = _resolving[key];
    if (existing != null) return existing;
    late final Future<String> operation;
    operation =
        _resolve(
          targetDir,
          List.of(candidateLegacyDirs ?? getLegacyCandidates()),
        ).whenComplete(() {
          if (identical(_resolving[key], operation)) _resolving.remove(key);
        });
    return _resolving[key] = operation;
  }

  static Future<String> _resolve(String target, List<String> candidates) async {
    // A legacy recovery journal has precedence even when it temporarily moved
    // the target DB away. Never resurrect an older candidate in that gap.
    if (await _exists(p.join(target, pendingName))) {
      final directory = await _safeDirectory(target);
      final lease = await StorageDirectoryLease.acquire(directory);
      try {
        await _recover(directory);
      } finally {
        await lease.close();
      }
    }
    if (await _exists(p.join(target, databaseFileName))) {
      await _requireFile(File(p.join(target, databaseFileName)));
      return target;
    }
    if (await _exists(p.join(target, 'recovery.pending.json'))) return target;
    for (final candidate in candidates) {
      if (await _exists(p.join(candidate, 'recovery.pending.json'))) {
        return candidate;
      }
      if (await _exists(p.join(candidate, pendingName))) {
        throw const DatabaseLocationMigrationException();
      }
      if (!await _exists(p.join(candidate, databaseFileName))) {
        if (await Directory(candidate).exists()) {
          await _requireEmptyStore(Directory(candidate));
        }
        continue;
      }
      await _requireFile(File(p.join(candidate, databaseFileName)));
      return await migrateDirectory(
            sourceDir: candidate,
            destinationDir: target,
          )
          ? target
          : candidate;
    }
    // Even with no legacy candidate, don't initialize an empty DB over an
    // incomplete store whose origin cannot be established.
    if (await Directory(target).exists()) {
      await _requireEmptyStore(Directory(target));
    }
    return target;
  }

  static List<String> getLegacyCandidates() {
    if (!Platform.isWindows) return const [];
    final appData = Platform.environment['APPDATA'];
    final local = Platform.environment['LOCALAPPDATA'];
    return [
      if (appData != null && appData.isNotEmpty) ...[
        p.join(appData, 'com.example', 'DontForget', 'databases'),
        p.join(appData, 'com.example', 'dont_forget', 'databases'),
      ],
      if (local != null && local.isNotEmpty)
        p.join(local, 'DontForget', 'databases'),
    ];
  }

  static Future<bool> migrateDirectory({
    required String sourceDir,
    required String destinationDir,
    Future<void> Function(LocationMigrationCheckpoint)? checkpoint,
  }) async {
    final source = await _safeDirectory(sourceDir);
    final targetPath = p.normalize(p.absolute(destinationDir));
    if (p.equals(source.path, targetPath) ||
        p.isWithin(source.path, targetPath) ||
        p.isWithin(targetPath, source.path)) {
      throw const DatabaseLocationMigrationException();
    }
    // A directory creation failure can use the original legacy store. Once a
    // target exists, ownership/recovery errors must reach startup unchanged.
    Directory target;
    try {
      await Directory(targetPath).create(recursive: true);
      target = await _safeDirectory(targetPath);
    } on FileSystemException {
      return false;
    }
    if (p.equals(source.path, target.path) ||
        p.isWithin(source.path, target.path) ||
        p.isWithin(target.path, source.path)) {
      throw const DatabaseLocationMigrationException();
    }
    final targetLease = await StorageDirectoryLease.acquire(target);
    StorageDirectoryLease? sourceLease;
    Database? sql;
    Directory? stage;
    var interrupted = false;
    var sqlLocked = false;
    try {
      if (await _exists(p.join(target.path, pendingName)) &&
          await _recover(target)) {
        return true;
      }
      if (await _exists(p.join(target.path, databaseFileName))) {
        await _requireFile(File(p.join(target.path, databaseFileName)));
        return true;
      }
      if (await _exists(p.join(target.path, 'recovery.pending.json'))) {
        return true;
      }
      await _requireEmptyStore(target);
      try {
        sourceLease = await StorageDirectoryLease.acquire(source);
      } on FileSystemException {
        throw const DatabaseLocationMigrationException();
      }
      for (final name in _activeFiles) {
        if (await _exists(p.join(source.path, name))) return false;
      }
      if (await _exists(p.join(source.path, pendingName))) return false;
      final database = File(p.join(source.path, databaseFileName));
      await _requireFile(database);
      final header = await database.open();
      late List<int> prefix;
      try {
        prefix = await header.read(20);
      } finally {
        await header.close();
      }
      // WAL stores stay at the original location, even with no current WAL:
      // opening them read-only can create shared memory or need crash recovery.
      if (prefix.length != 20 ||
          ascii.decode(prefix.take(16).toList(), allowInvalid: true) !=
              'SQLite format 3\u0000' ||
          prefix[18] != 1 ||
          prefix[19] != 1) {
        return false;
      }
      sqfliteFfiInit();
      sql = await databaseFactoryFfi.openDatabase(
        database.uri.replace(queryParameters: {'mode': 'rw'}).toString(),
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await sql.execute('PRAGMA busy_timeout = 0');
      await sql.execute('PRAGMA trusted_schema = OFF');
      // A read-only connection downgrades EXCLUSIVE to a shared read lock.
      // mode=rw forbids creating a missing source; no write SQL is executed.
      // This rejects older live clients that predate directory leases.
      await sql.execute('BEGIN EXCLUSIVE');
      sqlLocked = true;
      await sql.execute('PRAGMA query_only = ON');
      final check = await sql.rawQuery('PRAGMA quick_check(1)');
      if (check.length != 1 || check.single.values.single != 'ok') return false;
      final before = await _inventory(source);
      stage = await target.createTemp(_stagePrefix);
      for (final name in before.keys) {
        final destination = File(p.join(stage.path, name));
        await destination.parent.create(recursive: true);
        final output = await destination.open(mode: FileMode.write);
        try {
          await for (final bytes in File(
            p.join(source.path, name),
          ).openRead()) {
            await output.writeFrom(bytes);
          }
          await output.flush();
        } finally {
          await output.close();
        }
        if (await _digest(destination) != before[name]) {
          throw const FormatException();
        }
      }
      if (!_same(before, await _inventory(source))) {
        throw const FormatException();
      }
      final receipt = File(p.join(stage.path, receiptName));
      await receipt.writeAsString(
        jsonEncode({'version': 1, 'source': source.path, 'files': before}),
        flush: true,
      );
      final files = {...before, receiptName: await _digest(receipt)};
      await checkpoint?.call(LocationMigrationCheckpoint.staged);
      if (!_same(before, await _inventory(source))) {
        throw const FormatException();
      }
      for (final name in _activeFiles) {
        if (await _exists(p.join(source.path, name))) {
          throw const FormatException();
        }
      }
      await _requireEmptyStore(target, allowedStage: p.basename(stage.path));
      final intent = File(p.join(stage.path, pendingName));
      await intent.writeAsString(
        jsonEncode({
          'version': 1,
          'stage': p.basename(stage.path),
          'source': source.path,
          'files': files,
        }),
        flush: true,
      );
      await intent.rename(p.join(target.path, pendingName));
      await checkpoint?.call(LocationMigrationCheckpoint.prepared);
      for (final name in files.keys.where((name) => name != databaseFileName)) {
        await _publish(stage, target, name);
      }
      await checkpoint?.call(LocationMigrationCheckpoint.sidecarsPublished);
      await _publish(stage, target, databaseFileName);
      await checkpoint?.call(LocationMigrationCheckpoint.databasePublished);
      await _recover(target);
      return true;
    } on LocationMigrationInterruption {
      interrupted = true;
      rethrow;
    } on DatabaseLocationMigrationException {
      rethrow;
    } catch (error) {
      if (sql != null && !sqlLocked) {
        throw const DatabaseLocationMigrationException();
      }
      debugPrint('Legacy location migration stopped: ${error.runtimeType}');
      if (await _exists(p.join(target.path, pendingName))) {
        return await _recover(target, sourceLease: sourceLease);
      }
      return false;
    } finally {
      try {
        if (sql != null) {
          try {
            if (sqlLocked) await sql.execute('ROLLBACK');
          } finally {
            await sql.close();
          }
        }
      } finally {
        try {
          await sourceLease?.close();
        } finally {
          try {
            if (!interrupted &&
                stage != null &&
                await stage.exists() &&
                !await _exists(p.join(target.path, pendingName))) {
              await stage.delete(recursive: true);
            }
          } finally {
            await targetLease.close();
          }
        }
      }
    }
  }

  static Future<bool> _exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  static Future<Directory> _safeDirectory(String path) async {
    final directory = Directory(p.normalize(p.absolute(path)));
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const DatabaseLocationMigrationException();
    }
    // Windows may redirect RoamingAppData through a parent junction. The leaf
    // itself must be a real directory; use its canonical root for every lease
    // and subsequent file operation, as DatabaseHelper already does.
    return Directory(await directory.resolveSymbolicLinks());
  }

  static Future<void> _requireFile(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const DatabaseLocationMigrationException();
    }
  }

  static Future<String> _digest(File file) async {
    await _requireFile(file);
    return (await sha256.bind(file.openRead()).first).toString();
  }

  static Future<Map<String, String>> _inventory(Directory directory) async {
    final result = <String, String>{};
    var bytes = 0;
    Future<void> add(String name) async {
      final file = File(p.join(directory.path, name));
      await _requireFile(file);
      bytes += await file.length();
      if (bytes > _maxBytes || result.length >= _maxFiles) {
        throw const FormatException();
      }
      result[name] = await _digest(file);
    }

    for (final name in sidecarFiles) {
      if (await _exists(p.join(directory.path, name))) await add(name);
    }
    final managed = Directory(p.join(directory.path, _managed));
    if (await _exists(managed.path)) {
      await _safeDirectory(managed.path);
      await for (final entry in managed.list(followLinks: false)) {
        if (!await _isManagedFile(p.basename(entry.path))) {
          throw const FormatException();
        }
        await add(p.join(_managed, p.basename(entry.path)));
      }
    }
    return result;
  }

  static Future<bool> _isManagedFile(String name) async =>
      const [
        'current.json',
        'retained.json',
        'source-v1.json',
      ].contains(name) ||
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(json|log)$',
      ).hasMatch(name);

  static bool _same(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  static Future<void> _requireEmptyStore(
    Directory directory, {
    String? allowedStage,
  }) async {
    await for (final entry in directory.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (name.startsWith(_stagePrefix) && name != allowedStage) {
        throw const DatabaseLocationMigrationException();
      }
    }
    for (final name in [
      ...sidecarFiles,
      ..._activeFiles,
      _managed,
      pendingName,
      receiptName,
    ]) {
      if (await _exists(p.join(directory.path, name))) {
        throw const DatabaseLocationMigrationException();
      }
    }
  }

  static Future<void> _publish(
    Directory stage,
    Directory target,
    String name,
  ) async {
    final destination = File(p.join(target.path, name));
    if (await _exists(destination.path)) {
      throw const DatabaseLocationMigrationException();
    }
    await destination.parent.create(recursive: true);
    await File(p.join(stage.path, name)).rename(destination.path);
  }

  /// Returns true for a committed DB; otherwise removes only verified partial
  /// files from this intent. Changed/unknown files leave the gate closed.
  static Future<bool> _recover(
    Directory target, {
    StorageDirectoryLease? sourceLease,
  }) async {
    final pending = File(p.join(target.path, pendingName));
    await _requireFile(pending);
    if (await pending.length() > 65536) {
      throw const DatabaseLocationMigrationException();
    }
    final raw = await pending.readAsString();
    final data = jsonDecode(raw);
    if (data is! Map ||
        data.length != 4 ||
        data['source'] is! String ||
        !p.isAbsolute(data['source']) ||
        data['version'] != 1 ||
        data['stage'] is! String ||
        !RegExp(
          r'^\.dontforget-location-stage-[A-Za-z0-9_-]+$',
        ).hasMatch(data['stage']) ||
        data['files'] is! Map) {
      throw const DatabaseLocationMigrationException();
    }
    final files = Map<String, dynamic>.from(data['files']);
    if (files.length > _maxFiles + 1 ||
        !files.containsKey(databaseFileName) ||
        !files.containsKey(receiptName)) {
      throw const DatabaseLocationMigrationException();
    }
    final stage = Directory(p.join(target.path, data['stage']));
    if (await _exists(stage.path)) await _safeDirectory(stage.path);
    for (final directory in [target, stage]) {
      final managed = Directory(p.join(directory.path, _managed));
      if (await _exists(managed.path)) {
        await _safeDirectory(managed.path);
        await for (final entry in managed.list(followLinks: false)) {
          if (entry is! File ||
              !files.containsKey(p.join(_managed, p.basename(entry.path)))) {
            throw const DatabaseLocationMigrationException();
          }
        }
      }
    }
    for (final entry in files.entries) {
      final name = entry.key;
      final parts = p.split(name);
      if (!(sidecarFiles.contains(name) ||
              name == receiptName ||
              (parts.length == 2 &&
                  parts.first == _managed &&
                  await _isManagedFile(parts.last))) ||
          entry.value is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value)) {
        throw const DatabaseLocationMigrationException();
      }
      for (final directory in [target, stage]) {
        final file = File(p.join(directory.path, name));
        if (await _exists(file.path) && await _digest(file) != entry.value) {
          throw const DatabaseLocationMigrationException();
        }
      }
    }
    final committed = await _exists(p.join(target.path, databaseFileName));
    if (committed &&
        files.keys.any(
          (name) => !File(p.join(target.path, name)).existsSync(),
        )) {
      throw const DatabaseLocationMigrationException();
    }
    // Before rolling back, establish that the original complete source still
    // exists unchanged. Otherwise staging may now be the only usable copy.
    if (!committed) {
      final source = await _safeDirectory(data['source']);
      StorageDirectoryLease? temporaryLease;
      try {
        if (sourceLease == null) {
          temporaryLease = await StorageDirectoryLease.acquire(source);
        } else {
          sourceLease.checkHeld();
          if (!p.equals(sourceLease.directory.path, source.path)) {
            throw const DatabaseLocationMigrationException();
          }
        }
        for (final name in _activeFiles) {
          if (await _exists(p.join(source.path, name))) {
            throw const DatabaseLocationMigrationException();
          }
        }
        final expected = Map<String, String>.from(files)..remove(receiptName);
        if (!_same(expected, await _inventory(source))) {
          throw const DatabaseLocationMigrationException();
        }
      } finally {
        await temporaryLease?.close();
      }
    }
    // Validate the entire intent before deleting any file.
    if (await stage.exists()) {
      await for (final entry in stage.list(
        recursive: true,
        followLinks: false,
      )) {
        final name = p.relative(entry.path, from: stage.path);
        if (entry is Directory && name == _managed) continue;
        if (entry is! File || !files.containsKey(name)) {
          throw const DatabaseLocationMigrationException();
        }
      }
    }
    if (!committed) {
      for (final name in files.keys) {
        final file = File(p.join(target.path, name));
        if (await file.exists()) await file.delete();
      }
      final managed = Directory(p.join(target.path, _managed));
      if (await managed.exists() && (await managed.list().toList()).isEmpty) {
        await managed.delete();
      }
    }
    if (await stage.exists()) await stage.delete(recursive: true);
    if (await pending.readAsString() != raw) {
      throw const DatabaseLocationMigrationException();
    }
    await pending.delete();
    return committed;
  }
}
