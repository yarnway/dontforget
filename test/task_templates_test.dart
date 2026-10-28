import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/task_template.dart';
import 'package:dont_forget/providers/task_templates_provider.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/offline_management_harness.dart';

const template = TaskTemplate(
  id: 'fixture',
  name: 'Travel',
  title: 'Pack bag',
  items: ['Passport', 'Headphones'],
  tags: ['personal'],
  project: 'Trip',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('template copies fresh unchecked content and immutable round trip', () {
    expect(TaskTemplate.decode(null), isEmpty);
    final item = TaskTemplate.decode(TaskTemplate.encode([template])).single;
    expect(item.sameAs(template), isTrue);
    expect(() => item.items.clear(), throwsUnsupportedError);
    final first = item.instantiate(), second = item.instantiate();
    expect(first.checklist.map((e) => e.label), template.items);
    expect(first.checklist.every((e) => !e.done), isTrue);
    expect(
      first.checklist
          .map((e) => e.id)
          .toSet()
          .intersection(second.checklist.map((e) => e.id).toSet()),
      isEmpty,
    );
    expect(first.history, isEmpty);
    expect(first.repeat, isNull);
    expect(first.tags, ['personal']);
  });
  test(
    'unknown, malformed, duplicate and oversized template data fails closed',
    () {
      for (final raw in [
        {'version': 2, 'items': []},
        {'version': 1.0, 'items': []},
        {
          'version': 1,
          'items': [template.toJson(), template.toJson()],
        },
        {
          'version': 1,
          'items': [
            template.toJson(),
            {...template.toJson(), 'id': 'other', 'name': 'travel'},
          ],
        },
        for (final change in <Map<String, dynamic>>[
          {'unexpected': true},
          {'id': '../file'},
          {'name': ' '},
          {
            'items': ['x\ny'],
          },
          {'items': List.filled(65, 'x')},
          {
            'tags': ['x', 'x'],
          },
          {'title': 'x' * 161},
        ])
          {
            'version': 1,
            'items': [
              {...template.toJson(), ...change},
            ],
          },
        {
          'version': 1,
          'items': [
            for (var i = 0; i < 25; i++)
              {...template.toJson(), 'id': 'id-$i', 'name': 'Name $i'},
          ],
        },
        {
          'version': 1,
          'items': [
            for (var i = 0; i < 24; i++)
              {
                ...template.toJson(),
                'id': 'id-$i',
                'name': 'Name $i',
                'items': List.filled(64, '字' * 500),
              },
          ],
        },
      ]) {
        expect(() => TaskTemplate.decode(raw), throwsFormatException);
      }
    },
  );
  group('durable template library', () {
    late OfflineManagementHarness h;
    TaskTemplateStore store() => h.container.read(taskTemplateStoreProvider);
    Future<void> save(
      String name, {
      TaskTemplate? expected,
      String title = 'Pack bag',
    }) => store().save(
      expected: expected,
      name: name,
      title: title,
      items: ['Keys', 'Umbrella'],
      tags: ['home'],
      project: 'Personal',
    );
    setUp(() async {
      h = OfflineManagementHarness();
      await h.create();
    });
    tearDown(() => h.dispose());
    test(
      'concurrent writes preserve unrelated drafts and survive reopen',
      () async {
        await Future.wait([
          save('Travel'),
          save('Work'),
          h.container.read(workspaceDraftsProvider.notifier).put('unrelated', {
            'text': 'preserve',
          }),
        ]);
        final before = await h.drafts();
        await h.close();
        await h.open();
        expect(await h.drafts(), before);
        expect((await store().load()).map((e) => e.name), ['Travel', 'Work']);
        expect(h.container.read(workspaceDraftsProvider)['unrelated'], {
          'text': 'preserve',
        });
      },
    );
    test(
      'edit and delete reject stale snapshots and duplicate names',
      () async {
        await save('First');
        await save('Second');
        final first = (await store().load()).first;
        await save('Renamed', expected: first, title: 'New title');
        await expectLater(
          store().remove(first),
          throwsA(isA<TaskTemplateException>()),
        );
        final before = await h.drafts();
        await expectLater(
          save('SECOND', expected: (await store().load()).first),
          throwsA(isA<TaskTemplateException>()),
        );
        expect(await h.drafts(), before);
        await store().remove((await store().load()).first);
        expect((await store().load()).single.name, 'Second');
        await save('Third');
        expect(await store().load(), hasLength(2));
      },
    );
    test('limit is enforced without losing saved content', () async {
      for (var i = 0; i < 24; i++) {
        await save('Template $i');
      }
      final before = await h.drafts();
      await expectLater(
        save('Overflow'),
        throwsA(
          isA<TaskTemplateException>().having(
            (e) => e.reason,
            'reason',
            TaskTemplateFailure.limitReached,
          ),
        ),
      );
      expect(await h.drafts(), before);
    });
    test(
      'SQLite failure rolls back the library and later writes recover',
      () async {
        await save('First');
        final before = await h.drafts();
        final db = await h.database.database;
        await db.execute(
          "CREATE TRIGGER fail_template BEFORE UPDATE ON Settings BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END",
        );
        await expectLater(save('Second'), throwsA(isA<DatabaseException>()));
        expect(await h.drafts(), before);
        expect((await store().load()).single.name, 'First');
        await db.execute('DROP TRIGGER fail_template');
        await save('Second');
        expect(await store().load(), hasLength(2));
      },
    );
    test('corrupt library never gets overwritten by defaults', () async {
      await h.container.read(workspaceDraftsProvider.notifier).put(
        TaskTemplate.storageKey,
        {'version': 99, 'items': []},
      );
      final before = await h.drafts();
      await expectLater(store().load(), throwsFormatException);
      await expectLater(save('New'), throwsFormatException);
      expect(await h.drafts(), before);
    });
    test(
      'old store cannot write after a recovery generation changes',
      () async {
        await save('First');
        final old = store();
        final item = (await old.load()).single;
        final before = await h.drafts();
        final lease = await h.database.beginMaintenance();
        await lease.resume();
        await expectLater(
          old.remove(item),
          throwsA(isA<DatabaseAccessException>()),
        );
        await expectLater(
          old.save(name: 'Old', title: 'Old', items: [], tags: [], project: ''),
          throwsA(isA<DatabaseAccessException>()),
        );
        expect(await h.drafts(), before);
      },
    );
    test(
      'JSON and SQLite backup previews preserve templates and reject corrupt namespace',
      () async {
        await save('First');
        await h.database.createMirrorBackup();
        for (final name in ['ha_snapshot.json', 'dont_forget_v3.mirror.db']) {
          final preview = await BackupInspector(
            databaseFactoryFfi,
          ).inspect(File('${h.directory.path}/$name'));
          expect(preview.version, 16);
        }
        final source = File('${h.directory.path}/ha_snapshot.json');
        final raw = jsonDecode(await source.readAsString());
        raw['settings'][0]['workspace_drafts_json'] = jsonEncode({
          TaskTemplate.storageKey: {'version': 2, 'items': []},
        });
        final bad = await File(
          '${h.directory.path}/bad-templates.json',
        ).writeAsString(jsonEncode(raw));
        await expectLater(
          BackupInspector(databaseFactoryFfi).inspect(bad),
          throwsA(isA<BackupInspectionException>()),
        );
        expect((await store().load()).single.name, 'First');
      },
    );
    for (final format in ['json', 'sqlite']) {
      test(
        '$format recovery restores templates and unrelated drafts exactly',
        () async {
          await save('First');
          await h.container.read(workspaceDraftsProvider.notifier).put(
            'unrelated',
            {'preserved': true},
          );
          final before = await h.drafts();
          final oldStore = store();
          await h.database.createMirrorBackup();
          final name = format == 'json'
              ? 'ha_snapshot.json'
              : 'dont_forget_v3.mirror.db';
          final source = await File(
            '${h.directory.path}/$name',
          ).copy('${h.directory.path}/source-$format');
          final inspector = BackupInspector(databaseFactoryFfi);
          final preview = await inspector.inspect(source);
          await save('Later');
          await DatabaseRecovery(
            h.database,
            inspector: inspector,
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(source, expectedDigest: preview.digest);
          expect(await h.drafts(), before);
          await expectLater(
            oldStore.load(),
            throwsA(isA<DatabaseAccessException>()),
          );
          await h.close();
          await h.open();
          expect((await store().load()).single.name, 'First');
          expect(h.container.read(workspaceDraftsProvider)['unrelated'], {
            'preserved': true,
          });
        },
      );
    }
  });
}
