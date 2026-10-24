// Opt-in measurement. See docs/Notification_Status_Benchmark.md.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/notification_schedule_reader.dart';
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

Map<String, int> _counts(NotificationScheduleStatus status) => {
  'upcoming': status.upcoming,
  'submitted': status.submitted,
  'needsAttention': status.needsAttention,
  'cancellations': status.cancellations,
  'overdueUnconfirmed': status.overdueUnconfirmed,
};

// Exact pre-optimization reader: same lease, journal/epoch validation, decoder
// and accounting, but querying every Reminder column.
Future<NotificationScheduleStatus> _fullRows(DatabaseHelper helper) async {
  final generation = helper.captureGeneration();
  return helper.runOperation(generation, () async {
    final rows = await helper.read(generation, (db) => db.query('Reminders'));
    final journal = await helper.withNotificationJournal((j) => j.read());
    helper.checkGeneration(generation);
    final epoch = journal == null ? null : await helper.readNotificationEpoch();
    helper.checkGeneration(generation);
    return NotificationScheduleStatus.fromSaved(
      rows.map(Reminder.fromJson),
      journal != null && journal.epoch == epoch ? journal.entries : {},
      DateTime.now(),
    );
  });
}

void main() {
  final fixturePath = Platform.environment['DONTFORGET_STATUS_FIXTURE'];
  final reportPath = Platform.environment['DONTFORGET_STATUS_REPORT'];
  test(
    'alternating same-fixture notification status reads',
    () async {
      if (fixturePath == null || reportPath == null) {
        throw ArgumentError('Both fixture and report paths are required.');
      }
      final report = File(reportPath);
      if (await report.exists()) throw StateError('Report already exists.');
      final bytes = await File(fixturePath).readAsBytes();
      expect(sha256.convert(bytes).toString(), _fixtureDigest);
      final fixture = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(fixture['version'], 9);
      expect(fixture['reminders'], hasLength(10000));
      final schema = const LineSplitter()
          .convert(await File('test/fixtures/schema_v9.sql').readAsString())
          .where((line) => !line.trimLeft().startsWith('--'))
          .join('\n');
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'dontforget-status-cost-',
      );
      final helper = DatabaseHelper.forTesting(
        directory.path,
        databaseFactoryFfi,
        migrateNotificationJournal: true,
      );
      try {
        final seed = await databaseFactoryFfi.openDatabase(
          p.join(directory.path, 'dont_forget_v3.db'),
          options: OpenDatabaseOptions(
            version: 9,
            onCreate: (db, _) async {
              for (final statement in schema.split(';')) {
                if (statement.trim().isNotEmpty) await db.execute(statement);
              }
              final batch = db.batch();
              for (final table in _tables.entries) {
                for (final row in fixture[table.value] as List) {
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
        await seed.close();
        final db = await helper.database;
        expect(await db.getVersion(), 10);
        final before = {
          for (final table in _tables.keys) table: await db.query(table),
        };
        final reader = NotificationScheduleReader(helper);
        final samples = <Map<String, Object>>[];
        Map<String, int>? expected;
        for (var run = -2; run < 7; run++) {
          final order = run.isEven
              ? ['full_rows', 'projected_rows']
              : ['projected_rows', 'full_rows'];
          final sample = <String, Object>{'order': order};
          for (final variant in order) {
            final watch = Stopwatch()..start();
            final status = variant == 'full_rows'
                ? await _fullRows(helper)
                : await reader.read();
            watch.stop();
            expected ??= _counts(status);
            expect(_counts(status), expected);
            sample['${variant}_us'] = watch.elapsedMicroseconds;
          }
          if (run >= 0) samples.add(sample);
        }
        for (final table in _tables.keys) {
          expect(await db.query(table), before[table]);
        }
        expect(
          (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
          'ok',
        );
        // Representation size is a repeatable volume proxy, not an allocation
        // measurement or the actual SQLite FFI transport encoding.
        final projected = await db.query(
          'Reminders',
          columns: const [
            'id',
            'task_title',
            'quadrant_level',
            'trigger_time',
            'is_completed',
            'notice_revision',
            'notice_acknowledged_at',
          ],
        );
        Map<String, int> distribution(String variant) {
          final values = samples.map((s) => s['${variant}_us'] as int).toList()
            ..sort();
          return {
            'p50_us': values[3],
            'p95_us': values.last,
            'max_us': values.last,
          };
        }

        await report.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({'scope': 'Flutter test JIT; real SQLite FFI and product status reader; empty journal; no OS calls; not native UI or cold startup', 'fixture_sha256': _fixtureDigest, 'records': 10000, 'warmup_pairs': 2, 'runtime': Platform.version, 'os': Platform.operatingSystemVersion, 'counts': expected, 'all_counts_equal_and_business_rows_unchanged': true, 'full_rows_json_bytes': utf8.encode(jsonEncode(before['Reminders'])).length, 'projected_rows_json_bytes': utf8.encode(jsonEncode(projected)).length, 'samples': samples, 'full_rows': distribution('full_rows'), 'projected_rows': distribution('projected_rows')})}\n',
          flush: true,
        );
      } finally {
        await helper.close();
        await directory.delete(recursive: true);
      }
    },
    skip: fixturePath == null && reportPath == null
        ? 'Opt-in: set DONTFORGET_STATUS_FIXTURE and DONTFORGET_STATUS_REPORT.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
