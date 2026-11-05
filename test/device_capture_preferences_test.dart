import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/services/device_window_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseHelper db;
  File flag() => File(
    p.join(directory.path, DeviceWindowPreferencesStore.shortcutFileName),
  );
  Future<bool> read() =>
      db.withDeviceWindowPreferences((store) => store.readCaptureShortcut());
  Future<void> write(bool value) => db.withDeviceWindowPreferences(
    (store) => store.writeCaptureShortcut(value),
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'dontforget-capture-pref-',
    );
    db = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    await db.database;
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });
  test(
    'device preference survives reopen without changing business settings or geometry',
    () async {
      final settings = await db.read(
        db.captureGeneration(),
        (sql) => sql.query('Settings'),
      );
      await db.withDeviceWindowPreferences(
        (store) => store.write({'width': 1280.0}),
      );
      final geometry = File(
        p.join(directory.path, DeviceWindowPreferencesStore.fileName),
      );
      final original = await geometry.readAsBytes();
      expect(await read(), isFalse);
      await write(true);
      await write(false);
      await write(true);
      expect(await geometry.readAsBytes(), original);
      expect(
        await db.read(db.captureGeneration(), (sql) => sql.query('Settings')),
        settings,
      );
      await db.close();
      db = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
      expect(await read(), isTrue);
      expect(jsonDecode(await flag().readAsString()), {
        'version': 1,
        'enabled': true,
      });
      expect(
        await directory.list().where((e) => e.path.endsWith('.tmp')).toList(),
        isEmpty,
      );
    },
  );
  test(
    'malformed, oversized, and newer formats are retained byte-for-byte',
    () async {
      for (final data in [
        '{broken',
        '{"version":2,"enabled":true}',
        '{"version":1,"enabled":"yes"}',
        '{"version":1,"enabled":true,"future":1}',
        ' ' * 4097,
      ]) {
        await flag().writeAsString(data);
        await expectLater(read(), throwsA(anything));
        await expectLater(write(false), throwsA(anything));
        expect(await flag().readAsString(), data);
      }
    },
  );
  test('directory at preferences path cannot be replaced', () async {
    await Directory(flag().path).create();
    await expectLater(write(true), throwsA(isA<FileSystemException>()));
    expect(await Directory(flag().path).exists(), isTrue);
  });
}
