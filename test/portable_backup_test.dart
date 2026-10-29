import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/portable_backup_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DatabaseHelper database;
  const service = PortableBackupService();
  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('dontforget-bundle-');
    database = DatabaseHelper.forTesting('${root.path}/db', databaseFactoryFfi);
    await database.database;
  });
  tearDown(() async {
    await database.close(createBackup: false);
    await root.delete(recursive: true);
  });
  Future<void> seed() async {
    final file = File('${root.path}/image.png');
    await file.writeAsBytes([1, 2, 3, 4, 5]);
    await database.writeTransaction(database.captureGeneration(), (db) async {
      final settings = AppSettings.defaults().copyWith(
        apiKey: 'synthetic-key-never-export',
      );
      await db.update(
        'Settings',
        settings.toJson(),
        where: 'id = ?',
        whereArgs: ['default'],
      );
      for (final record in [
        MediaRecord(
          id: 'image',
          type: 'image',
          contentOrPath: file.path,
          createdAt: DateTime(2030),
        ),
        MediaRecord(
          id: 'missing',
          type: 'audio',
          contentOrPath: '${root.path}/absent.wav',
          createdAt: DateTime(2030),
        ),
        MediaRecord(
          id: 'text',
          type: 'text',
          contentOrPath: 'Keep original source',
          createdAt: DateTime(2030),
        ),
      ]) {
        await db.insert('MediaRecords', record.toJson());
      }
      await db.insert(
        'Reminders',
        Reminder(
          id: 'task',
          recordId: 'image',
          taskTitle: 'Original task',
          quadrantLevel: 2,
        ).toJson(),
      );
    });
  }

  Future<File> exported() async {
    final bundle = await service.create(database, database.captureGeneration());
    final file = File('${root.path}/bundle.json');
    await file.writeAsBytes(bundle.bytes);
    return file;
  }

  test(
    'bundle carries attachment bytes, missing references and no model keys',
    () async {
      await seed();
      final bundle = await service.create(
        database,
        database.captureGeneration(),
      );
      final text = utf8.decode(bundle.bytes);
      expect(bundle.mediaCount, 1);
      expect(bundle.missingMedia, ['missing']);
      expect(text, contains('Keep original source'));
      expect(text, contains(base64Encode([1, 2, 3, 4, 5])));
      expect(text, isNot(contains('synthetic-key-never-export')));
      final settings = await database.read(
        database.captureGeneration(),
        (db) => db.query('Settings'),
      );
      expect(settings.single['api_key'], 'synthetic-key-never-export');
    },
  );
  test(
    'restore preparation remaps media safely and passes existing backup preview',
    () async {
      await seed();
      final file = await exported();
      final hash = sha256.convert(await file.readAsBytes());
      final preview = await service.inspect(file);
      final snapshot = await service.prepareRestore(
        file,
        Directory('${root.path}/restored-media'),
        expectedDigest: preview.digest,
        isCurrent: () => true,
      );
      final value = jsonDecode(await snapshot.readAsString());
      final image = (value['media_records'] as List).firstWhere(
        (r) => r['id'] == 'image',
      );
      expect(await File(image['content_or_path']).readAsBytes(), [
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(image['content_or_path'], isNot('${root.path}/image.png'));
      final inspected = await BackupInspector(
        databaseFactoryFfi,
      ).inspect(snapshot);
      expect(inspected.version, DatabaseHelper.schemaVersion);
      expect(inspected.missingMedia, 1);
      expect(sha256.convert(await file.readAsBytes()), hash);
      expect(await File('${root.path}/image.png').readAsBytes(), [
        1,
        2,
        3,
        4,
        5,
      ]);
    },
  );
  test('digest mismatch rejects before creating restore files', () async {
    await seed();
    final file = await exported();
    final value = jsonDecode(await file.readAsString());
    value['attachments'][0]['bytes'] = base64Encode([9]);
    await file.writeAsString(jsonEncode(value));
    expect(
      service.prepareRestore(
        file,
        Directory('${root.path}/rejected'),
        expectedDigest: 'x',
        isCurrent: () => true,
      ),
      throwsFormatException,
    );
    await Future<void>.delayed(Duration.zero);
    expect(await Directory('${root.path}/rejected').exists(), isFalse);
  });
  test('a changed bundle cannot reuse an earlier confirmation', () async {
    await seed();
    final file = await exported();
    final preview = await service.inspect(file);
    await file.writeAsString('${await file.readAsString()}\n');
    await expectLater(
      service.prepareRestore(
        file,
        Directory('${root.path}/rejected'),
        expectedDigest: preview.digest,
        isCurrent: () => true,
      ),
      throwsFormatException,
    );
    expect(await Directory('${root.path}/rejected').exists(), isFalse);
  });
  test('untrusted filenames cannot traverse directories', () async {
    await seed();
    final file = await exported();
    final value = jsonDecode(await file.readAsString());
    value['attachments'][0]['name'] = '../../override.png';
    await file.writeAsString(jsonEncode(value));
    final preview = await service.inspect(file);
    final snapshot = await service.prepareRestore(
      file,
      Directory('${root.path}/safe'),
      expectedDigest: preview.digest,
      isCurrent: () => true,
    );
    final data = jsonDecode(await snapshot.readAsString());
    final image = (data['media_records'] as List).firstWhere(
      (r) => r['id'] == 'image',
    );
    expect(
      p.isWithin(p.join(root.path, 'safe'), image['content_or_path'] as String),
      isTrue,
    );
    expect(await File('${root.path}/override.png').exists(), isFalse);
  });
  test('missing attachment manifest cannot silently omit a file', () async {
    await seed();
    final file = await exported();
    final value = jsonDecode(await file.readAsString());
    value['attachments'] = [];
    await file.writeAsString(jsonEncode(value));
    await expectLater(service.inspect(file), throwsFormatException);
  });
  test('stale session creates no restore files', () async {
    await seed();
    final file = await exported();
    final preview = await service.inspect(file);
    await expectLater(
      service.prepareRestore(
        file,
        Directory('${root.path}/stale'),
        expectedDigest: preview.digest,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    expect(await Directory('${root.path}/stale').exists(), isFalse);
  });
}
