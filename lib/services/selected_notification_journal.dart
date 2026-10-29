// Selection, migration and rollback under one database directory lease.
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'notification_journal_model.dart';
import 'storage_directory_lease.dart';
import 'incremental_journal_engine.dart';

/// All readers and writers hold the SAME directory lease as DatabaseHelper.
/// Selection is explicit: corrupt selected incremental state never falls back
/// to an old v1 copy. Rollback exports the latest committed incremental state.
class LeasedIncrementalJournal {
  LeasedIncrementalJournal._(
    this._lease,
    this.checkpointEveryFrames,
    this.maxDirectoryBytes,
    this.maxCheckpointBytes,
    this.maxLogBytes,
    this.maxFrameBytes, {
    this.ownsLease = true,
  });

  final bool ownsLease;
  bool get isIncremental => _selection?['backend'] == 'incremental';

  /// Reuse DatabaseHelper's live lease; never open/close a second lock handle.
  static Future<LeasedIncrementalJournal> attach(
    StorageDirectoryLease lease,
  ) async {
    lease.checkHeld();
    final session = LeasedIncrementalJournal._(
      lease,
      24,
      256 * 1024 * 1024,
      16 * 1024 * 1024,
      64 * 1024 * 1024,
      4 * 1024 * 1024,
      ownsLease: false,
    );
    await session._recoverRollback();
    await session._read();
    return session;
  }

  /// An explicit v1 selection pins a rollback until a deliberate upgrade.
  Future<bool> get permitsAutomaticMigration async =>
      await FileSystemEntity.type(
        _root(selectorName).path,
        followLinks: false,
      ) ==
      FileSystemEntityType.notFound;

  static const selectorName = NotificationJournalFormat.storageSelectorFileName;
  static const intentName = 'notification-rollback.intent.json';
  static const maxManagedFiles = 256;
  final StorageDirectoryLease _lease;
  final int checkpointEveryFrames, maxDirectoryBytes;
  final int maxCheckpointBytes, maxLogBytes, maxFrameBytes;
  final _generations = RegExp(
    r'^([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.(json|log|manifest\.tmp)$',
  );
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  bool _accepting = true, _failed = false;
  int _scheduledOperations = 0;
  IncrementalJournalEngine? _engine;
  Map<String, dynamic>? _selection;
  int reclaimedFiles = 0;
  ({int bytes, int flushes, int checkpoints}) get writeStatistics => (
    bytes: _engine?.writtenBytes ?? 0,
    flushes: _engine?.flushes ?? 0,
    checkpoints: _engine?.checkpoints ?? 0,
  );
  Future<void> Function(String point)? hook;
  Directory get directory => _lease.directory;
  Directory get managed =>
      Directory(p.join(directory.path, 'notification-incremental'));
  File _root(String name) => File(p.join(directory.path, name));
  File _managed(String name) => File(p.join(managed.path, name));
  static const _v1Selection = {'format': 1, 'backend': 'v1'};

  static Future<LeasedIncrementalJournal> acquire(
    Directory directory, {
    int checkpointEveryFrames = 24,
    int maxDirectoryBytes = 256 * 1024 * 1024,
    int maxCheckpointBytes = 16 * 1024 * 1024,
    int maxLogBytes = 64 * 1024 * 1024,
    int maxFrameBytes = 4 * 1024 * 1024,
  }) async {
    if (checkpointEveryFrames < 1 ||
        checkpointEveryFrames > 1024 ||
        maxDirectoryBytes < 4096 ||
        maxDirectoryBytes > 256 * 1024 * 1024) {
      throw ArgumentError('Invalid leased journal policy');
    }
    // Validate engine limits before acquiring a lease or touching any files.
    IncrementalJournalEngine(
      directory,
      maxCheckpointBytes: maxCheckpointBytes,
      maxLogBytes: maxLogBytes,
      maxFrameBytes: maxFrameBytes,
    );
    final lease = await StorageDirectoryLease.acquire(directory);
    final session = LeasedIncrementalJournal._(
      lease,
      checkpointEveryFrames,
      maxDirectoryBytes,
      maxCheckpointBytes,
      maxLogBytes,
      maxFrameBytes,
    );
    try {
      await session._recoverRollback();
      await session._read();
      return session;
    } catch (_) {
      await lease.close();
      rethrow;
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    if (!_accepting) {
      return Future.error(StateError('Journal session is closing'));
    }
    _scheduledOperations++;
    final next = _tail.then((_) async {
      try {
        _lease.checkHeld();
        if (_failed) throw StateError('Close and reopen the failed session');
        try {
          return await operation();
        } catch (_) {
          _failed = true;
          rethrow;
        }
      } finally {
        _scheduledOperations--;
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> close() {
    _accepting = false;
    Future<void> finish() async {
      if (ownsLease) await _lease.close();
    }

    return _closing ??= _scheduledOperations == 0
        ? finish()
        : _tail.then((_) => finish());
  }

  Future<void> _regular(File file, {bool missing = false}) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        !(missing && type == FileSystemEntityType.notFound)) {
      throw const FormatException('Expected a regular journal file');
    }
  }

  Future<List<int>?> _bytes(
    File file,
    int limit, {
    bool missing = false,
  }) async {
    await _regular(file, missing: missing);
    if (!await file.exists()) return null;
    if (await file.length() > limit) {
      throw const FormatException('Journal file too large');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > limit) {
      throw const FormatException('Journal file grew too large');
    }
    return bytes;
  }

  List<int> _encode(Object value) => utf8.encode(jsonEncode(value));
  String _hash(List<int> bytes) => IncrementalJournalEngine.digest(bytes);
  Future<void> _atomic(File target, List<int> bytes, int limit) async {
    if (bytes.length > limit) throw StateError('Journal output exceeds limit');
    await _regular(target, missing: true);
    final temporary = File('${target.path}.tmp');
    await _regular(temporary, missing: true);
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  }

  Future<void> _remove(File file) async {
    await _regular(file, missing: true);
    if (await file.exists()) await file.delete();
  }

  Future<void> _managedDirectory() async {
    final type = await FileSystemEntity.type(managed.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) await managed.create();
    if (await FileSystemEntity.type(managed.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.equals(await managed.resolveSymbolicLinks(), managed.path)) {
      throw const FormatException('Unsafe incremental directory');
    }
  }

  Future<Map<String, dynamic>> _selected() async {
    if (_selection != null) return _selection!;
    final bytes = await _bytes(_root(selectorName), 4096, missing: true);
    final map = bytes == null
        ? Map<String, dynamic>.from(_v1Selection)
        : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    if (map['format'] != 1 ||
        !{'v1', 'incremental'}.contains(map['backend']) ||
        map.length != (map['backend'] == 'v1' ? 2 : 3) ||
        (map['backend'] == 'incremental' && !_isHash(map['source_sha256']))) {
      throw const FormatException('Unknown journal selection');
    }
    return _selection = map;
  }

  bool _isHash(dynamic value) =>
      value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  IncrementalJournalEngine _newEngine() => IncrementalJournalEngine(
    managed,
    maxCheckpointBytes: maxCheckpointBytes,
    maxLogBytes: maxLogBytes,
    maxFrameBytes: maxFrameBytes,
  );

  Future<NotificationJournalSnapshot?> read() => _run(_read);
  Future<NotificationJournalSnapshot?> _read() async {
    final selected = await _selected();
    if (selected['backend'] == 'v1') {
      final bytes = await _bytes(
        _root(NotificationJournalFormat.fileName),
        NotificationJournalFormat.maxBytes,
        missing: true,
      );
      return bytes == null
          ? null
          : NotificationJournalSnapshot.decode(jsonDecode(utf8.decode(bytes)));
    }
    if (_engine == null) {
      await _managedDirectory();
      final original = await _bytes(
        _managed('source-v1.json'),
        NotificationJournalFormat.maxBytes,
      );
      final legacy = await _bytes(
        _root(NotificationJournalFormat.fileName),
        NotificationJournalFormat.maxBytes,
      );
      if (_hash(original!) != selected['source_sha256'] ||
          _hash(legacy!) != selected['source_sha256']) {
        throw const FormatException('Legacy state changed outside migration');
      }
      final engine = _newEngine();
      await engine
          .open(); // Selected corruption fails closed, no old-v1 fallback.
      _engine = engine;
    }
    return _engine!.snapshot!;
  }

  Future<void> migrate() => _run(() async {
    if ((await _selected())['backend'] != 'v1') {
      throw StateError('Already incremental');
    }
    final bytes = await _bytes(
      _root(NotificationJournalFormat.fileName),
      NotificationJournalFormat.maxBytes,
    );
    final state = NotificationJournalSnapshot.decode(
      jsonDecode(utf8.decode(bytes!)),
    );
    await _managedDirectory();
    await _capacity(bytes.length * 2 + 16384);
    await _atomic(
      _managed('source-v1.json'),
      bytes,
      NotificationJournalFormat.maxBytes,
    );
    final engine = _newEngine();
    await engine.checkpoint(state);
    await hook?.call('import_checkpoint');
    if (_hash(
          (await _bytes(
            _root(NotificationJournalFormat.fileName),
            NotificationJournalFormat.maxBytes,
          ))!,
        ) !=
        _hash(bytes)) {
      throw const FormatException('v1 changed during migration');
    }
    final selection = {
      'format': 1,
      'backend': 'incremental',
      'source_sha256': _hash(bytes),
    };
    await _atomic(_root(selectorName), _encode(selection), 4096);
    _selection = selection;
    _engine = engine;
    await hook?.call('import_published');
    await _collect();
  });

  Future<void> append(
    String epoch,
    List<NotificationJournalEntry> entries,
  ) => _run(() async {
    if (_engine == null) await _read();
    if (_engine == null) {
      throw StateError('Migrate before append');
    }
    if (_engine!.ignoredTailBytes != 0) await _checkpoint();
    // Reserve bounded worst-case output, rather than copying/serializing the
    // entire snapshot for every small delta. Checkpoints validate exact size.
    await _capacity(maxFrameBytes + maxCheckpointBytes + 16384);
    try {
      await _engine!.append(epoch, entries);
    } on JournalSegmentFull {
      await _checkpoint();
      await _engine!.append(epoch, entries);
    }
    if (_engine!.segmentFrames >= checkpointEveryFrames) await _checkpoint();
  });
  Future<void> checkpoint() => _run(_checkpoint);
  Future<void> _checkpoint() async {
    final state = await _read();
    if (_engine == null || state == null) {
      throw StateError('No incremental state');
    }
    await _checkpointState(state);
  }

  Future<void> reset(String epoch) => _run(() async {
    await _read();
    if (_engine == null) throw StateError('No incremental state');
    await _checkpointState(NotificationJournalSnapshot(epoch, {}));
  });

  Future<void> _checkpointState(NotificationJournalSnapshot state) async {
    await _capacity(maxCheckpointBytes + 8192);
    // Pin the old generation BEFORE publishing a replacement. Every reader
    // takes this lease, so none can still be reading an unpinned generation.
    await _atomic(
      _managed('retained.json'),
      _encode({'generation': await _generation()}),
      4096,
    );
    _engine!.checkpointHook = hook;
    await _engine!.checkpoint(state);
    await _collect();
  }

  Future<String> _generation() async {
    final value =
        jsonDecode(utf8.decode((await _bytes(_managed('current.json'), 4096))!))
            as Map;
    final generation = value['generation'];
    if (generation is! String || !_generations.hasMatch('$generation.json')) {
      throw const FormatException('Invalid selected generation');
    }
    return generation;
  }

  Future<Map<String, int>> _files() async {
    final files = <String, int>{};
    await for (final item in managed.list(followLinks: false)) {
      if (files.length >= maxManagedFiles) {
        throw const FormatException('Managed journal file count exceeds limit');
      }
      if (await FileSystemEntity.type(item.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('Unsafe file in managed journal directory');
      }
      files[item.path.substring(managed.path.length + 1)] = await File(
        item.path,
      ).length();
    }
    return files;
  }

  Future<({int deletedFiles, int bytes})> collect() => _run(_collect);
  Future<({int deletedFiles, int bytes})> _collect() async {
    final files = await _files();
    final pins = <String>{};
    if (files.containsKey('current.json')) pins.add(await _generation());
    if (files.containsKey('retained.json')) {
      final value =
          jsonDecode(
                utf8.decode((await _bytes(_managed('retained.json'), 4096))!),
              )
              as Map;
      final id = value['generation'];
      if (value.length != 1 ||
          id is! String ||
          !_generations.hasMatch('$id.json')) {
        throw const FormatException('Invalid retained generation');
      }
      pins.add(id);
    }
    var deleted = 0, bytes = 0;
    for (final entry in files.entries) {
      final match = _generations.firstMatch(entry.key);
      if (match != null && !pins.contains(match.group(1))) {
        await _remove(_managed(entry.key));
        deleted++;
        reclaimedFiles++;
        await hook?.call('generation_removed');
      } else {
        bytes += entry.value;
      }
    }
    return (deletedFiles: deleted, bytes: bytes);
  }

  Future<void> _capacity(int reserve) async {
    final usage = await _collect();
    if (usage.bytes + reserve > maxDirectoryBytes) {
      throw StateError('Managed journal directory budget exceeded');
    }
  }

  Future<void> rollback() => _run(() async {
    final state = await _read();
    if (_engine == null) {
      await _atomic(_root(selectorName), _encode(_v1Selection), 4096);
      _selection = Map.from(_v1Selection);
      return;
    }
    if (state == null) throw StateError('No incremental state');
    final bytes = _encode(state.toJson());
    if (bytes.length > NotificationJournalFormat.maxBytes) {
      throw StateError('Rollback exceeds v1 limit');
    }
    final previous = (await _bytes(
      _root(NotificationJournalFormat.fileName),
      NotificationJournalFormat.maxBytes,
    ))!;
    if (_hash(previous) != (await _selected())['source_sha256']) {
      throw const FormatException('Legacy state changed before rollback');
    }
    final selectedBytes = (await _bytes(_root(selectorName), 4096))!;
    await _atomic(
      _root(intentName),
      _encode({
        'format': 1,
        'selector_sha256': _hash(selectedBytes),
        'previous_v1_sha256': _hash(previous),
        'export_sha256': _hash(bytes),
      }),
      4096,
    );
    await hook?.call('rollback_intent');
    await _atomic(
      _root(NotificationJournalFormat.fileName),
      bytes,
      NotificationJournalFormat.maxBytes,
    );
    await hook?.call('rollback_v1_published');
    await _atomic(_root(selectorName), _encode(_v1Selection), 4096);
    await hook?.call('rollback_selected');
    await _remove(_root(intentName));
    _selection = Map.from(_v1Selection);
    _engine = null;
  });

  Future<void> _recoverRollback() async {
    final raw = await _bytes(_root(intentName), 4096, missing: true);
    if (raw == null) return;
    final intent = jsonDecode(utf8.decode(raw)) as Map;
    if (intent.length != 4 ||
        intent['format'] != 1 ||
        ![
          'selector_sha256',
          'previous_v1_sha256',
          'export_sha256',
        ].every((k) => _isHash(intent[k]))) {
      throw const FormatException('Invalid rollback intent');
    }
    final selected = await _selected();
    final legacy = (await _bytes(
      _root(NotificationJournalFormat.fileName),
      NotificationJournalFormat.maxBytes,
    ))!;
    if (selected['backend'] == 'incremental') {
      if (_hash((await _bytes(_root(selectorName), 4096))!) !=
              intent['selector_sha256'] ||
          !{
            intent['previous_v1_sha256'],
            intent['export_sha256'],
          }.contains(_hash(legacy))) {
        throw const FormatException('Rollback inputs changed');
      }
      await _managedDirectory();
      final engine = _newEngine();
      final state = await engine.open();
      final bytes = _encode(state.toJson());
      if (_hash(bytes) != intent['export_sha256']) {
        throw const FormatException('Rollback state changed');
      }
      await _atomic(
        _root(NotificationJournalFormat.fileName),
        bytes,
        NotificationJournalFormat.maxBytes,
      );
      await _atomic(_root(selectorName), _encode(_v1Selection), 4096);
    } else if (_hash(legacy) != intent['export_sha256']) {
      throw const FormatException('Selected rollback export is inconsistent');
    }
    await _remove(_root(intentName));
    _selection = Map.from(_v1Selection);
    _engine = null;
  }
}
