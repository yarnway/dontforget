// Opt-in measurement. See docs/Schema_Upgrade_Benchmark.md for invocation.
// All database access below is confined to this entrypoint's temporary directory.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _fixtureDigest =
    'ffe48931fba0f93c79c3f0c60daaa0dc0e3dcfa26f1210d82c7ccd531203e669';
const _tables = {
  'Settings': 'settings',
  'MediaRecords': 'media_records',
  'Reminders': 'reminders',
};

void main() {
  final fixturePath = Platform.environment['DONTFORGET_UPGRADE_FIXTURE'];
  final reportPath = Platform.environment['DONTFORGET_UPGRADE_REPORT'];
  test(
    'same-fixture schema 9 upgrade and verified rollback snapshot',
    () async {
      if (fixturePath == null || reportPath == null) {
        throw ArgumentError('Both fixture and report paths are required.');
      }
      final samples = int.parse(
        Platform.environment['DONTFORGET_UPGRADE_SAMPLES'] ?? '5',
      );
      if (samples < 3 || samples > 10) {
        throw ArgumentError('Samples must be in 3..10.');
      }
      final report = File(reportPath);
      if (await report.exists()) throw StateError('Report already exists.');
      final bytes = await File(fixturePath).readAsBytes();
      expect(sha256.convert(bytes).toString(), _fixtureDigest);
      final fixture = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(fixture['version'], 9);
      expect(fixture['reminders'], hasLength(10000));
      final expected = {
        for (final entry in _tables.entries)
          entry.key: (fixture[entry.value] as List)
              .map((row) => Map<String, Object?>.from(row as Map))
              .toList(),
      };
      // This frozen fixture has whole-line comments containing semicolons.
      // Remove those comments before splitting its simple CREATE statements.
      final schema = const LineSplitter()
          .convert(await File('test/fixtures/schema_v9.sql').readAsString())
          .where((line) => !line.trimLeft().startsWith('--'))
          .join('\n');
      sqfliteFfiInit();
      final root = await Directory.systemTemp.createTemp(
        'dontforget-upgrade-cost-',
      );
      final measured = <Map<String, Object>>[];

      Future<void> seed(Directory dir, Map<String, dynamic> source) async {
        await dir.create();
        final db = await databaseFactoryFfi.openDatabase(
          p.join(dir.path, 'dont_forget_v3.db'),
          options: OpenDatabaseOptions(
            version: 9,
            onCreate: (db, _) async {
              for (final statement in schema.split(';')) {
                if (statement.trim().isNotEmpty) await db.execute(statement);
              }
              final batch = db.batch();
              for (final table in _tables.entries) {
                for (final row in source[table.value] as List) {
                  batch.insert(
                    table.key,
                    Map<String, Object?>.from(row as Map),
                  );
                }
              }
              await batch.commit(noResult: true);
            },
          ),
        );
        await db.close();
      }

      Future<Map<String, List<Map<String, Object?>>>> rows(Database db) async =>
          {for (final table in _tables.keys) table: await db.query(table)};

      try {
        for (var run = -2; run < samples; run++) {
          final directory = Directory(p.join(root.path, 'sample-$run'));
          await seed(directory, fixture);
          final helper = DatabaseHelper.forTesting(
            directory.path,
            databaseFactoryFfi,
            migrateNotificationJournal: true,
          );
          try {
            final beforeRss = ProcessInfo.currentRss;
            final watch = Stopwatch()..start();
            final db = await helper.database;
            watch.stop();
            final upgradeUs = watch.elapsedMicroseconds;
            final afterRss = ProcessInfo.currentRss;
            expect(await db.getVersion(), 10);
            expect(
              (await db.rawQuery(
                'PRAGMA integrity_check',
              )).single.values.single,
              'ok',
            );
            final upgraded = await rows(db);
            for (final table in expected.keys) {
              expect(upgraded[table], [
                for (final row in expected[table]!)
                  {
                    ...row,
                    if (table == 'Settings') ...{
                      'ai_profiles_json': AppSettings.fromJson(
                        row,
                      ).toJson()['ai_profiles_json'],
                      'ai_fallback_enabled': 0,
                    },
                  },
              ]);
            }
            final snapshotDirectory = directory
                .listSync()
                .whereType<Directory>()
                .singleWhere(
                  (d) => p
                      .basename(d.path)
                      .startsWith('schema-upgrade-v9-to-v10-'),
                );
            final snapshotBytes = await File(
              p.join(snapshotDirectory.path, 'snapshot.json'),
            ).readAsBytes();
            final snapshot =
                jsonDecode(utf8.decode(snapshotBytes)) as Map<String, dynamic>;
            final manifest =
                jsonDecode(
                      await File(
                        p.join(snapshotDirectory.path, 'manifest.json'),
                      ).readAsString(),
                    )
                    as Map;
            expect(
              manifest['snapshotSha256'],
              sha256.convert(snapshotBytes).toString(),
            );
            for (final table in _tables.entries) {
              expect(snapshot[table.value], expected[table.key]);
            }
            await helper.close();
            watch.reset();
            watch.start();
            final reopened = await helper.database;
            watch.stop();
            final reopenUs = watch.elapsedMicroseconds;
            expect(await rows(reopened), upgraded);
            await helper.close();

            // Rebuild the old schema from the actual emitted snapshot, never
            // open a v10 database with an older application.
            final rollback = Directory(p.join(root.path, 'rollback-$run'));
            await seed(rollback, snapshot);
            final old = await databaseFactoryFfi.openDatabase(
              p.join(rollback.path, 'dont_forget_v3.db'),
            );
            try {
              expect(await old.getVersion(), 9);
              expect(await rows(old), expected);
              expect(
                (await old.rawQuery(
                  'PRAGMA integrity_check',
                )).single.values.single,
                'ok',
              );
            } finally {
              await old.close();
            }
            if (run >= 0) {
              measured.add({
                'upgrade_with_snapshot_us': upgradeUs,
                'already_upgraded_reopen_us': reopenUs,
                'snapshot_bytes': snapshotBytes.length,
                'rss_before_bytes': beforeRss,
                'rss_after_open_bytes': afterRss,
                'all_rows_snapshot_and_v9_rollback_exact': true,
              });
            }
          } finally {
            await helper.close();
          }
        }
        Map<String, int> distribution(String key) {
          final values = measured.map((r) => r[key] as int).toList()..sort();
          return {
            'p50_us': values[(values.length * .5).ceil() - 1],
            'p95_us': values[(values.length * .95).ceil() - 1],
            'max_us': values.last,
          };
        }

        await report.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({'scope': 'Flutter test JIT, real product DatabaseHelper with SQLite FFI and filesystem; not native UI startup or standalone snapshot time', 'fixture_sha256': _fixtureDigest, 'records': 10000, 'warmups': 2, 'runtime': Platform.version, 'os': Platform.operatingSystemVersion, 'samples': measured, 'upgrade_with_snapshot': distribution('upgrade_with_snapshot_us'), 'already_upgraded_reopen': distribution('already_upgraded_reopen_us')})}\n',
          flush: true,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: fixturePath == null && reportPath == null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
