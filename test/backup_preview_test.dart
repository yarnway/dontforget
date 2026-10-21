import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/ui/screens/backup_preview_screen.dart';

class _PreviewFixture extends BackupInspector {
  _PreviewFixture() : super(databaseFactoryFfi);
  @override
  Future<BackupPreview> inspect(File source) async => const BackupPreview(
    version: 9,
    digest: 'fixture-digest',
    counts: {'settings': 1, 'media_records': 2, 'reminders': 3},
    containsCredentials: true,
    missingMedia: 2,
    unresolvedReferences: 0,
  );
}

void main() {
  late Directory directory;
  late DatabaseHelper helper;
  late BackupInspector inspector;
  late File snapshot;
  late File mainFile;
  Future<String> digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'dontforget-preview-test-',
    );
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    final db = await helper.database;
    await db.update('Settings', {'api_key': 'private-fixture-key'});
    await db.insert(
      'MediaRecords',
      MediaRecord(
        id: 'media',
        type: 'audio',
        contentOrPath: '${directory.path}/missing.m4a',
        createdAt: DateTime(2026),
      ).toJson(),
    );
    await db.insert(
      'Reminders',
      Reminder(
        id: 'task',
        recordId: 'media',
        taskTitle: 'Fixture',
        quadrantLevel: 2,
        linkedTaskIds: ['missing-id'],
      ).toJson(),
    );
    await helper.createMirrorBackup();
    await helper.close();
    inspector = BackupInspector(databaseFactoryFfi);
    snapshot = File('${directory.path}/ha_snapshot.json');
    mainFile = File('${directory.path}/dont_forget_v3.db');
  });
  tearDown(() async {
    await helper.close();
    await directory.delete(recursive: true);
  });

  for (final format in ['json', 'sqlite']) {
    test(
      '$format preview is read-only and reports missing media without exposing credentials',
      () async {
        final file = format == 'json'
            ? snapshot
            : File('${directory.path}/dont_forget_v3.mirror.db');
        final original = await digest(file), main = await digest(mainFile);
        final result = await inspector.inspect(file);
        expect(result.version, 9);
        expect(result.counts, {
          'settings': 1,
          'media_records': 1,
          'reminders': 1,
        });
        expect(result.missingMedia, 1);
        expect(result.unresolvedReferences, 1);
        expect(result.containsCredentials, isTrue);
        expect(result.digest, original);
        expect(await digest(file), original);
        expect(await digest(mainFile), main);
      },
    );
  }
  for (final version in [7, 8]) {
    test(
      'historical v$version standalone mirror is previewed without migration',
      () async {
        final file = File('${directory.path}/old-$version.db');
        final db = await databaseFactoryFfi.openDatabase(
          file.path,
          options: OpenDatabaseOptions(
            version: version,
            onCreate: (db, _) async {
              for (final statement in (await File(
                'test/fixtures/schema_v7.sql',
              ).readAsString()).split(';')) {
                if (statement.trim().isNotEmpty) await db.execute(statement);
              }
            },
          ),
        );
        await db.insert('Settings', {'id': 'default'});
        await db.close();
        final original = await digest(file);
        expect((await inspector.inspect(file)).version, version);
        expect(await digest(file), original);
      },
    );
  }
  for (final invalid in [
    'future',
    'duplicate',
    'type',
    'missing',
    'unknown',
    'profiles',
  ]) {
    test(
      'rejects $invalid snapshot and preserves source and current DB',
      () async {
        final data = jsonDecode(await snapshot.readAsString());
        switch (invalid) {
          case 'future':
            data['version'] = 99;
          case 'duplicate':
            data['reminders'].add(data['reminders'].first);
          case 'type':
            data['reminders'].first['is_completed'] = 'false';
          case 'missing':
            data.remove('settings');
          case 'unknown':
            data['reminders'].first['mystery'] = true;
          case 'profiles':
            data['settings'].first['ai_profiles_json'] =
                '[{"api_key":"private-fixture-key"}]';
        }
        final file = File('${directory.path}/invalid.json');
        await file.writeAsString(jsonEncode(data));
        final original = await digest(file), main = await digest(mainFile);
        try {
          await inspector.inspect(file);
          fail('accepted invalid backup');
        } on FormatException catch (e) {
          expect(e.message, isNot(contains('private-fixture-key')));
        }
        expect(await digest(file), original);
        expect(await digest(mainFile), main);
      },
    );
  }
  test('rejects corrupt, oversized and sidecar-bearing inputs', () async {
    final file = File('${directory.path}/bad.db');
    await file.writeAsString('SQLite format 3\u0000broken');
    await expectLater(inspector.inspect(file), throwsFormatException);
    await expectLater(
      BackupInspector(databaseFactoryFfi, maxBytes: 10).inspect(snapshot),
      throwsFormatException,
    );
    await File('${mainFile.path}-wal').writeAsString('in-progress');
    await expectLater(inspector.inspect(mainFile), throwsFormatException);
    expect(await File('${mainFile.path}-wal').readAsString(), 'in-progress');
  });
  testWidgets('preview works at 375/768/1440 and offers no restore action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [375.0, 768.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpWidget(
        MaterialApp(
          home: BackupPreviewScreen(
            inspector: _PreviewFixture(),
            pickPath: () async => '/synthetic/backup.json',
          ),
        ),
      );
      await tester.tap(find.text('选择备份'));
      await tester.pumpAndSettle();
      expect(find.text('结构检查通过'), findsOneWidget);
      expect(find.text('本机缺失附件：2 · 未解析关联：0'), findsOneWidget);
      expect(find.textContaining('private-fixture-key'), findsNothing);
      expect(find.text('执行恢复'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
