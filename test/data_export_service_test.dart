import 'dart:io';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/data_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Independent CSV reader for escaped quote/newline round trips.
List<List<String>> readCsv(String value) {
  final rows = <List<String>>[];
  var row = <String>[];
  var cell = StringBuffer();
  var quoted = false;
  for (var i = 1; i < value.length; i++) {
    final char = value[i];
    if (char == '"') {
      if (quoted && i + 1 < value.length && value[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (!quoted && char == ',') {
      row.add(cell.toString());
      cell = StringBuffer();
    } else if (!quoted && char == '\r' && value[i + 1] == '\n') {
      row.add(cell.toString());
      rows.add(row);
      row = [];
      cell = StringBuffer();
      i++;
    } else {
      cell.write(char);
    }
  }
  expect(quoted, isFalse);
  expect(row, isEmpty);
  return rows;
}

void main() {
  const service = DataExportService();
  final now = DateTime(2026, 10, 26, 12);
  Reminder task(String title) => Reminder(
    id: 'csv-1',
    taskTitle: title,
    taskSummary: 'line one\r\n"quoted",two',
    quadrantLevel: 2,
    triggerTime: now.subtract(const Duration(days: 1)),
    createdAt: now.subtract(const Duration(days: 3)),
    urgencyLevel: 'General',
  );
  for (final locale in ['en', 'zh', 'ja']) {
    test('CSV $locale round trips text, 16 columns and localized status', () {
      final data = service.generateCsvContent(
        [
          task('Unicode 日本語 中文 😀'),
          task('done').copyWith(isCompleted: true, triggerTime: null),
        ],
        locale: locale,
        now: now,
      );
      expect(data.startsWith('\uFEFF'), isTrue);
      final rows = readCsv(data);
      expect(rows.length, 3);
      expect(rows.every((r) => r.length == 16), isTrue);
      expect(rows[1][1], 'Unicode 日本語 中文 😀');
      expect(rows[1][2], 'line one\r\n"quoted",two');
      expect(
        rows[1][10],
        locale == 'zh'
            ? '常规'
            : locale == 'ja'
            ? '通常'
            : 'General',
      );
      expect(rows[2][6], isEmpty);
      expect(
        rows[0][10],
        locale == 'en'
            ? 'Urgency'
            : locale == 'ja'
            ? '緊急度'
            : '紧急程度 (Urgency)',
      );
      expect(
        rows[1][5],
        locale == 'en'
            ? 'Reminder time passed'
            : locale == 'ja'
            ? '通知時刻を経過'
            : '提醒时间已过',
      );
      final mask = int.parse(rows[1][15].substring(2), radix: 16);
      expect(mask & TaskBitmask.overdue, isNonZero);
      expect(mask & TaskBitmask.stagnant, isNonZero);
    });
  }
  test('formula-like text is inert; ordinary quote escaping stays exact', () {
    for (final text in [
      '=1+1',
      ' +SUM(1,2)',
      '-1+2',
      '@SUM(1,2)',
      '\ttext',
      '\r=1',
      '\n=1',
    ]) {
      final rows = readCsv(service.generateCsvContent([task(text)], now: now));
      expect(rows[1][1], "'$text");
    }
    expect(
      readCsv(
        service.generateCsvContent([task('plain - text')], now: now),
      )[1][1],
      'plain - text',
    );
  });
  test('file export never overwrites and rejects path traversal', () async {
    final dir = await Directory.systemTemp.createTemp('export-csv-');
    addTearDown(() => dir.delete(recursive: true));
    final first = await service.exportToFile(
      [task('first')],
      customDirectory: dir.path,
      filename: 'same.csv',
    );
    final original = await first.readAsBytes();
    await expectLater(
      service.exportToFile(
        [task('second')],
        customDirectory: dir.path,
        filename: 'same.csv',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await first.readAsBytes(), original);
    await expectLater(
      service.exportToFile(
        [],
        customDirectory: dir.path,
        filename: '../escape.csv',
      ),
      throwsArgumentError,
    );
  });
  test(
    'background encoding respects recovery before opening native save dialog',
    () async {
      final result = await service.saveWithDialog(
        List.generate(1000, (i) => task('Worker $i')),
        locale: 'en',
        title: 'Synthetic',
        isCurrent: () => false,
      );
      expect(result, isNull);
    },
  );
  test('ten thousand rows preserve row count and ordering', () {
    final rows = readCsv(
      service.generateCsvContent(
        List.generate(10000, (i) => task('Task $i')),
        locale: 'en',
        now: now,
      ),
    );
    expect(rows.length, 10001);
    expect(rows.last[1], 'Task 9999');
  });
}
