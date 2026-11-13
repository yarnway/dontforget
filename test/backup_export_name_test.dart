import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/backup_export_name.dart';
import 'package:dont_forget/services/backup_file_exporter.dart';

void main() {
  test('automatic names use readable local time, including milliseconds', () {
    expect(
      BackupExportName.resolve('', at: DateTime(2030, 1, 2, 3, 4, 5, 6)),
      'dontforget-2030-01-02-030405006.dfbackup',
    );
    expect(
      BackupExportName.resolve('  ', at: DateTime(2030, 1, 2, 3, 4, 5, 7)),
      'dontforget-2030-01-02-030405007.dfbackup',
    );
  });
  test(
    'custom Unicode names and pasted extensions are preserved without doubling',
    () {
      for (final name in ['会议资料', 'Project A (1)', 'v1.8.9', '学習ノート', '笔记📚']) {
        expect(BackupExportName.resolve(' $name '), '$name.dfbackup');
        expect(BackupExportName.resolve('$name.DFBACKUP'), '$name.dfbackup');
      }
    },
  );
  test(
    'paths, control characters, reserved device names and ambiguous names fail',
    () {
      for (final name in [
        '../copy',
        r'C:\backup',
        '/tmp/backup',
        r'\\server\share',
        '.',
        '..',
        '.dfbackup',
        '.hidden',
        'name.',
        'foo\nbar',
        'foo\u0000bar',
        'foo\u0085bar',
        'foo\u2028bar',
        'foo\u2029bar',
        'a:b',
        'a*b',
        'a?b',
        'a"b',
        'a<b',
        'a>b',
        'a|b',
        'CON',
        'con.txt',
        'CON .notes',
        'PrN',
        'AUX',
        'NUL',
        'COM1',
        'COM9.txt',
        'LPT1',
        'COM¹',
        'COM².txt',
        'LPT³',
        'name.dfbackup.dfbackup',
        'name .dfbackup',
      ]) {
        expect(
          () => BackupExportName.resolve(name),
          throwsFormatException,
          reason: name,
        );
      }
      for (final name in ['CONTEXT', 'COM10', 'LPT10', 'my.CON']) {
        expect(BackupExportName.resolve(name), '$name.dfbackup');
      }
    },
  );
  test(
    'limits reserve enough bytes for directory-export UUID and extension',
    () {
      expect(BackupExportName.resolve('a' * 80), '${'a' * 80}.dfbackup');
      expect(() => BackupExportName.resolve('a' * 81), throwsFormatException);
      expect(
        utf8.encode(BackupExportName.resolve('词' * 66)).length + 37,
        lessThanOrEqualTo(255),
      );
      expect(() => BackupExportName.resolve('词' * 67), throwsFormatException);
    },
  );
  test('legacy local paths have names, opaque document providers do not', () {
    expect(
      BackupExportName.fromLocation('/tmp/notes.dfbackup'),
      'notes.dfbackup',
    );
    expect(
      BackupExportName.fromLocation(r'C:\old\notes.dfbackup'),
      'notes.dfbackup',
    );
    expect(
      BackupExportName.fromLocation(r'\\server\share\notes.dfbackup'),
      'notes.dfbackup',
    );
    expect(
      BackupExportName.fromLocation('file:///tmp/hello%20world.dfbackup'),
      'hello world.dfbackup',
    );
    expect(
      BackupExportName.fromLocation(
        'content://documents/document/primary%3ADownload%2Fnotes.dfbackup',
      ),
      isNull,
    );
    expect(
      BackupExportName.fromLocation('https://example.test/notes.dfbackup'),
      isNull,
    );
    expect(
      BackupExportName.fromLocation('file:///tmp/my%2Fnotes.dfbackup'),
      isNull,
    );
    expect(BackupExportName.display('bad/name'), isNull);
    expect(BackupExportName.display(123), isNull);
    expect(BackupExportName.display(' '), isNull);
  });
  test(
    'invalid names never open a picker and valid directory exports stay unique',
    () async {
      final root = await Directory.systemTemp.createTemp('backup-name-');
      try {
        final source = await File(
          '${root.path}/source',
        ).writeAsString('original synthetic bytes');
        var picks = 0;
        final exporter = BackupFileExporter(
          useDirectoryPicker: true,
          pickDirectory: () async {
            picks++;
            return root.path;
          },
        );
        await expectLater(
          exporter.save(source, '../bad'),
          throwsFormatException,
        );
        expect(picks, 0);
        final first = await exporter.save(source, '学习笔记');
        final second = await exporter.save(source, '学习笔记.dfbackup');
        expect(first, isNot(second));
        expect(picks, 2);
        expect(await File(first!).readAsString(), 'original synthetic bytes');
        expect(await File(second!).readAsString(), 'original synthetic bytes');
        expect(await source.readAsString(), 'original synthetic bytes');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
