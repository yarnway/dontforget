import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show DatabaseExecutor;
import 'package:uuid/uuid.dart';
import '../../data/database_helper.dart';
import '../../models/media_record.dart';
import '../../models/stored_json.dart';
import '../local_media_store.dart';
import 'owned_material_activity.dart';
import 'retained_media_references.dart';

enum ContentEntryKind { record, original, restore }

class ContentCleanupEntry {
  ContentCleanupEntry({
    required this.key,
    required this.label,
    required this.kind,
    required this.files,
    required this.bytes,
    required this.reason,
    this.record,
  });
  final String key, label;
  final ContentEntryKind kind;
  final List<String> files;
  final int bytes;

  /// Empty means eligible. Referenced/recent/active/unknown entries are protected.
  final String reason;
  final Map<String, dynamic>? record;
  bool get eligible => reason.isEmpty;
  String get signature => jsonEncode([key, record, files, bytes, reason]);
}

class ContentInventory {
  ContentInventory(this.entries, this.pendingJobs);
  final List<ContentCleanupEntry> entries;
  final List<String> pendingJobs;
}

class ContentCleanupPlan {
  ContentCleanupPlan._(this.entries, this.fingerprints);
  final List<ContentCleanupEntry> entries;
  final Map<String, String> fingerprints;
  int get bytes => entries.fold(0, (n, e) => n + e.bytes);
}

class ContentCleanupResult {
  const ContentCleanupResult(this.records, this.files, this.pending);
  final int records, files;
  final bool pending;
}

/// Never removes exports, automatic backups or recovery rollback material.
/// Only the current Documents/media/import-* layout can lose physical files.
class ContentCleanupService {
  ContentCleanupService(
    this.database,
    this.documents, {
    DateTime Function()? clock,
    this.beforePurge,
  }) : clock = clock ?? DateTime.now;
  final DatabaseHelper database;
  final Directory documents;
  final DateTime Function() clock;

  /// A fault-injection seam; production leaves this unset.
  final Future<void> Function()? beforePurge;
  static const retention = Duration(hours: 24);
  static const cleanupKey = '_contentCleanupV1';
  static const journalName = 'cleanup.json';
  static final _import = RegExp(r'^import-[A-Za-z0-9_-]+$');
  static final _job = RegExp(r'^\.cleanup-[a-f0-9-]{36}$');
  Future<String> _root() async {
    final doc = await documents.resolveSymbolicLinks();
    final root = p.join(doc, 'media');
    final type = await FileSystemEntity.type(root, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FormatException('Unsafe media directory');
    }
    return root;
  }

  static bool _hasTraversal(String path) {
    for (final part in path.split(RegExp(r'[/\\]'))) {
      if (part == '.' || part == '..') return true;
    }
    return false;
  }

  Future<String?> _owned(String path, String root) async {
    final file = File(path);
    if (!file.isAbsolute ||
        _hasTraversal(path) ||
        !_import.hasMatch(p.basename(p.dirname(path)))) {
      return null;
    }
    final parent = Directory(p.dirname(path));
    if (await FileSystemEntity.type(parent.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final canonical = await parent.resolveSymbolicLinks();
    if (!p.equals(p.dirname(canonical), root) ||
        !_import.hasMatch(p.basename(canonical))) {
      return null;
    }
    final result = p.join(canonical, p.basename(path));
    if (await FileSystemEntity.type(result, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
    return p.equals(path, result) ? path : result;
  }

  Future<_Graph> _graph(DatabaseExecutor db, String root) async {
    final rawMedia = await db.query('MediaRecords', limit: 100001);
    final reminders = await db.query('Reminders', limit: 100001);
    final settings = await db.query(
      'Settings',
      where: 'id = ?',
      whereArgs: ['default'],
    );
    if (rawMedia.length > 100000 ||
        reminders.length > 100000 ||
        settings.length != 1) {
      throw const FormatException('Content inventory too large or unavailable');
    }
    final rows = {
      for (final row in rawMedia)
        row['id'] as String: Map<String, dynamic>.from(row),
    };
    final referenced = <String>{}, pathReferences = <String>{};
    var nodes = 0;
    void collect(dynamic value, [int depth = 0]) {
      if (++nodes > 1000000 || depth > 64) {
        throw const FormatException('References too complex');
      }
      if (value is String) {
        if (rows.containsKey(value)) referenced.add(value);
        if (p.isAbsolute(value) && !_hasTraversal(value)) {
          pathReferences.add(p.normalize(value));
        }
      } else if (value is List) {
        for (final item in value) {
          collect(item, depth + 1);
        }
      } else if (value is Map) {
        for (final item in value.values) {
          collect(item, depth + 1);
        }
      }
    }

    for (final row in reminders) {
      collect(row['record_id']);
      for (final field in ['details_json', 'capture_proposal_json']) {
        final value = row[field];
        if (value != null) collect(decodeStoredJson(value as String));
      }
    }
    final rawDrafts = settings.single['workspace_drafts_json'];
    final drafts = rawDrafts == null
        ? <String, dynamic>{}
        : decodeStoredJson(rawDrafts as String);
    if (drafts is! Map<String, dynamic>) {
      throw const FormatException('Invalid workspace references');
    }
    collect(drafts);
    final directReferences = Set<String>.of(pathReferences);
    final owned = <String, String>{}, owners = <String, Set<String>>{};
    final resolver = LocalMediaStore(documentsDirectory: () async => documents);
    for (final entry in rows.entries) {
      final record = MediaRecord.fromJson(entry.value);
      if (record.type == 'text') continue;
      final resolved = await resolver.resolvePath(record.contentOrPath);
      if (p.isAbsolute(resolved)) pathReferences.add(p.normalize(resolved));
      final path = await _owned(resolved, root);
      if (path != null) {
        owned[entry.key] = path;
        owners.putIfAbsent(path, () => {}).add(entry.key);
      }
    }
    final normalizedPaths = <String>{...pathReferences};
    for (final path in pathReferences) {
      final safe = await _owned(await resolver.resolvePath(path), root);
      if (safe != null) {
        normalizedPaths.add(safe);
        if (directReferences.contains(path)) directReferences.add(safe);
      }
    }
    final retained = await RetainedMediaReferences.read(database);
    final backupPaths = <String>{};
    for (final path in retained.paths) {
      backupPaths.add(p.normalize(path));
      final safe = await _owned(await resolver.resolvePath(path), root);
      if (safe != null) backupPaths.add(safe);
    }
    return _Graph(
      rows,
      referenced,
      normalizedPaths,
      owned,
      owners,
      drafts,
      directReferences,
      backupPaths,
      retained.uncertain,
    );
  }

  bool _old(DateTime at) => !at.isAfter(clock().subtract(retention));
  Future<List<File>> _flatFiles(Directory directory) async {
    final list = await directory.list(followLinks: false).take(100002).toList();
    if (list.length > 100001 || list.any((e) => e is! File)) {
      throw const FormatException('Unknown media directory contents');
    }
    return list.cast<File>()..sort((a, b) => a.path.compareTo(b.path));
  }

  Future<String?> _role(Directory directory, List<File> files) async {
    final marker = File(
      p.join(directory.path, OwnedMaterialActivity.markerName),
    );
    if (files.any((e) => p.equals(e.path, marker.path))) {
      if (await marker.length() > 1024) return null;
      final raw = decodeStoredJson(await marker.readAsString());
      if (raw is Map &&
          raw.length == 4 &&
          raw['format'] == 'dontforget.material' &&
          raw['version'] == 1 &&
          raw['version'] is int &&
          const ['original', 'restore'].contains(raw['role']) &&
          raw['created_at'] is String &&
          DateTime.tryParse(raw['created_at']) != null) {
        return raw['role'] as String;
      }
      return null;
    }
    // Recognize only the exact flat layout emitted by the previous restorers.
    final snapshot = File(p.join(directory.path, 'snapshot.json'));
    if (!files.any((e) => p.equals(e.path, snapshot.path)) ||
        files.any(
          (e) =>
              !p.equals(e.path, snapshot.path) &&
              !RegExp(
                r'^attachment-\d+\.[a-z0-9]{1,10}$',
              ).hasMatch(p.basename(e.path)),
        ) ||
        await snapshot.length() > 32 * 1024 * 1024) {
      return null;
    }
    try {
      final data = decodeStoredJson(await snapshot.readAsString());
      if (data is! Map ||
          data['version'] is! int ||
          data['version'] < 7 ||
          data['version'] > DatabaseHelper.schemaVersion ||
          data['settings'] is! List ||
          data['reminders'] is! List ||
          data['media_records'] is! List) {
        return null;
      }
      final paths = <String>{};
      for (final row in data['media_records']) {
        if (row is! Map ||
            row['type'] is! String ||
            row['content_or_path'] is! String) {
          return null;
        }
        if (row['type'] != 'text') {
          final path = row['content_or_path'] as String;
          final safe = await _owned(path, p.dirname(directory.path));
          if (safe == null || !p.equals(p.dirname(safe), directory.path)) {
            return null;
          }
          paths.add(safe);
        }
      }
      if (files.any(
        (f) =>
            !p.equals(f.path, snapshot.path) &&
            !paths.any((p0) => p.equals(p0, f.path)),
      )) {
        return null;
      }
      return 'restore';
    } catch (_) {
      return null;
    }
  }

  Future<ContentInventory> _inspect(DatabaseExecutor db, String root) async {
    final graph = await _graph(db, root), entries = <ContentCleanupEntry>[];
    final ownership = <String, bool>{};
    Future<bool> recognized(String file) async {
      final directory = p.dirname(file);
      if (ownership.containsKey(directory)) return ownership[directory]!;
      try {
        final folder = Directory(directory);
        return ownership[directory] =
            await _role(folder, await _flatFiles(folder)) != null;
      } catch (_) {
        return ownership[directory] = false;
      }
    }

    for (final item in graph.rows.entries) {
      final record = MediaRecord.fromJson(item.value),
          owned = graph.owned[item.key];
      final stat = owned == null ? null : await File(owned).stat();
      final isFile = stat?.type == FileSystemEntityType.file;
      final referenced =
          graph.referenced.contains(item.key) ||
          (owned != null && graph.directReferences.contains(owned));
      final active =
          owned != null && OwnedMaterialActivity.active(p.dirname(owned));
      final recent =
          !_old(record.createdAt) || (isFile && !_old(stat!.modified));
      final deletableFile =
          owned != null &&
          isFile &&
          graph.owners[owned]!.length == 1 &&
          !graph.backupUncertain &&
          !graph.backupPaths.contains(owned) &&
          await recognized(owned);
      entries.add(
        ContentCleanupEntry(
          key: 'record:${record.id}',
          label: record.type == 'text'
              ? record.contentOrPath
              : p.basename(record.contentOrPath),
          kind: ContentEntryKind.record,
          record: Map.unmodifiable(item.value),
          files: List.unmodifiable(deletableFile ? [owned] : <String>[]),
          bytes: deletableFile ? stat!.size : 0,
          reason: referenced
              ? 'referenced'
              : active
              ? 'active'
              : recent
              ? 'recent'
              : '',
        ),
      );
    }
    final pending = <String>[];
    if (await Directory(root).exists()) {
      var count = 0;
      await for (final child in Directory(root).list(followLinks: false)) {
        if (++count > 100000) {
          throw const FormatException('Too many content directories');
        }
        if (child is! Directory) continue;
        final name = p.basename(child.path);
        if (_job.hasMatch(name)) {
          if (!OwnedMaterialActivity.active(child.path)) pending.add(name);
          continue;
        }
        if (!_import.hasMatch(name)) continue;
        List<File> files;
        try {
          files = await _flatFiles(child);
        } catch (_) {
          continue;
        }
        final protected =
            graph.owners.keys.any((f) => p.dirname(f) == child.path) ||
            graph.pathReferences.any((f) => p.dirname(f) == child.path);
        final backupProtected =
            graph.backupUncertain ||
            graph.backupPaths.any((f) => p.dirname(f) == child.path);
        final role = await _role(child, files);
        var bytes = 0, recent = false;
        for (final file in files) {
          final stat = await file.stat();
          bytes += stat.size;
          recent = recent || !_old(stat.modified);
        }
        final active = OwnedMaterialActivity.active(child.path);
        entries.add(
          ContentCleanupEntry(
            key: 'directory:$name',
            label: name,
            kind: role == 'restore'
                ? ContentEntryKind.restore
                : ContentEntryKind.original,
            files: List.unmodifiable(files.map((e) => e.path)),
            bytes: bytes,
            reason: backupProtected
                ? 'backupProtected'
                : protected
                ? 'referenced'
                : active
                ? 'active'
                : role == null
                ? 'unknown'
                : recent
                ? 'recent'
                : '',
          ),
        );
      }
    }
    return ContentInventory(
      List.unmodifiable(entries),
      List.unmodifiable(pending),
    );
  }

  Future<ContentInventory> inspect(DataGeneration generation) =>
      database.runOperation(generation, () async {
        final root = await _root();
        return database.writeTransaction(
          generation,
          (db) => _inspect(db, root),
        );
      });
  Future<String> _fingerprint(String path, void Function() check) async {
    check();
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Content changed');
    }
    final file = File(path), before = await file.stat();
    final digest = await sha256
        .bind(
          file.openRead(0, before.size).map((chunk) {
            check();
            return chunk;
          }),
        )
        .first;
    final after = await file.stat();
    check();
    if (before.size != after.size || before.modified != after.modified) {
      throw StateError('Content changed');
    }
    return '${before.size}:${before.modified.toIso8601String()}:$digest';
  }

  Future<ContentCleanupPlan> prepare(
    ContentInventory inventory,
    Set<String> selected,
    DataGeneration generation, {
    required bool Function() isCurrent,
  }) => database.runOperation(generation, () async {
    if (selected.isEmpty || selected.length > 100) {
      throw const FormatException('Select 1 to 100 entries');
    }
    final entries = inventory.entries
        .where((e) => selected.contains(e.key))
        .toList();
    if (entries.length != selected.length || entries.any((e) => !e.eligible)) {
      throw StateError('Content is protected');
    }
    final root = await _root(), prints = <String, String>{};
    void check() {
      database.checkGeneration(generation);
      if (!isCurrent()) throw StateError('Content session changed');
    }

    for (final entry in entries) {
      for (final path in entry.files) {
        final ownedPath = await _owned(path, root);
        if (ownedPath == null ||
            !p.equals(ownedPath, path) ||
            prints.containsKey(path)) {
          throw StateError('Unsafe or overlapping content');
        }
        prints[path] = await _fingerprint(path, check);
      }
    }
    check();
    return ContentCleanupPlan._(
      List.unmodifiable(entries),
      Map.unmodifiable(prints),
    );
  });
  Future<void> _jobs(DatabaseExecutor db, String job, bool add) async {
    final row = (await db.query(
      'Settings',
      where: 'id = ?',
      whereArgs: ['default'],
    )).single;
    final raw = row['workspace_drafts_json'];
    final drafts = raw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(decodeStoredJson(raw as String) as Map);
    final jobs = _jobList(drafts).toSet();
    if (add) {
      jobs.add(job);
    } else {
      jobs.remove(job);
    }
    if (jobs.length > 64) {
      throw const FormatException('Too many pending cleanups');
    }
    if (jobs.isEmpty) {
      drafts.remove(cleanupKey);
    } else {
      drafts[cleanupKey] = jobs.toList();
    }
    final encoded = jsonEncode(drafts);
    if (encoded.length > 1048576) {
      throw const FormatException('Workspace too large');
    }
    await db.update(
      'Settings',
      {'workspace_drafts_json': encoded},
      where: 'id = ?',
      whereArgs: ['default'],
    );
  }

  List<String> _jobList(Map drafts) {
    final jobs = drafts[cleanupKey] ?? [];
    if (jobs is! List ||
        jobs.length > 64 ||
        jobs.any((e) => e is! String || !_job.hasMatch(e))) {
      throw const FormatException('Invalid cleanup jobs');
    }
    return List<String>.from(jobs);
  }

  Future<void> _restoreMoves(
    String root,
    Directory quarantine,
    List<Map<String, dynamic>> moves,
  ) async {
    for (final move in moves.reversed) {
      final from = File(p.join(quarantine.path, move['to'] as String));
      if (!await from.exists()) continue;
      final relativeFrom =
          p.joinAll(p.posix.split((move['from'] as String).replaceAll('\\', '/')));
      final destination = File(p.join(root, relativeFrom));
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Restore destination changed');
      }
      if (await FileSystemEntity.type(
            destination.parent.path,
            followLinks: false,
          ) ==
          FileSystemEntityType.notFound) {
        await destination.parent.create();
      }
      final ownedDest = await _owned(destination.path, root);
      if (ownedDest == null || !p.equals(ownedDest, destination.path)) {
        throw StateError('Unsafe content path');
      }
      await from.rename(destination.path);
    }
  }

  Future<ContentCleanupResult> clean(
    ContentCleanupPlan plan,
    DataGeneration generation, {
    required bool Function() isCurrent,
  }) => database.runOperation(generation, () async {
    final root = await _root(), name = '.cleanup-${const Uuid().v4()}';
    final quarantine = Directory(p.join(root, name)),
        moves = <Map<String, dynamic>>[];
    var committed = false, records = 0;
    void check() {
      database.checkGeneration(generation);
      if (!isCurrent()) throw StateError('Content session changed');
    }

    try {
      await database.writeTransaction(generation, (db) async {
        check();
        final fresh = await _inspect(db, root);
        for (final expected in plan.entries) {
          final found = fresh.entries
              .where((e) => e.key == expected.key)
              .firstOrNull;
          if (found == null ||
              found.signature != expected.signature ||
              !found.eligible) {
            throw StateError('Content references changed');
          }
        }
        for (final item in plan.fingerprints.entries) {
          final ownedItem = await _owned(item.key, root);
          if (ownedItem == null ||
              !p.equals(ownedItem, item.key) ||
              await _fingerprint(item.key, check) != item.value) {
            throw StateError('Content changed after preview');
          }
          moves.add({
            'from': p.posix.joinAll(p.split(p.relative(item.key, from: root))),
            'to': 'file-${moves.length}',
          });
        }
        await Directory(root).create();
        await quarantine.create();
        OwnedMaterialActivity.hold(quarantine);
        final journalData = jsonEncode({
          'format': 'dontforget.cleanup',
          'version': 1,
          'job': name,
          'moves': moves,
        });
        if (utf8.encode(journalData).length > 1048576) {
          throw const FormatException('Cleanup plan too large');
        }
        await File(
          p.join(quarantine.path, journalName),
        ).writeAsString(journalData, flush: true);
        for (final move in moves) {
          check();
          final relativeFrom =
              p.joinAll(p.posix.split(move['from'] as String));
          await File(
            p.join(root, relativeFrom),
          ).rename(p.join(quarantine.path, move['to'] as String));
        }
        for (final entry in plan.entries.where((e) => e.record != null)) {
          records += await db.delete(
            'MediaRecords',
            where: 'id = ?',
            whereArgs: [entry.record!['id']],
          );
        }
        await _jobs(db, name, true);
        check();
      });
      committed = true;
      try {
        await beforePurge?.call();
        final removed = await _resume(name, generation, isCurrent);
        return ContentCleanupResult(records, removed, false);
      } catch (_) {
        return ContentCleanupResult(records, 0, true);
      }
    } catch (_) {
      if (!committed && await quarantine.exists()) {
        try {
          await _restoreMoves(root, quarantine, moves);
          await _removeJournal(quarantine);
        } catch (_) {
          /* The durable journal remains available for repair. */
        }
      }
      rethrow;
    } finally {
      OwnedMaterialActivity.releaseDirectory(quarantine);
    }
  });
  Future<void> _removeJournal(Directory directory) async {
    final journal = File(p.join(directory.path, journalName));
    if (await journal.exists()) await journal.delete();
    if ((await directory.list(followLinks: false).toList()).isEmpty) {
      await directory.delete();
    }
  }

  Future<int> repair(
    String job,
    DataGeneration generation, {
    required bool Function() isCurrent,
  }) => database.runOperation(
    generation,
    () => _resume(job, generation, isCurrent),
  );
  Future<int> _resume(
    String job,
    DataGeneration generation,
    bool Function() isCurrent,
  ) async {
    if (!_job.hasMatch(job)) {
      throw const FormatException('Invalid cleanup identity');
    }
    final root = await _root(), quarantine = Directory(p.join(root, job));
    if (await FileSystemEntity.type(quarantine.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Cleanup unavailable');
    }
    final journal = File(p.join(quarantine.path, journalName));
    if (await FileSystemEntity.type(journal.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await journal.length() > 1048576) {
      throw const FormatException('Invalid cleanup journal');
    }
    final data = decodeStoredJson(await journal.readAsString());
    if (data is! Map ||
        data.length != 4 ||
        data['format'] != 'dontforget.cleanup' ||
        data['version'] is! int ||
        data['version'] != 1 ||
        data['job'] != job ||
        data['moves'] is! List ||
        data['moves'].length > 100000) {
      throw const FormatException('Invalid cleanup journal');
    }
    final moves = <Map<String, dynamic>>[],
        sources = <String>{},
        targets = <String>{};
    for (final value in data['moves']) {
      if (value is! Map ||
          value.length != 2 ||
          value['from'] is! String ||
          value['to'] is! String) {
        throw const FormatException('Invalid cleanup path');
      }
      final from = (value['from'] as String).replaceAll('\\', '/'),
          to = value['to'] as String,
          parts = p.posix.split(from);
      if (p.posix.isAbsolute(from) ||
          parts.length != 2 ||
          !_import.hasMatch(parts.first) ||
          parts.last == '.' ||
          parts.last == '..' ||
          p.posix.normalize(from) != from ||
          !RegExp(r'^file-\d+$').hasMatch(to) ||
          !sources.add(from) ||
          !targets.add(to)) {
        throw const FormatException('Unsafe cleanup path');
      }
      moves.add({'from': from, 'to': to});
    }
    final files = await _flatFiles(quarantine);
    if (files.any(
      (f) =>
          p.basename(f.path) != journalName &&
          !targets.contains(p.basename(f.path)),
    )) {
      throw StateError('Unknown cleanup files');
    }
    var removed = 0;
    await database.writeTransaction(generation, (db) async {
      database.checkGeneration(generation);
      if (!isCurrent()) throw StateError('Content session changed');
      final graph = await _graph(db, root);
      final committed = _jobList(graph.drafts).contains(job);
      final currentPaths = {
        ...graph.owners.keys,
        ...graph.pathReferences,
        ...graph.backupPaths,
      };
      final protected =
          graph.backupUncertain ||
          moves.any(
            (m) {
              final relativeFrom =
                  p.joinAll(p.posix.split(m['from'] as String));
              final diskFrom = p.join(root, relativeFrom);
              final diskTo = p.join(quarantine.path, m['to'] as String);
              return currentPaths.any(
                (cp) => p.equals(cp, diskFrom) || p.equals(cp, diskTo),
              );
            },
          );
      if (!committed || protected) {
        await _restoreMoves(root, quarantine, moves);
      } else {
        for (final move in moves) {
          database.checkGeneration(generation);
          if (!isCurrent()) throw StateError('Content session changed');
          final file = File(p.join(quarantine.path, move['to'] as String));
          final type = await FileSystemEntity.type(
            file.path,
            followLinks: false,
          );
          if (type == FileSystemEntityType.notFound) continue;
          if (type != FileSystemEntityType.file) {
            throw StateError('Unsafe cleanup file');
          }
          await file.delete();
          removed++;
        }
      }
      await _jobs(db, job, false);
    });
    await _removeJournal(quarantine);
    for (final move in moves) {
      final relativeFrom = p.joinAll(p.posix.split(move['from'] as String));
      final directory = Directory(
        p.dirname(p.join(root, relativeFrom)),
      );
      if (await FileSystemEntity.type(directory.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          (await directory.list(followLinks: false).toList()).isEmpty) {
        await directory.delete();
      }
    }
    return removed;
  }
}

class _Graph {
  _Graph(
    this.rows,
    this.referenced,
    this.pathReferences,
    this.owned,
    this.owners,
    this.drafts,
    this.directReferences,
    this.backupPaths,
    this.backupUncertain,
  );
  final Map<String, Map<String, dynamic>> rows;
  final Set<String> referenced, pathReferences, directReferences, backupPaths;
  final bool backupUncertain;
  final Map<String, String> owned;
  final Map<String, Set<String>> owners;
  final Map<String, dynamic> drafts;
}
