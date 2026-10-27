import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/local_media_store.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _TrackingFactory implements DatabaseFactory {
  _TrackingFactory({this.onOpen, this.noTableXinfo = false});
  final Future<void> Function(Database database)? onOpen;
  final bool noTableXinfo;
  final List<String> openedPaths = [];
  final List<OpenDatabaseOptions?> optionsSeen = [];
  Database? opened;

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    openedPaths.add(path);
    optionsSeen.add(options);
    final database = await databaseFactoryFfi.openDatabase(
      path,
      options: options,
    );
    opened = database;
    await onOpen?.call(database);
    return noTableXinfo ? _LegacySqlite(database) : database;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Models supported pre-3.26 SQLite engines: unknown PRAGMAs return no rows.
class _LegacySqlite implements Database {
  _LegacySqlite(this.delegate);
  final Database delegate;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => sql.startsWith('PRAGMA table_xinfo')
      ? Future.value([])
      : delegate.rawQuery(sql, arguments);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      delegate.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => delegate.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  @override
  Future<void> close() => delegate.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late Directory staging;
  late BackupInspector inspector;
  late Map<String, dynamic> fixture;
  late String schema;

  Matcher error(BackupInspectionError code) => isA<BackupInspectionException>()
      .having((exception) => exception.code, 'safe error code', code);

  Future<String> digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<File> jsonFile({
    String? contents,
    String name = 'snapshot.json',
  }) async {
    final file = File(paths.join(directory.path, name));
    await file.writeAsString(contents ?? jsonEncode(fixture));
    return file;
  }

  Future<File> sqliteFile({
    int version = 8,
    String? sql,
    Future<void> Function(Database)? alter,
  }) async {
    final file = File(paths.join(directory.path, 'mirror.db'));
    final database = await databaseFactoryFfi.openDatabase(
      file.path,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, _) async {
          for (final statement in (sql ?? schema).split(';')) {
            if (statement.trim().isNotEmpty) {
              await db.execute(statement);
            }
          }
          for (final table in {
            'Settings': 'settings',
            'MediaRecords': 'media_records',
            'Reminders': 'reminders',
          }.entries) {
            for (final row in fixture[table.value] as List) {
              await db.insert(table.key, Map<String, Object?>.from(row as Map));
            }
          }
          await alter?.call(db);
        },
      ),
    );
    await database.close();
    return file;
  }

  setUp(() async {
    sqfliteFfiInit();
    final raw = await Directory.systemTemp.createTemp('dontforget-inspector-');
    directory = Directory(await raw.resolveSymbolicLinks());
    staging = await Directory(paths.join(directory.path, 'staging')).create();
    inspector = BackupInspector(
      databaseFactoryFfi,
      temporaryDirectory: staging,
    );
    schema = await File('test/fixtures/schema_v7.sql').readAsString();
    final present = await File(
      paths.join(directory.path, 'present.png'),
    ).writeAsString('Fixture metadata only; no image or media is decoded.');
    fixture = {
      'version': 8,
      'timestamp': '2026-10-21T10:00:00.000+08:00',
      'settings': [
        AppSettings.defaults().copyWith(apiKey: 'private-fixture-key').toJson()
          ..remove('ai_profiles_json')
          ..remove('ai_fallback_enabled')
          ..remove('appearance')
          ..remove('workspace_drafts_json')
          ..remove('input_send_mode'),
      ],
      'media_records': [
        {
          'id': 'present',
          'type': 'image',
          'content_or_path': present.path,
          'created_at': '2024-02-29T10:00:00Z',
        },
        {
          'id': 'missing',
          'type': 'file',
          'content_or_path': paths.join(directory.path, 'missing.txt'),
          'created_at': '2024-02-29T10:00:00Z',
        },
      ],
      'reminders': [
        Reminder(
          id: 'task',
          taskTitle: 'Synthetic fixture',
          quadrantLevel: 2,
          recordId: 'present',
          linkedTaskIds: ['unknown-task'],
          subTasks: '["First step"]',
          contextTrigger: '{"type":"profile","value":"home"}',
          createdAt: DateTime.utc(2026),
        ).toJson()..removeWhere(
          (key, _) => const {
            'review_notifications_enabled',
            'event_time',
            'recurrence_event_anchor_time',
            'suggested_trigger_time',
            'source_text', 'capture_proposal_json', 'word_progress_json',
            'capture_pending',
            'is_pinned',
            'notice_revision',
            'notice_acknowledged_at',
            'upcoming_dismissed_at',
            'snoozed_at',
            'recurrence_anchor_time',
          }.contains(key),
        ),
      ],
    };
  });

  tearDown(() async {
    // Every success, rejection and cancellation must remove its private copy.
    expect(await staging.list().toList(), isEmpty);
    await directory.delete(recursive: true);
  });

  test(
    'relocated owned media is available without rewriting a backup',
    () async {
      final documents = await Directory(
        paths.join(directory.path, 'new', 'Documents'),
      ).create(recursive: true);
      final imported = await Directory(
        paths.join(documents.path, 'media', 'import-saved'),
      ).create(recursive: true);
      final attachment = await File(
        paths.join(imported.path, 'recording.m4a'),
      ).writeAsString('preserved attachment bytes');
      final old = paths.join(
        directory.path,
        'old',
        'Documents',
        'media',
        'import-saved',
        'recording.m4a',
      );
      fixture['media_records'][1]['content_or_path'] = old;
      final source = await jsonFile();
      final before = await digest(source);
      final reader = BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: staging,
        mediaStore: LocalMediaStore(documentsDirectory: () async => documents),
      );
      final result = await reader.inspect(source);
      expect(result.missingMedia, 0);
      expect(await digest(source), before);
      expect(await attachment.readAsString(), 'preserved attachment bytes');
      expect(await File(old).exists(), isFalse);
    },
  );

  test(
    'relocated media through a symlink remains unavailable',
    () async {
      final documents = await Directory(
        paths.join(directory.path, 'new', 'Documents'),
      ).create(recursive: true);
      final media = await Directory(
        paths.join(documents.path, 'media'),
      ).create();
      await Link(paths.join(media.path, 'import-saved')).create(directory.path);
      fixture['media_records'][1]['content_or_path'] =
          '/old-container/Documents/media/import-saved/present.png';
      final source = await jsonFile();
      final before = await digest(source);
      final result = await BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: staging,
        mediaStore: LocalMediaStore(documentsDirectory: () async => documents),
      ).inspect(source);
      expect(result.missingMedia, 1);
      expect(await digest(source), before);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires Windows privileges'
        : false,
  );

  for (final version in [7, 8]) {
    for (final format in ['json', 'sqlite']) {
      test(
        'v$version $format preview preserves source and returns summary only',
        () async {
          fixture['version'] = version;
          final file = format == 'json'
              ? await jsonFile()
              : await sqliteFile(version: version);
          final before = await digest(file);
          final result = await inspector.inspect(file);
          expect(result.version, version);
          expect(result.digest, before);
          expect(await digest(file), before);
          expect(result.counts, {
            'settings': 1,
            'media_records': 2,
            'reminders': 1,
          });
          expect(result.containsCredentials, isTrue);
          expect(result.missingMedia, 1);
          expect(result.unresolvedReferences, 1);
          expect(
            result.timestamp,
            format == 'json' ? DateTime.utc(2026, 10, 21, 2) : null,
          );
          expect(() => result.counts['settings'] = 4, throwsUnsupportedError);
          expect(result.toString(), isNot(contains('private-fixture-key')));
          expect(await File('${file.path}-wal').exists(), isFalse);
          expect(await File('${file.path}-journal').exists(), isFalse);
        },
      );
    }
  }

  test(
    'actual current exports and isolated primary database remain unchanged',
    () async {
      final appDirectory = await Directory(
        paths.join(directory.path, 'isolated-app'),
      ).create();
      final helper = DatabaseHelper.forTesting(
        appDirectory.path,
        databaseFactoryFfi,
      );
      try {
        await helper.database;
        await helper.createMirrorBackup();
        final primary = File(
          paths.join(appDirectory.path, 'dont_forget_v3.db'),
        );
        final primaryDigest = await digest(primary);
        for (final name in ['ha_snapshot.json', 'dont_forget_v3.mirror.db']) {
          final source = File(paths.join(appDirectory.path, name));
          final originalDigest = await digest(source);
          final result = await inspector.inspect(source);
          expect(result.version, DatabaseHelper.schemaVersion);
          expect(result.containsCredentials, isFalse);
          expect(await digest(source), originalDigest);
          expect(await digest(primary), primaryDigest);
        }
      } finally {
        await helper.close();
      }
    },
  );

  test(
    'SQLite opens only a disposable copy with readOnly and no migration',
    () async {
      final file = await sqliteFile();
      final tracking = _TrackingFactory();
      await BackupInspector(
        tracking,
        temporaryDirectory: staging,
      ).inspect(file);
      expect(tracking.openedPaths, hasLength(1));
      expect(tracking.openedPaths.single, isNot(file.path));
      expect(paths.isWithin(staging.path, tracking.openedPaths.single), isTrue);
      expect(tracking.optionsSeen.single!.readOnly, isTrue);
      expect(tracking.optionsSeen.single!.singleInstance, isFalse);
      expect(tracking.optionsSeen.single!.version, isNull);
      expect(tracking.opened!.isOpen, isFalse);
    },
  );

  for (final version in [6, DatabaseHelper.schemaVersion + 1, 99]) {
    for (final format in ['json', 'sqlite']) {
      test(
        'rejects unsupported v$version $format without changing it',
        () async {
          fixture['version'] = version;
          final file = format == 'json'
              ? await jsonFile()
              : await sqliteFile(version: version);
          final before = await digest(file);
          await expectLater(
            inspector.inspect(file),
            throwsA(error(BackupInspectionError.unsupportedVersion)),
          );
          expect(await digest(file), before);
        },
      );
    }
  }

  final badDates = [
    '2026-02-30T12:00:00Z',
    '2026-13-01T12:00:00Z',
    '2026-00-01T12:00:00Z',
    '2026-01-00T12:00:00Z',
    '2026-01-42T12:00:00Z',
    '2026-01-01T25:00:00Z',
    '2026-01-01T12:60:00Z',
    '2026-01-01T12:00:60Z',
    '2023-02-29T12:00:00Z',
    '2026-01-01T12:00:00+25:00',
    '2026-01-01T12:00:00+08:60',
  ];
  for (final date in badDates) {
    test('rejects overflow ISO date $date', () async {
      fixture['timestamp'] = date;
      await expectLater(
        inspector.inspect(await jsonFile()),
        throwsA(error(BackupInspectionError.invalidData)),
      );
    });
  }
  for (final date in [
    '2024-02-29T23:59:59.999Z',
    '2024-02-29T23:59:59.123456-05:30',
    '2024-02-29T23:59:59+0800',
  ]) {
    test('preserves valid leap day and timezone instant $date', () async {
      fixture['timestamp'] = date;
      final result = await inspector.inspect(await jsonFile());
      expect(result.timestamp, DateTime.parse(date));
      expect(result.timestamp!.isUtc, isTrue);
    });
  }
  test('applies strict dates to reminder and media rows too', () async {
    fixture['reminders'][0]['trigger_time'] = '2026-02-30T12:00:00';
    await expectLater(
      inspector.inspect(await jsonFile()),
      throwsA(error(BackupInspectionError.invalidData)),
    );
    fixture['reminders'][0]['trigger_time'] = null;
    fixture['media_records'][0]['created_at'] = '2026-13-01T00:00:00Z';
    await expectLater(
      inspector.inspect(await jsonFile()),
      throwsA(error(BackupInspectionError.invalidData)),
    );
  });

  final invalidRows = <String, void Function(Map<String, dynamic>)>{
    'duplicate IDs': (data) => data['reminders'].add(data['reminders'][0]),
    'empty ID': (data) => data['reminders'][0]['id'] = ' ',
    'wrong flag type': (data) => data['reminders'][0]['is_completed'] = true,
    'quadrant overflow': (data) => data['reminders'][0]['quadrant_level'] = 5,
    'review overflow': (data) => data['reminders'][0]['review_level'] = 6,
    'unknown media kind': (data) => data['media_records'][0]['type'] = 'script',
    'unknown recurrence': (data) =>
        data['reminders'][0]['recurrence_rule'] = 'hourly',
    'default settings missing': (data) => data['settings'][0]['id'] = 'other',
    'legacy object subtasks': (data) => data['reminders'][0]['sub_tasks'] =
        '[{"title":"Old format","isCompleted":false}]',
    'non-string link': (data) =>
        data['reminders'][0]['linked_task_ids'] = '[1]',
    'empty link': (data) => data['reminders'][0]['linked_task_ids'] = '[""]',
    'invalid context value': (data) => data['reminders'][0]['context_trigger'] =
        '{"type":"profile","value":"unknown"}',
    'invalid context type': (data) => data['reminders'][0]['context_trigger'] =
        '{"type":"script","value":"x"}',
    'invalid context fields': (data) =>
        data['reminders'][0]['context_trigger'] =
            '{"type":"wifi","value":"x","secret":1}',
  };
  for (final entry in invalidRows.entries) {
    test('rejects ${entry.key}', () async {
      entry.value(fixture);
      await expectLater(
        inspector.inspect(await jsonFile()),
        throwsA(error(BackupInspectionError.invalidData)),
      );
    });
  }
  test(
    'rejects legacy free-text context instead of silently dropping it',
    () async {
      fixture['reminders'][0]['context_trigger'] = 'home';
      await expectLater(
        inspector.inspect(await jsonFile()),
        throwsA(error(BackupInspectionError.invalidFormat)),
      );
    },
  );
  test(
    'counts broken record and task references without exposing their IDs',
    () async {
      fixture['reminders'][0]['record_id'] = 'absent';
      final result = await inspector.inspect(await jsonFile());
      expect(result.unresolvedReferences, 2);
    },
  );
  test('does not fetch URLs or resolve relative attachment paths', () async {
    fixture['media_records'][0]['content_or_path'] =
        'https://example.invalid/private.png';
    fixture['media_records'][1]['content_or_path'] = 'relative.txt';
    expect((await inspector.inspect(await jsonFile())).missingMedia, 2);
  });

  for (final badJson in [
    '{',
    '[]',
    '{"version":8,"version":7}',
    '{"version":8,"ver\\u0073ion":7}',
  ]) {
    test('rejects malformed or duplicate JSON keys: $badJson', () async {
      await expectLater(
        inspector.inspect(await jsonFile(contents: badJson)),
        throwsA(error(BackupInspectionError.invalidFormat)),
      );
    });
  }
  test('rejects excessive JSON nesting before decoding', () async {
    final encoded =
        '${List.filled(65, '[').join()}0${List.filled(65, ']').join()}';
    await expectLater(
      inspector.inspect(await jsonFile(contents: encoded)),
      throwsA(error(BackupInspectionError.invalidFormat)),
    );
  });
  for (final field in ['missing', 'extra', 'schema9']) {
    test('rejects $field fields without echoing secrets', () async {
      if (field == 'missing') {
        fixture.remove('settings');
      }
      if (field == 'extra') {
        fixture['reminders'][0]['secret'] = 'private-fixture-key';
      }
      if (field == 'schema9') {
        fixture['settings'][0]['ai_profiles_json'] = 'private-fixture-key';
      }
      final file = await jsonFile();
      final before = await digest(file);
      await expectLater(
        inspector.inspect(file),
        throwsA(error(BackupInspectionError.invalidSchema)),
      );
      expect(await digest(file), before);
    });
  }

  // Defined as transforms so setup's historical schema is the source of truth.
  final transforms = <String, String Function(String)>{
    'wrong affinity': (sql) => sql.replaceFirst('api_key TEXT', 'api_key BLOB'),
    'missing required constraint': (sql) =>
        sql.replaceFirst('task_title TEXT NOT NULL', 'task_title TEXT'),
    'missing primary key': (sql) =>
        sql.replaceFirst('id TEXT PRIMARY KEY', 'id TEXT'),
    'different foreign key': (sql) =>
        sql.replaceFirst('ON DELETE CASCADE', 'ON DELETE SET NULL'),
    'different default': (sql) => sql.replaceFirst(
      'review_level INTEGER DEFAULT 0',
      'review_level INTEGER DEFAULT 1',
    ),
    'extra check': (sql) => sql.replaceFirst(
      'api_key TEXT',
      "api_key TEXT CHECK(length(api_key) >= 0)",
    ),
  };
  for (final entry in transforms.entries) {
    test('rejects SQLite ${entry.key}', () async {
      final file = await sqliteFile(sql: entry.value(schema));
      await expectLater(
        inspector.inspect(file),
        throwsA(error(BackupInspectionError.invalidSchema)),
      );
    });
  }
  for (final statement in [
    'CREATE VIEW Extra AS SELECT * FROM Settings',
    'CREATE TRIGGER Extra AFTER INSERT ON Settings BEGIN SELECT 1; END',
    'CREATE INDEX Extra ON Settings(api_key)',
    'CREATE TABLE Extra(id TEXT)',
    'ALTER TABLE Settings ADD COLUMN derived TEXT GENERATED ALWAYS AS (api_key) VIRTUAL',
  ]) {
    test(
      'rejects extra or executable SQLite schema objects: $statement',
      () async {
        final file = await sqliteFile(alter: (db) => db.execute(statement));
        await expectLater(
          inspector.inspect(file),
          throwsA(error(BackupInspectionError.invalidSchema)),
        );
      },
    );
  }
  test('accepts upgraded v7 equivalent quoted recurrence defaults', () async {
    final file = await sqliteFile(
      sql: schema.replaceFirst("DEFAULT 'none'", 'DEFAULT "none"'),
    );
    expect((await inspector.inspect(file)).version, 8);
  });

  test(
    'accepts Android locale metadata without counting it as user data',
    () async {
      final file = await sqliteFile(
        alter: (db) async {
          await db.execute('CREATE TABLE android_metadata (locale TEXT)');
          await db.insert('android_metadata', {'locale': 'zh_CN'});
        },
      );
      final result = await inspector.inspect(file);
      expect(result.counts, {
        'settings': 1,
        'media_records': 2,
        'reminders': 1,
      });
    },
  );
  for (final sql in [
    'CREATE TABLE android_metadata (locale TEXT, injected TEXT)',
    'CREATE TABLE android_metadata (locale TEXT UNIQUE)',
    'CREATE VIEW android_metadata AS SELECT api_key AS locale FROM Settings',
  ]) {
    test('rejects forged Android metadata: $sql', () async {
      final file = await sqliteFile(alter: (db) => db.execute(sql));
      await expectLater(
        inspector.inspect(file),
        throwsA(error(BackupInspectionError.invalidSchema)),
      );
    });
  }
  test('rejects executable objects attached to Android metadata', () async {
    final file = await sqliteFile(
      alter: (db) async {
        await db.execute('CREATE TABLE android_metadata (locale TEXT)');
        await db.execute(
          'CREATE TRIGGER MetadataHook AFTER INSERT ON android_metadata BEGIN SELECT 1; END',
        );
      },
    );
    await expectLater(
      inspector.inspect(file),
      throwsA(error(BackupInspectionError.invalidSchema)),
    );
  });
  test(
    'pre-3.26 SQLite falls back to table_info without losing schema checks',
    () async {
      final file = await sqliteFile();
      final tracking = _TrackingFactory(noTableXinfo: true);
      final result = await BackupInspector(
        tracking,
        temporaryDirectory: staging,
      ).inspect(file);
      expect(result.version, 8);
      expect(result.counts['reminders'], 1);
    },
  );
  test('table_info fallback still rejects invalid constraints', () async {
    final file = await sqliteFile(
      sql: schema.replaceFirst('ON DELETE CASCADE', 'ON DELETE SET NULL'),
    );
    await expectLater(
      BackupInspector(
        _TrackingFactory(noTableXinfo: true),
        temporaryDirectory: staging,
      ).inspect(file),
      throwsA(error(BackupInspectionError.invalidSchema)),
    );
  });
  test(
    'table_info fallback rejects generated columns before reading rows',
    () async {
      final file = await sqliteFile(
        alter: (db) => db.execute(
          'ALTER TABLE Settings ADD COLUMN derived TEXT GENERATED ALWAYS AS (api_key) VIRTUAL',
        ),
      );
      await expectLater(
        BackupInspector(
          _TrackingFactory(noTableXinfo: true),
          temporaryDirectory: staging,
        ).inspect(file),
        throwsA(error(BackupInspectionError.invalidSchema)),
      );
    },
  );

  test('enforces file and table limits and cleans temporary copies', () async {
    final file = await jsonFile();
    await expectLater(
      BackupInspector(
        databaseFactoryFfi,
        maxBytes: 16,
        temporaryDirectory: staging,
      ).inspect(file),
      throwsA(error(BackupInspectionError.tooLarge)),
    );
    await expectLater(
      BackupInspector(
        databaseFactoryFfi,
        maxRows: 1,
        temporaryDirectory: staging,
      ).inspect(file),
      throwsA(error(BackupInspectionError.tooManyRows)),
    );
    await expectLater(
      BackupInspector(
        databaseFactoryFfi,
        maxRows: 1,
        temporaryDirectory: staging,
      ).inspect(await sqliteFile()),
      throwsA(error(BackupInspectionError.tooManyRows)),
    );
  });
  test('bounds lists inside reminder fields too', () async {
    fixture['reminders'][0]['sub_tasks'] = '["one","two","three"]';
    await expectLater(
      BackupInspector(
        databaseFactoryFfi,
        maxRows: 2,
        temporaryDirectory: staging,
      ).inspect(await jsonFile()),
      throwsA(error(BackupInspectionError.tooManyRows)),
    );
  });
  for (final suffix in ['-wal', '-journal', '-shm']) {
    test(
      'rejects a source with $suffix without touching either file',
      () async {
        final file = await sqliteFile();
        final before = await digest(file);
        final sidecar = await File(
          '${file.path}$suffix',
        ).writeAsString('in progress');
        await expectLater(
          inspector.inspect(file),
          throwsA(error(BackupInspectionError.unsafeSource)),
        );
        expect(await digest(file), before);
        expect(await sidecar.readAsString(), 'in progress');
      },
    );
  }
  test(
    'rejects directories and symlinks including parent-directory links',
    () async {
      final file = await jsonFile();
      await expectLater(
        inspector.inspect(File(staging.path)),
        throwsA(error(BackupInspectionError.unsafeSource)),
      );
      final link = await Link(
        paths.join(directory.path, 'alias.json'),
      ).create(file.path);
      await expectLater(
        inspector.inspect(File(link.path)),
        throwsA(error(BackupInspectionError.unsafeSource)),
      );
      final folderLink = await Link(
        paths.join(directory.path, 'alias-folder'),
      ).create(directory.path);
      await expectLater(
        inspector.inspect(File(paths.join(folderLink.path, 'snapshot.json'))),
        throwsA(error(BackupInspectionError.unsafeSource)),
      );
    },
    skip: Platform.isWindows,
  );
  test(
    'macOS system temp aliases are checked through their canonical parent',
    () async {
      final file = await jsonFile();
      if (file.path.startsWith('/private/var/')) {
        expect(
          (await inspector.inspect(
            File(file.path.replaceFirst('/private/var/', '/var/')),
          )).version,
          8,
        );
      } else if (file.path.startsWith('/private/tmp/')) {
        expect(
          (await inspector.inspect(
            File(file.path.replaceFirst('/private/tmp/', '/tmp/')),
          )).version,
          8,
        );
      }
    },
    skip: !Platform.isMacOS,
  );
  test('rejects source changes during validation', () async {
    final source = await sqliteFile();
    final tracking = _TrackingFactory(
      onOpen: (_) async {
        await source.writeAsBytes([0], mode: FileMode.append);
      },
    );
    await expectLater(
      BackupInspector(tracking, temporaryDirectory: staging).inspect(source),
      throwsA(error(BackupInspectionError.sourceChanged)),
    );
  });
  test('rejects a source that acquires a WAL during validation', () async {
    final source = await sqliteFile();
    final tracking = _TrackingFactory(
      onOpen: (_) async {
        await File('${source.path}-wal').writeAsString('new writer');
      },
    );
    await expectLater(
      BackupInspector(tracking, temporaryDirectory: staging).inspect(source),
      throwsA(error(BackupInspectionError.unsafeSource)),
    );
  });
  test(
    'pre-cancelled inspection never creates a copy or opens SQLite',
    () async {
      final token = BackupInspectionCancellation()..cancel();
      final tracking = _TrackingFactory();
      await expectLater(
        BackupInspector(
          tracking,
          temporaryDirectory: staging,
        ).inspect(await jsonFile(), cancellation: token),
        throwsA(error(BackupInspectionError.cancelled)),
      );
      expect(tracking.openedPaths, isEmpty);
    },
  );
  test(
    'cancellation after an in-flight SQLite open closes and cleans the copy',
    () async {
      final token = BackupInspectionCancellation();
      final started = Completer<void>();
      final release = Completer<void>();
      final tracking = _TrackingFactory(
        onOpen: (_) async {
          started.complete();
          await release.future;
        },
      );
      final future = BackupInspector(
        tracking,
        temporaryDirectory: staging,
      ).inspect(await sqliteFile(), cancellation: token);
      final assertion = expectLater(
        future,
        throwsA(error(BackupInspectionError.cancelled)),
      );
      await started.future;
      token.cancel();
      release.complete();
      await assertion;
      expect(tracking.opened!.isOpen, isFalse);
      expect(await staging.list().toList(), isEmpty);
    },
  );
  test('errors never reveal selected paths, raw data or credentials', () async {
    final source = await jsonFile(
      contents: '{"private-fixture-key":',
      name: 'private-fixture-key.json',
    );
    try {
      await inspector.inspect(source);
      fail('accepted malformed JSON');
    } on BackupInspectionException catch (exception) {
      expect(exception.toString(), isNot(contains('private-fixture-key')));
      expect(exception.toString(), isNot(contains(directory.path)));
    }
    await expectLater(
      inspector.inspect(
        File(paths.join(directory.path, 'absent-private-fixture-key')),
      ),
      throwsA(error(BackupInspectionError.unreadable)),
    );
  });
}
