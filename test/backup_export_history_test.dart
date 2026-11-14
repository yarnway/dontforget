import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/backup_export_history.dart';

void main() {
  Map<String, dynamic> record(int day) => {
    'at': DateTime(2030, 1, day).toIso8601String(),
    'name': '备份-$day.dfbackup',
    'location': 'content://documents/document/local-$day',
    'encrypted': day.isEven,
    'media': day,
    'missing': 0,
    'format': 2,
  };

  test(
    'legacy last export remains readable without changing stored metadata',
    () {
      final legacy = {
        'at': '2030-01-01T10:00:00',
        'location': r'C:\backups\旧备份.dfbackup',
      };
      final before = jsonEncode(legacy);
      expect(BackupExportHistory.read(legacy).single['name'], '旧备份.dfbackup');
      expect(jsonEncode(legacy), before);
      final merged = BackupExportHistory.prepend(record(2), legacy);
      expect(BackupExportHistory.read(merged).map((e) => e['name']), [
        '备份-2.dfbackup',
        '旧备份.dfbackup',
      ]);
      expect(merged['name'], '备份-2.dfbackup');
    },
  );

  test(
    'history keeps twenty recent exports without nesting or arbitrary fields',
    () {
      Object? stored;
      for (var day = 1; day <= 35; day++) {
        stored = BackupExportHistory.prepend({
          ...record(day),
          'password': 'synthetic-not-for-history',
          'extra': {'oversized': List.filled(1000, 'unused')},
        }, stored);
      }
      final entries = BackupExportHistory.read(stored);
      expect(entries, hasLength(20));
      expect(entries.first['name'], '备份-35.dfbackup');
      expect(entries.last['name'], '备份-16.dfbackup');
      expect(jsonEncode(stored), isNot(contains('synthetic-not-for-history')));
      expect(jsonEncode(stored), isNot(contains('oversized')));
      expect(
        RegExp('previous_exports').allMatches(jsonEncode(stored)),
        hasLength(1),
      );
      expect(jsonEncode(stored).length, lessThan(10000));
    },
  );

  test(
    'duplicate metadata is ignored but a new export at the same location remains',
    () {
      final first = BackupExportHistory.prepend(record(1), null);
      final duplicate = BackupExportHistory.prepend(record(1), first);
      expect(BackupExportHistory.read(duplicate), hasLength(1));
      final newer = {...record(1), 'at': '2030-02-01T00:00:00'};
      expect(
        BackupExportHistory.read(BackupExportHistory.prepend(newer, duplicate)),
        hasLength(2),
      );
    },
  );

  test(
    'malformed imported entries are bounded and never become location references',
    () {
      final stored = {
        ...record(5),
        'history_version': 1,
        'previous_exports': [
          {'at': 'not-a-date', 'location': '/invalid'},
          {...record(1), 'location': 'bad\nlocation'},
          {...record(2), 'location': ''},
          {...record(3), 'location': 'x' * 8193},
          ...List.filled(30, record(4)),
          record(6),
        ],
      };
      expect(BackupExportHistory.read(stored).map((e) => e['name']), [
        '备份-5.dfbackup',
        '备份-4.dfbackup',
      ]);
      expect(
        BackupExportHistory.read({'at': 'bad', 'location': '/a'}),
        isEmpty,
      );
      expect(BackupExportHistory.read(null), isEmpty);
    },
  );

  test(
    'opaque locations do not appear as display names and records are immutable',
    () {
      final opaque = {...record(1)}..remove('name');
      final entries = BackupExportHistory.read(opaque);
      expect(entries.single['name'], isNull);
      expect(
        () => entries.single['location'] = '/changed',
        throwsUnsupportedError,
      );
      expect(() => entries.clear(), throwsUnsupportedError);
      expect(opaque['location'], 'content://documents/document/local-1');
    },
  );

  test('unknown future history stays readable but cannot be overwritten', () {
    final future = {...record(1), 'history_version': 2, 'previous_exports': []};
    expect(BackupExportHistory.read(future), hasLength(1));
    expect(
      () => BackupExportHistory.prepend(record(2), future),
      throwsFormatException,
    );
    expect(future['history_version'], 2);
    expect(
      () => BackupExportHistory.prepend({'at': 'bad'}, null),
      throwsFormatException,
    );
  });
}
