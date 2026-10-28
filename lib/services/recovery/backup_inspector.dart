import '../../models/task_details.dart';
import '../../models/medication_plan.dart';
import '../../models/departure_plan.dart';
import '../../models/settings.dart';
import '../../models/reminder.dart';
import '../../models/saved_task_filter.dart';
import '../../models/task_template.dart';
import '../learning_queue_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../data/schema_14_compatibility.dart';
import '../../data/schema_15_compatibility.dart';
import '../../models/stored_datetime.dart';
import '../../models/stored_json.dart';
import '../local_media_store.dart';

enum BackupInspectionError {
  cancelled,
  unsupportedVersion,
  invalidFormat,
  unsafeSource,
  sourceChanged,
  tooLarge,
  tooManyRows,
  invalidSchema,
  invalidData,
  unreadable,
}

/// Deliberately carries no source path, SQL, JSON fragments or credentials.
class BackupInspectionException implements Exception {
  const BackupInspectionException(this.code);
  final BackupInspectionError code;

  @override
  String toString() => 'BackupInspectionException(${code.name})';
}

class BackupInspectionCancellation {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!isCancelled) {
      _cancelled.complete();
    }
  }

  void throwIfCancelled() {
    if (isCancelled) {
      _fail(BackupInspectionError.cancelled);
    }
  }
}

class BackupPreview {
  const BackupPreview({
    required this.version,
    required this.digest,
    required this.counts,
    required this.containsCredentials,
    required this.missingMedia,
    required this.unresolvedReferences,
    this.timestamp,
  });

  final int version;
  final String digest;
  final Map<String, int> counts;
  final bool containsCredentials;
  final int missingMedia;
  final int unresolvedReferences;
  final DateTime? timestamp;
}

/// Inspects a bounded private copy of one standalone v7–v16 export.
///
/// Never opens the source through SQLite, imports data, opens the app database,
/// or reads attachment contents. Symlinks (including parent directories) and
/// files with SQLite sidecars are rejected, except exact platform aliases for
/// macOS/iOS temp and Android app-data roots. Their canonical parents are
/// checked too. The result is a structural preview,
/// not proof that the backup can be restored or that attachments are playable.
class BackupInspector {
  BackupInspector(
    this.factory, {
    this.maxBytes = 64 * 1024 * 1024,
    this.maxRows = 100000,
    this.temporaryDirectory,
    LocalMediaStore? mediaStore,
  }) : _mediaStore = mediaStore ?? LocalMediaStore(),
       assert(maxBytes > 0),
       assert(maxRows > 0);

  factory BackupInspector.platform() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      return BackupInspector(databaseFactoryFfi);
    }
    return BackupInspector(sqflite.databaseFactory);
  }

  final DatabaseFactory factory;
  final int maxBytes;

  /// Maximum rows per table; also bounds lists nested inside a reminder.
  final int maxRows;

  /// A parent directory for private copies; useful for isolated service tests.
  final Directory? temporaryDirectory;
  final LocalMediaStore _mediaStore;

  Future<BackupPreview> inspect(
    File source, {
    BackupInspectionCancellation? cancellation,
  }) async {
    final token = cancellation ?? BackupInspectionCancellation();
    Directory? temporary;
    Database? database;
    try {
      token.throwIfCancelled();
      final original = await _sourceState(source);
      token.throwIfCancelled();
      if (original.stat.size > maxBytes) {
        _fail(BackupInspectionError.tooLarge);
      }
      temporary = await (temporaryDirectory ?? Directory.systemTemp).createTemp(
        'dontforget-inspect-',
      );
      token.throwIfCancelled();
      final copy = File(paths.join(temporary.path, 'candidate'));
      final output = await copy.open(mode: FileMode.write);
      var copiedBytes = 0;
      try {
        await for (final chunk in File(original.path).openRead()) {
          token.throwIfCancelled();
          copiedBytes += chunk.length;
          if (copiedBytes > maxBytes) {
            _fail(BackupInspectionError.tooLarge);
          }
          await output.writeFrom(chunk);
        }
      } finally {
        await output.close();
      }
      token.throwIfCancelled();
      final afterCopy = await _sourceState(source);
      if (!original.matches(afterCopy) || copiedBytes != original.stat.size) {
        _fail(BackupInspectionError.sourceChanged);
      }
      final digest = (await sha256.bind(copy.openRead()).first).toString();
      token.throwIfCancelled();
      final header = await copy.open();
      late List<int> signature;
      try {
        signature = await header.read(16);
      } finally {
        await header.close();
      }
      Map<String, Object?>? data;
      if (ascii.decode(signature, allowInvalid: true) ==
          'SQLite format 3\u0000') {
        database = await factory.openDatabase(
          copy.path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        token.throwIfCancelled();
        // Static SQL only. Do not evaluate application-defined schema objects.
        await database.execute('PRAGMA trusted_schema = OFF');
        await database.execute('PRAGMA query_only = ON');
        final version = (await database.rawQuery(
          'PRAGMA user_version',
        )).single.values.single;
        _checkVersion(version);
        token.throwIfCancelled();
        await _checkSchema(database, token, version as int);
        final integrity = await database.rawQuery('PRAGMA integrity_check(1)');
        if (integrity.length != 1 || integrity.single.values.single != 'ok') {
          _fail(BackupInspectionError.invalidData);
        }
        token.throwIfCancelled();
        data = {'version': version, 'timestamp': null};
        for (final table in _tables.entries) {
          final count =
              (await database.rawQuery(
                    'SELECT count(*) FROM ${table.key}',
                  )).single.values.single
                  as int;
          token.throwIfCancelled();
          if (count > maxRows) {
            _fail(BackupInspectionError.tooManyRows);
          }
          data[table.value] = await database.query(
            table.key,
            limit: maxRows + 1,
          );
          token.throwIfCancelled();
        }
      }
      final validated = await _validateInIsolate(
        data,
        copy.path,
        maxRows,
        token,
      );
      var missing = 0;
      for (final path in validated.paths) {
        token.throwIfCancelled();
        // Never fetch a URI, expand a relative path, follow a media symlink,
        // or read attachment contents. Inaccessible paths count as unavailable.
        var exists = false;
        if (paths.isAbsolute(path) &&
            !path.startsWith('//') &&
            !path.startsWith(r'\\') &&
            !path.contains('\u0000')) {
          try {
            exists =
                await FileSystemEntity.type(path, followLinks: false) ==
                FileSystemEntityType.file;
            if (!exists) {
              final resolved = await _mediaStore.resolvePath(path);
              token.throwIfCancelled();
              if (resolved != path) {
                exists =
                    await FileSystemEntity.type(resolved, followLinks: false) ==
                    FileSystemEntityType.file;
              }
            }
          } on FileSystemException {
            exists = false;
          }
        }
        if (!exists) {
          missing++;
        }
      }
      token.throwIfCancelled();
      // A source that becomes active or changes during inspection is not a
      // stable standalone export, even if our private copy happened to parse.
      if (!original.matches(await _sourceState(source))) {
        _fail(BackupInspectionError.sourceChanged);
      }
      token.throwIfCancelled();
      return BackupPreview(
        version: validated.version,
        digest: digest,
        counts: Map.unmodifiable(validated.counts),
        containsCredentials: validated.credentials,
        missingMedia: missing,
        unresolvedReferences: validated.unresolved,
        timestamp: validated.timestamp,
      );
    } on BackupInspectionException {
      rethrow;
    } catch (_) {
      token.throwIfCancelled();
      // Raw plugin and JSON errors can contain selected paths or secret data.
      _fail(BackupInspectionError.unreadable);
    } finally {
      try {
        await database?.close();
      } catch (_) {
        // Still remove the private copy if the SQLite close reports an error.
      }
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {
          _fail(BackupInspectionError.unreadable);
        }
      }
    }
  }
}

Never _fail(BackupInspectionError code) =>
    throw BackupInspectionException(code);

class _SourceState {
  _SourceState(this.path, this.stat);
  final String path;
  final FileStat stat;

  bool matches(_SourceState other) =>
      path == other.path &&
      stat.size == other.stat.size &&
      stat.modified == other.stat.modified &&
      stat.changed == other.stat.changed &&
      stat.mode == other.stat.mode;
}

Future<_SourceState> _sourceState(File source) async {
  final absolute = paths.absolute(source.path);
  // Check before lexical normalization: a link followed by '..' must not hide
  // a symlink traversal. Reject ambiguous dot components instead.
  if (paths.split(absolute).any((part) => part == '..' || part == '.')) {
    _fail(BackupInspectionError.unsafeSource);
  }
  final path = paths.normalize(absolute);
  await _checkFileAndParents(path, allowSystemAliases: true);
  final canonical = await File(path).resolveSymbolicLinks();
  if (!paths.equals(path, canonical)) {
    await _checkFileAndParents(canonical, allowSystemAliases: false);
  }
  for (final suffix in ['-wal', '-journal', '-shm']) {
    if (await FileSystemEntity.type('$canonical$suffix', followLinks: false) !=
        FileSystemEntityType.notFound) {
      _fail(BackupInspectionError.unsafeSource);
    }
  }
  final stat = await File(canonical).stat();
  if (stat.type != FileSystemEntityType.file) {
    _fail(BackupInspectionError.unsafeSource);
  }
  return _SourceState(canonical, stat);
}

Future<void> _checkFileAndParents(
  String path, {
  required bool allowSystemAliases,
}) async {
  var current = path;
  var leaf = true;
  while (true) {
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _fail(BackupInspectionError.unreadable);
    }
    final aliasTarget = (Platform.isMacOS || Platform.isIOS)
        ? const {'/var': '/private/var', '/tmp': '/private/tmp'}[current]
        : Platform.isAndroid
        ? const {
            '/data/user/0': '/data/data',
            '/data/data': '/data/user/0',
          }[current]
        : null;
    final systemAlias =
        !leaf &&
        allowSystemAliases &&
        aliasTarget != null &&
        type == FileSystemEntityType.link &&
        await Directory(current).resolveSymbolicLinks() == aliasTarget;
    if (!systemAlias &&
        type !=
            (leaf
                ? FileSystemEntityType.file
                : FileSystemEntityType.directory)) {
      _fail(BackupInspectionError.unsafeSource);
    }
    final parent = paths.dirname(current);
    if (parent == current) {
      break;
    }
    current = parent;
    leaf = false;
  }
}

const _tables = {
  'Settings': 'settings',
  'MediaRecords': 'media_records',
  'Reminders': 'reminders',
};
const _columns = {
  'settings': {
    'id': 's',
    'api_key': 's?',
    'base_url': 's?',
    'model_name': 's?',
    'language': 's?',
  },
  'media_records': {
    'id': 's',
    'type': 's',
    'content_or_path': 's',
    'created_at': 'd',
  },
  'reminders': {
    'id': 's',
    'record_id': 's?',
    'task_title': 's',
    'task_summary': 's?',
    'quadrant_level': 'q',
    'urgency_level': 's?',
    'importance_level': 's?',
    'trigger_time': 'd?',
    'is_completed': 'b',
    'is_recurring': 'b?',
    'recurrence_rule': 's?',
    'recurrence_description': 's?',
    'is_emotion_filtered': 'b?',
    'sub_tasks': 's?',
    'created_at': 'd?',
    'review_level': 'i?',
    'next_review_at': 'd?',
    'original_quadrant_level': 'q?',
    'is_dynamically_promoted': 'b?',
    'linked_task_ids': 's?',
    'context_trigger': 's?',
  },
};

const _reminderNoticeColumns = {
  'notice_revision': 'n',
  'notice_acknowledged_at': 'd?',
  'upcoming_dismissed_at': 'd?',
  'snoozed_at': 'd?',
  'recurrence_anchor_time': 'd?',
};

Map<String, String> _columnsFor(
  String table,
  int version, {
  Schema14Shape? version14Shape,
  Schema15Shape? version15Shape,
}) => {
  ..._columns[table]!,
  if (table == 'reminders' && version >= 9) ..._reminderNoticeColumns,
  if (table == 'settings' && version >= 10) ...{
    'ai_profiles_json': 's',
    'ai_fallback_enabled': 'b',
  },
  if (table == 'settings' && version >= 11) 'appearance': 's',
  if (table == 'settings' && version >= 12) 'input_send_mode': 's',
  if (table == 'reminders' && version >= 13)
    'review_notifications_enabled': 'b',
  if (table == 'reminders' &&
      (version >= 16 ||
          (version == 15 && version15Shape == Schema15Shape.recordReminder) ||
          (version == 14 && version14Shape == Schema14Shape.reminderOrigin)))
    'trigger_time_origin': 's',
  if (table == 'settings' &&
      (version >= 15 || (version == 14 && version14Shape?.isCapture == true)))
    'workspace_drafts_json': 's?',
  if (table == 'reminders' &&
      (version >= 15 ||
          (version == 14 && version14Shape?.isCapture == true))) ...{
    'event_time': 'd?',
    'recurrence_event_anchor_time': 'd?',
    'suggested_trigger_time': 'd?',
    'source_text': 's?',
    'capture_pending': 'b',
    'is_pinned': 'b',
  },
  if (table == 'reminders' &&
      (version >= 15 || (version == 14 && version14Shape?.hasProposal == true)))
    'capture_proposal_json': 's?',
  if (table == 'reminders' &&
      (version >= 15 ||
          (version == 14 && version14Shape?.hasWordProgress == true)))
    'word_progress_json': 's?',
  if (table == 'reminders' &&
      (version >= 16 ||
          (version == 15 && version15Shape == Schema15Shape.taskManagement)))
    'details_json': 's?',
};

Future<void> _checkSchema(
  Database database,
  BackupInspectionCancellation token,
  int version,
) async {
  Schema14Shape? version14Shape;
  Schema15Shape? version15Shape;
  if (version == 14 || version == 15) {
    Future<Set<String>> names(String table) async {
      var fields = await database.rawQuery('PRAGMA table_xinfo($table)');
      if (fields.isEmpty) {
        fields = await database.rawQuery('PRAGMA table_info($table)');
      }
      token.throwIfCancelled();
      if (fields.any((field) => (field['hidden'] ?? 0) != 0)) {
        _fail(BackupInspectionError.invalidSchema);
      }
      return fields.map((field) => field['name'] as String).toSet();
    }

    final settingsColumns = await names('Settings');
    final reminderColumns = await names('Reminders');
    if (version == 14) {
      version14Shape = identifySchema14(
        settingsColumns: settingsColumns,
        reminderColumns: reminderColumns,
      );
      if (version14Shape == null) _fail(BackupInspectionError.invalidSchema);
    } else {
      version15Shape = identifySchema15(
        settingsColumns: settingsColumns,
        reminderColumns: reminderColumns,
      );
      if (version15Shape == null) _fail(BackupInspectionError.invalidSchema);
    }
  }
  final objects = await database.rawQuery(
    'SELECT name,type,tbl_name,sql FROM sqlite_master LIMIT 16',
  );
  token.throwIfCancelled();
  final tables = <String>{};
  Map<String, Object?>? androidMetadata;
  for (final object in objects) {
    final name = object['name'];
    if (name == 'android_metadata' && object['type'] == 'table') {
      // Android's SQLite framework creates this locale table on open. It is
      // not application data and is never included in preview record counts.
      androidMetadata = object;
    } else if (object['type'] == 'table' &&
        _tables.containsKey(name) &&
        object['sql'] is String &&
        RegExp(
          r'^CREATE\s+TABLE\s',
          caseSensitive: false,
        ).hasMatch(object['sql'] as String)) {
      tables.add(name as String);
    } else if (object['type'] == 'index' &&
        object['sql'] == null &&
        const {
          'sqlite_autoindex_MediaRecords_1',
          'sqlite_autoindex_Reminders_1',
        }.contains(name)) {
      // Only SQLite's implicit constraint indexes belong to current exports.
    } else {
      _fail(BackupInspectionError.invalidSchema);
    }
  }
  if (objects.length >= 16 || tables.length != _tables.length) {
    _fail(BackupInspectionError.invalidSchema);
  }
  if (androidMetadata != null) {
    final sql = androidMetadata['sql'];
    if (sql is! String ||
        !RegExp(
          r'^CREATE\s+TABLE\s+android_metadata\s*\(\s*locale\s+TEXT\s*\)\s*$',
          caseSensitive: false,
        ).hasMatch(sql)) {
      _fail(BackupInspectionError.invalidSchema);
    }
    final metadata = await database.rawQuery(
      'SELECT locale FROM android_metadata LIMIT 2',
    );
    token.throwIfCancelled();
    if (metadata.length > 1 ||
        metadata.any((row) => row['locale'] is! String)) {
      _fail(BackupInspectionError.invalidSchema);
    }
  }
  for (final table in _tables.entries) {
    final sql =
        objects.firstWhere((object) => object['name'] == table.key)['sql']
            as String;
    if (RegExp(
      r'\b(CHECK|UNIQUE|GENERATED|COLLATE|AUTOINCREMENT|DEFERRABLE|STRICT)\b|WITHOUT\s+ROWID',
      caseSensitive: false,
    ).hasMatch(sql)) {
      _fail(BackupInspectionError.invalidSchema);
    }
    var fields = await database.rawQuery('PRAGMA table_xinfo(${table.key})');
    token.throwIfCancelled();
    if (fields.isEmpty) {
      // SQLite before 3.26 (including older supported Android versions) does
      // not know table_xinfo. Unknown PRAGMAs return no rows. Dangerous DDL was
      // rejected above, and table_info still checks every standard column.
      fields = await database.rawQuery('PRAGMA table_info(${table.key})');
    }
    token.throwIfCancelled();
    final expected = _columnsFor(
      table.value,
      version,
      version14Shape: version14Shape,
      version15Shape: version15Shape,
    );
    if (fields.length != expected.length ||
        !fields
            .map((field) => field['name'])
            .toSet()
            .containsAll(expected.keys) ||
        fields.any((field) => (field['hidden'] ?? 0) != 0)) {
      _fail(BackupInspectionError.invalidSchema);
    }
    for (final field in fields) {
      final name = field['name'] as String;
      final kind = expected[name]![0];
      final sqlType = name == 'is_completed'
          ? 'BOOLEAN'
          : ['b', 'q', 'i', 'n'].contains(kind)
          ? 'INTEGER'
          : 'TEXT';
      final primaryKey = name == 'id' && table.key != 'Settings';
      final notNull = !primaryKey && !expected[name]!.endsWith('?');
      final defaultValue = field['dflt_value'];
      final defaultsToZero = const {
        'is_recurring',
        'is_emotion_filtered',
        'review_level',
        'is_dynamically_promoted',
        'notice_revision',
        'ai_fallback_enabled',
        'review_notifications_enabled',
        'capture_pending',
        'is_pinned',
      }.contains(name);
      final validDefault = defaultsToZero
          ? defaultValue == '0'
          : name == 'ai_profiles_json'
          ? defaultValue == "'[]'"
          : name == 'appearance'
          ? defaultValue == "'system'"
          : name == 'input_send_mode'
          ? defaultValue == "'enter'"
          : name == 'trigger_time_origin'
          ? defaultValue == "'unknown'"
          : name == 'recurrence_rule'
          ? const ["'none'", '"none"'].contains(defaultValue)
          : defaultValue == null;
      if ((field['type'] as String).toUpperCase() != sqlType ||
          field['notnull'] != (notNull ? 1 : 0) ||
          field['pk'] != (primaryKey ? 1 : 0) ||
          !validDefault) {
        _fail(BackupInspectionError.invalidSchema);
      }
    }
    final foreignKeys = await database.rawQuery(
      'PRAGMA foreign_key_list(${table.key})',
    );
    token.throwIfCancelled();
    if (table.key != 'Reminders') {
      if (foreignKeys.isNotEmpty) {
        _fail(BackupInspectionError.invalidSchema);
      }
    } else if (foreignKeys.length != 1 ||
        foreignKeys.single['table'] != 'MediaRecords' ||
        foreignKeys.single['from'] != 'record_id' ||
        foreignKeys.single['to'] != 'id' ||
        foreignKeys.single['on_delete'] != 'CASCADE' ||
        foreignKeys.single['on_update'] != 'NO ACTION' ||
        foreignKeys.single['match'] != 'NONE') {
      _fail(BackupInspectionError.invalidSchema);
    }
  }
}

void _checkVersion(Object? value) {
  if (value is! int ||
      !const {7, 8, 9, 10, 11, 12, 13, 14, 15, 16}.contains(value)) {
    _fail(BackupInspectionError.unsupportedVersion);
  }
}

class _Validated {
  _Validated(
    this.version,
    this.timestamp,
    this.counts,
    this.credentials,
    this.paths,
    this.unresolved,
  );
  final int version;
  final DateTime? timestamp;
  final Map<String, int> counts;
  final bool credentials;
  final List<String> paths;
  final int unresolved;
}

Future<_Validated> _validateInIsolate(
  Map<String, Object?>? data,
  String copyPath,
  int maxRows,
  BackupInspectionCancellation token,
) async {
  token.throwIfCancelled();
  final messages = ReceivePort();
  final exits = ReceivePort();
  final exited = Completer<void>();
  final exitSubscription = exits.listen((_) {
    if (!exited.isCompleted) {
      exited.complete();
    }
  });
  final completion = Completer<_Validated>();
  final subscription = messages.listen((message) {
    if (completion.isCompleted) {
      return;
    }
    if (message is _Validated) {
      completion.complete(message);
    } else {
      completion.completeError(
        BackupInspectionException(
          message is BackupInspectionError
              ? message
              : BackupInspectionError.invalidFormat,
        ),
      );
    }
  });
  final result = Future.any([
    completion.future,
    token._cancelled.future.then<_Validated>(
      (_) => _fail(BackupInspectionError.cancelled),
    ),
  ]);
  // Subscribe before spawning; a tiny malformed file may finish immediately.
  unawaited(result.then<void>((_) {}, onError: (Object _) {}));
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
      _validationWorker,
      (messages.sendPort, data, copyPath, maxRows),
      onError: messages.sendPort,
      onExit: exits.sendPort,
      errorsAreFatal: true,
    );
    // Race a single token Future; the worker is killed in finally before the
    // copied file is deleted. No unobserved decode work survives cancellation.
    return await result;
  } finally {
    worker?.kill(priority: Isolate.immediate);
    if (worker != null) {
      await exited.future;
    }
    await subscription.cancel();
    await exitSubscription.cancel();
    messages.close();
    exits.close();
  }
}

void _validationWorker((SendPort, Map<String, Object?>?, String, int) request) {
  try {
    final raw = request.$2 ?? _decodeJson(File(request.$3).readAsStringSync());
    if (raw is! Map<String, dynamic>) {
      _fail(BackupInspectionError.invalidFormat);
    }
    request.$1.send(_validate(raw, request.$4));
  } on BackupInspectionException catch (error) {
    request.$1.send(error.code);
  } catch (_) {
    request.$1.send(BackupInspectionError.invalidFormat);
  }
}

Object? _decodeJson(String text) {
  try {
    return decodeStoredJson(text);
  } catch (_) {
    _fail(BackupInspectionError.invalidFormat);
  }
}

_Validated _validate(Map<String, dynamic> data, int maxRows) {
  _checkVersion(data['version']);
  if (data.length != 5 ||
      !data.keys.toSet().containsAll([
        'version',
        'timestamp',
        ..._tables.values,
      ])) {
    _fail(BackupInspectionError.invalidSchema);
  }
  final timestamp = data['timestamp'] == null
      ? null
      : tryParseStoredDateTime(data['timestamp']);
  if (data['timestamp'] != null && timestamp == null) {
    _fail(BackupInspectionError.invalidData);
  }
  Schema14Shape? version14Shape;
  if (data['version'] == 14) {
    final settings = data['settings'];
    if (settings is! List || settings.length != 1 || settings.single is! Map) {
      _fail(BackupInspectionError.invalidSchema);
    }
    final keys = (settings.single as Map).keys;
    if (keys.any((key) => key is! String)) {
      _fail(BackupInspectionError.invalidSchema);
    }
    version14Shape = identifySchema14FromSettings(keys.cast<String>().toSet());
    if (version14Shape == null) _fail(BackupInspectionError.invalidSchema);
    final reminders = data['reminders'];
    if (reminders is List && reminders.isNotEmpty) {
      if (reminders.first is! Map) _fail(BackupInspectionError.invalidSchema);
      final reminderKeys = (reminders.first as Map).keys;
      if (reminderKeys.any((key) => key is! String)) {
        _fail(BackupInspectionError.invalidSchema);
      }
      version14Shape = identifySchema14(
        settingsColumns: keys.cast<String>().toSet(),
        reminderColumns: reminderKeys.cast<String>().toSet(),
      );
      if (version14Shape == null) _fail(BackupInspectionError.invalidSchema);
    }
  }
  Schema15Shape? version15Shape;
  if (data['version'] == 15) {
    final settings = data['settings'];
    final reminders = data['reminders'];
    if (settings is! List ||
        settings.length != 1 ||
        settings.single is! Map ||
        reminders is! List) {
      _fail(BackupInspectionError.invalidSchema);
    }
    final settingsKeys = (settings.single as Map).keys;
    if (settingsKeys.any((key) => key is! String) ||
        settingsKeys.length != schema15SettingsColumns.length ||
        !settingsKeys.toSet().containsAll(schema15SettingsColumns)) {
      _fail(BackupInspectionError.invalidSchema);
    }
    // Both v15 variants have identical settings. With no reminders there is
    // no extension data to preserve; either variant imports to the same v16.
    version15Shape = Schema15Shape.recordReminder;
    if (reminders.isNotEmpty) {
      if (reminders.first is! Map) _fail(BackupInspectionError.invalidSchema);
      final reminderKeys = (reminders.first as Map).keys;
      if (reminderKeys.any((key) => key is! String)) {
        _fail(BackupInspectionError.invalidSchema);
      }
      version15Shape = identifySchema15(
        settingsColumns: settingsKeys.cast<String>().toSet(),
        reminderColumns: reminderKeys.cast<String>().toSet(),
      );
      if (version15Shape == null) _fail(BackupInspectionError.invalidSchema);
    }
  }
  final ids = <String, Set<String>>{};
  final counts = <String, int>{};
  for (final table in _tables.values) {
    final rows = data[table];
    if (rows is! List) {
      _fail(BackupInspectionError.invalidData);
    }
    if (rows.length > maxRows) {
      _fail(BackupInspectionError.tooManyRows);
    }
    counts[table] = rows.length;
    ids[table] = {};
    final fields = _columnsFor(
      table,
      data['version'] as int,
      version14Shape: version14Shape,
      version15Shape: version15Shape,
    );
    for (final row in rows) {
      if (row is! Map ||
          row.length != fields.length ||
          !row.keys.toSet().containsAll(fields.keys)) {
        _fail(BackupInspectionError.invalidSchema);
      }
      for (final field in fields.entries) {
        final value = row[field.key], type = field.value;
        if (value == null && type.endsWith('?')) {
          continue;
        }
        final valid = switch (type[0]) {
          's' => value is String,
          'd' => tryParseStoredDateTime(value) != null,
          'b' => value is int && (value == 0 || value == 1),
          'q' => value is int && value >= 1 && value <= 4,
          'i' => value is int && value >= 0 && value <= 5,
          'n' => value is int && value >= 0,
          _ => false,
        };
        if (!valid) {
          _fail(BackupInspectionError.invalidData);
        }
      }
      final id = row['id'] as String;
      if (id.trim().isEmpty || !ids[table]!.add(id)) {
        _fail(BackupInspectionError.invalidData);
      }
    }
  }
  if (counts['settings'] != 1 || !ids['settings']!.contains('default')) {
    _fail(BackupInspectionError.invalidData);
  }
  final settings = (data['settings'] as List).single as Map;
  late AppSettings parsedSettings;
  try {
    // Validate the nested document too, including duplicate JSON keys.
    if (data['version'] >= 10) {
      _decodeJson(settings['ai_profiles_json'] as String);
    }
    final drafts = settings['workspace_drafts_json'];
    if (drafts != null) {
      if (drafts is! String || drafts.length > 1048576) {
        _fail(BackupInspectionError.invalidData);
      }
      final decoded = _decodeJson(drafts);
      if (decoded is! Map<String, dynamic>) {
        _fail(BackupInspectionError.invalidData);
      }
      SavedTaskFilter.decode(decoded[SavedTaskFilter.storageKey]);
      TaskTemplate.decode(decoded[TaskTemplate.storageKey]);
    }
    parsedSettings = AppSettings.fromJson(Map<String, dynamic>.from(settings));
  } catch (_) {
    _fail(BackupInspectionError.invalidData);
  }
  final mediaPaths = <String>[];
  for (final row in data['media_records']) {
    if (!const [
      'text',
      'audio',
      'image',
      'video',
      'file',
    ].contains(row['type'])) {
      _fail(BackupInspectionError.invalidData);
    }
    if (row['type'] != 'text') {
      mediaPaths.add(row['content_or_path'] as String);
    }
  }
  var unresolved = 0;
  for (final row in data['reminders']) {
    if ((data['version'] >= 16 ||
            (data['version'] == 15 &&
                version15Shape == Schema15Shape.recordReminder) ||
            (data['version'] == 14 &&
                version14Shape == Schema14Shape.reminderOrigin)) &&
        !const [
          'unknown',
          'manual',
          'aiSuggested',
        ].contains(row['trigger_time_origin'])) {
      _fail(BackupInspectionError.invalidData);
    }
    for (final field in ['capture_proposal_json', 'word_progress_json']) {
      final encoded = row[field];
      if (encoded == null) continue;
      if (encoded is! String || encoded.length > 300000) {
        _fail(BackupInspectionError.invalidData);
      }
      Object? decoded;
      try {
        decoded = _decodeJson(encoded);
      } catch (_) {
        _fail(BackupInspectionError.invalidData);
      }
      if (field == 'capture_proposal_json') {
        if (decoded is! List ||
            decoded.isEmpty ||
            decoded.length > 32 ||
            decoded.any(
              (proposal) =>
                  proposal is! Map ||
                  proposal['id'] is! String ||
                  proposal['task_title'] is! String ||
                  (proposal['task_title'] as String).trim().isEmpty ||
                  proposal['quadrant_level'] is! int ||
                  (proposal['quadrant_level'] as int) < 1 ||
                  (proposal['quadrant_level'] as int) > 4 ||
                  proposal['capture_proposal_json'] != null ||
                  (proposal['trigger_time'] != null &&
                      tryParseStoredDateTime(proposal['trigger_time']) ==
                          null) ||
                  (proposal['event_time'] != null &&
                      tryParseStoredDateTime(proposal['event_time']) == null),
            )) {
          _fail(BackupInspectionError.invalidData);
        }
      } else if (decoded is! Map && decoded is! List) {
        _fail(BackupInspectionError.invalidData);
      }
    }
    if (row['record_id'] != null &&
        !ids['media_records']!.contains(row['record_id'])) {
      unresolved++;
    }
    for (final field in ['linked_task_ids', 'sub_tasks']) {
      final encoded = row[field] as String?;
      if (encoded != null && encoded.trim().isNotEmpty) {
        final list = _decodeJson(encoded);
        if (list is! List || list.any((item) => item is! String)) {
          _fail(BackupInspectionError.invalidData);
        }
        if (list.length > maxRows) {
          _fail(BackupInspectionError.tooManyRows);
        }
        if (field == 'linked_task_ids') {
          if (list.any((id) => (id as String).trim().isEmpty)) {
            _fail(BackupInspectionError.invalidData);
          }
          unresolved += list
              .where((id) => !ids['reminders']!.contains(id))
              .length;
        }
      }
    }
    if (row['recurrence_rule'] != null &&
        !const [
          'none',
          'daily',
          'workday',
          'weekly',
          'monthly',
          'yearly',
        ].contains(row['recurrence_rule'])) {
      _fail(BackupInspectionError.invalidData);
    }
    if (data['version'] >= 15) {
      try {
        final details = TaskDetails.decode(row['details_json'] as String?);
        if (details.kind == 'medicationPlan') {
          MedicationPlan.fromJson(details.data);
        }
        if (details.kind == 'medication') Medicine.fromJson(details.data);
        if (details.kind == 'departure') DeparturePlan.fromJson(details.data);
      } catch (_) {
        _fail(BackupInspectionError.invalidData);
      }
    }
    if (data['version'] >= 14) {
      try {
        LearningQueueService.decode(row['word_progress_json'] as String?);
        final details = row['details_json'] as String?;
        if (details != null) _decodeJson(details);
        TaskDetails.decode(details);
        final proposal = row['capture_proposal_json'];
        if (proposal != null) {
          final values = _decodeJson(proposal as String);
          if (values is! List || values.isEmpty || values.length > 32) {
            throw const FormatException();
          }
          for (final candidate in values) {
            if (candidate is! Map ||
                candidate.keys.any(
                  (key) => !_columnsFor('reminders', 16).containsKey(key),
                )) {
              throw const FormatException();
            }
            final parsed = Reminder.fromJson(
              Map<String, dynamic>.from(candidate),
            );
            if (parsed.detailsJson != null) _decodeJson(parsed.detailsJson!);
            TaskDetails.decode(parsed.detailsJson);
          }
        }
      } catch (_) {
        _fail(BackupInspectionError.invalidData);
      }
    }
    final context = row['context_trigger'] as String?;
    if (context != null && context.trim().isNotEmpty) {
      final rule = _decodeJson(context);
      if (rule is! Map ||
          !rule.keys.toSet().containsAll(['type', 'value']) ||
          rule.keys.any((key) => !['type', 'value', 'prompt'].contains(key)) ||
          !['wifi', 'profile'].contains(rule['type']) ||
          rule['value'] is! String ||
          (rule['value'] as String).trim().isEmpty ||
          (rule.containsKey('prompt') && rule['prompt'] is! String) ||
          (rule['type'] == 'profile' &&
              ![
                'general',
                'office',
                'deepWork',
                'home',
                'commute',
              ].contains(rule['value']))) {
        _fail(BackupInspectionError.invalidData);
      }
    }
  }
  return _Validated(
    data['version'] as int,
    timestamp,
    counts,
    parsedSettings.apiKey.isNotEmpty ||
        parsedSettings.effectiveProfiles.any(
          (p) => p.settings.apiKey.isNotEmpty,
        ),
    mediaPaths,
    unresolved,
  );
}
