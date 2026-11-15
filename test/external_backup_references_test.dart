import 'dart:convert';
import 'package:dont_forget/services/content/external_backup_references.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

BackupPreview preview(int id, {Set<String> paths = const {'/old/file.png'}}) =>
    BackupPreview(
      version: 17,
      digest: id.toRadixString(16).padLeft(64, '0'),
      counts: const {},
      containsCredentials: true,
      missingMedia: paths.length,
      unresolvedReferences: 0,
      referencedMediaPaths: paths,
    );

void main() {
  final at = DateTime.utc(2026, 11, 15);
  test(
    'registration snapshots only bounded references and preserves original names',
    () {
      final paths = <String>{'/old/image.png', '/old/voice.m4a'};
      final raw = ExternalBackupReferences.add(
        null,
        preview(1, paths: paths),
        '旧备份.json',
        at: at,
      );
      paths.clear();
      final entry = ExternalBackupReferences.read(raw).single;
      expect(entry['name'], '旧备份.json');
      expect(entry['paths'], ['/old/image.png', '/old/voice.m4a']);
      expect(entry.keys.toSet(), {'digest', 'name', 'at', 'paths'});
      expect(jsonEncode(raw), isNot(contains('credentials')));
      expect(() => (entry['paths'] as List).clear(), throwsUnsupportedError);
      expect(() => entry['name'] = 'changed', throwsUnsupportedError);
    },
  );
  test(
    'same bytes register once and explicit removal preserves other protections',
    () {
      final first = ExternalBackupReferences.add(
        null,
        preview(1),
        'one.db',
        at: at,
      );
      final repeated = ExternalBackupReferences.add(
        first,
        preview(1),
        'renamed.db',
        at: at,
      );
      expect(repeated, first);
      final second = ExternalBackupReferences.add(
        repeated,
        preview(2),
        'two.db',
        at: at,
      );
      final removed = ExternalBackupReferences.remove(
        second,
        preview(1).digest,
      );
      expect(ExternalBackupReferences.read(removed).single['name'], 'two.db');
      expect(
        ExternalBackupReferences.remove(removed, preview(2).digest),
        isNull,
      );
      expect(
        () => ExternalBackupReferences.remove(removed, preview(1).digest),
        throwsStateError,
      );
    },
  );
  test('capacity never evicts a previous protection', () {
    Object? raw;
    for (var i = 0; i < 20; i++) {
      raw = ExternalBackupReferences.add(raw, preview(i), '$i.db', at: at);
    }
    final before = jsonEncode(raw);
    expect(
      () =>
          ExternalBackupReferences.add(raw, preview(20), 'overflow.db', at: at),
      throwsFormatException,
    );
    expect(jsonEncode(raw), before);
    expect(ExternalBackupReferences.read(raw), hasLength(20));
    expect(
      ExternalBackupReferences.add(raw, preview(0), 'duplicate.db', at: at),
      raw,
    );
  });
  test(
    'corruption, future versions, duplicate identities and excessive paths fail closed',
    () {
      final valid = ExternalBackupReferences.add(
        null,
        preview(1),
        'safe.db',
        at: at,
      );
      for (final raw in [
        {'version': 2, 'entries': []},
        {
          'version': 1,
          'entries': [valid['entries'], {}],
        },
        {
          'version': 1,
          'entries': [...valid['entries'] as List, ...valid['entries'] as List],
        },
        {
          'version': 1,
          'entries': [
            {
              ...ExternalBackupReferences.read(valid).single,
              'paths': ['x', 'x'],
            },
          ],
        },
        {
          'version': 1,
          'entries': [
            {
              ...ExternalBackupReferences.read(valid).single,
              'paths': ['\u0000'],
            },
          ],
        },
      ]) {
        expect(() => ExternalBackupReferences.read(raw), throwsFormatException);
        expect(
          () => ExternalBackupReferences.remove(raw, preview(1).digest),
          throwsFormatException,
        );
      }
      expect(
        () => ExternalBackupReferences.add(
          null,
          preview(1, paths: {for (var i = 0; i < 4001; i++) '/$i'}),
          'large.db',
          at: at,
        ),
        throwsFormatException,
      );
      expect(
        () => ExternalBackupReferences.add(
          null,
          preview(1, paths: {for (var i = 0; i < 100; i++) '/$i${'a' * 3000}'}),
          'large.db',
          at: at,
        ),
        throwsFormatException,
      );
    },
  );
}
