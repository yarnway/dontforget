import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String dart;
  setUpAll(() {
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    final flutter = packages.singleWhere((e) => e['name'] == 'flutter') as Map;
    final sdk = Directory.fromUri(
      config.uri.resolve(flutter['rootUri'] as String),
    ).parent.parent;
    dart = '${sdk.path}/bin/cache/dart-sdk/bin/dart';
  });

  // TZ is honored by the POSIX runtime, without changing the computer's zone or clock.
  for (final scenario in <String, List<int>>{
    'America/New_York': [1380, 1500],
    'Europe/Berlin': [1380, 1500],
    'Australia/Lord_Howe': [1410, 1470],
    'Asia/Shanghai': [1440, 1440],
  }.entries) {
    test(
      'Local recurrence and persistence across DST in ${scenario.key}',
      () async {
        final child = await Process.run(
          dart,
          [
            '--packages=.dart_tool/package_config.json',
            'test/support/recurrence_timezone_worker.dart',
          ],
          environment: {'TZ': scenario.key},
        );
        expect(child.exitCode, 0, reason: '${child.stderr}');
        final report = jsonDecode(child.stdout as String) as Map;
        expect(report['zone'], scenario.key);
        final rows = report['daily'] as List;
        expect(rows.map((e) => e['delta_minutes']), scenario.value);
        for (final row in rows) {
          expect(row['next'], endsWith('T09:15:30.123456'));
          expect(row['restored_next'], row['next']);
        }
        expect(report['utc_next'], '2026-03-08T09:15:30.123456Z');
        if (scenario.key == 'America/New_York') {
          expect(report['spring_gap_next'], '2026-03-08T03:30:00.000');
          expect(report['after_gap_next'], '2026-03-09T02:30:00.000');
          expect(report['after_fold_next'], '2026-11-02T01:30:00.000');
        }
      },
      skip: Platform.isWindows ? 'POSIX TZ process override' : false,
    );
  }
}
