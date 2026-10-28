import 'dart:convert';
import 'package:dont_forget/data/database_helper.dart';
import 'dart:io';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/content/content_cleanup_service.dart';
import 'package:dont_forget/services/content/owned_material_activity.dart';
import 'package:dont_forget/services/local_media_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  late Directory documents;
  late ContentCleanupService service;
  final now = DateTime(2032, 2, 10), old = DateTime(2032, 2, 1);
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    documents = await Directory('${h.directory.path}/Documents').create();
    service = ContentCleanupService(h.database, documents, clock: () => now);
  });
  tearDown(() async {
    OwnedMaterialActivity.activeDirectories.removeWhere(
      (p) => p.startsWith(h.directory.path),
    );
    await h.dispose();
  });
  Future<File> owned(
    String name, {
    String role = 'original',
    bool marker = true,
  }) async {
    final dir = await Directory(
      '${documents.path}/media/import-$name',
    ).create(recursive: true);
    final file = await File(
      '${dir.path}/$name.bin',
    ).writeAsString('Public synthetic $name');
    if (marker) await OwnedMaterialActivity.mark(dir, role);
    for (final f in await dir.list().toList()) {
      if (f is File) await f.setLastModified(old);
    }
    return file;
  }

  Future<void> record(
    String id,
    String path, {
    DateTime? at,
    String type = 'image',
  }) async {
    await h.database.writeTransaction(
      h.database.captureGeneration(),
      (db) => db.insert(
        'MediaRecords',
        MediaRecord(
          id: id,
          type: type,
          contentOrPath: path,
          createdAt: at ?? old,
        ).toJson(),
      ),
    );
  }

  Future<void> task(
    String id, {
    String? source,
    TaskDetails details = const TaskDetails(),
  }) async {
    await h.database.writeTransaction(
      h.database.captureGeneration(),
      (db) => db.insert(
        'Reminders',
        Reminder(
          id: id,
          recordId: source,
          taskTitle: id,
          quadrantLevel: 2,
          detailsJson: details.encode(),
        ).toJson(),
      ),
    );
  }

  Future<ContentCleanupPlan> plan(Set<String> keys) async => service.prepare(
    await service.inspect(h.database.captureGeneration()),
    keys,
    h.database.captureGeneration(),
    isCurrent: () => true,
  );
  Future<ContentCleanupResult> clean(ContentCleanupPlan p) async =>
      service.clean(p, h.database.captureGeneration(), isCurrent: () => true);
  test(
    'all task sources, attachments, medication evidence, trash, archive and drafts protect original records',
    () async {
      for (final id in [
        'source',
        'attachment',
        'evidence',
        'trash',
        'archive',
        'draft',
        'proposal',
      ]) {
        final f = await owned(id);
        await record(id, f.path);
      }
      await task(
        'normal',
        source: 'source',
        details: const TaskDetails(attachmentIds: ['attachment']),
      );
      await task(
        'med',
        details: const TaskDetails(
          kind: 'medicationPlan',
          data: {
            'sources': [
              {'record_id': 'evidence'},
            ],
          },
        ),
      );
      await task(
        'deleted',
        source: 'trash',
        details: TaskDetails(deletedAt: old),
      );
      await task(
        'archived',
        source: 'archive',
        details: TaskDetails(archivedAt: old),
      );
      await h.container.read(workspaceDraftsProvider.notifier).put(
        'medicationDraft',
        {
          'sources': [
            {'record_id': 'draft'},
          ],
        },
      );
      await h.database.writeTransaction(
        h.database.captureGeneration(),
        (db) => db.update(
          'Reminders',
          {
            'capture_proposal_json': jsonEncode({'source': 'proposal'}),
          },
          where: 'id = ?',
          whereArgs: ['normal'],
        ),
      );
      final inventory = await service.inspect(h.database.captureGeneration());
      expect(
        inventory.entries
            .where((e) => e.kind == ContentEntryKind.record)
            .every((e) => e.reason == 'referenced'),
        isTrue,
      );
      await expectLater(
        service.prepare(
          inventory,
          {'record:trash'},
          h.database.captureGeneration(),
          isCurrent: () => true,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'only confirmed unreferenced rows and exclusively owned files are removed; external files stay',
    () async {
      final file = await owned('unused');
      await record('unused', file.path);
      final external = await File(
        '${h.directory.path}/external.jpg',
      ).writeAsString('keep external');
      await record('external', external.path);
      final retained = await owned('retained');
      await record('retained', retained.path);
      await task('keep', source: 'retained');
      final result = await clean(
        await plan({'record:unused', 'record:external'}),
      );
      expect(result.records, 2);
      expect(result.pending, isFalse);
      expect(await file.exists(), isFalse);
      expect(await external.readAsString(), 'keep external');
      expect(await retained.exists(), isTrue);
      expect(
        (await h.database.database).query(
          'MediaRecords',
          where: 'id = ?',
          whereArgs: ['unused'],
        ),
        completion(isEmpty),
      );
    },
  );
  test(
    'standalone text can be removed when media directory has never existed',
    () async {
      await record('text', 'Keep this until explicit selection', type: 'text');
      final prepared = await plan({'record:text'});
      expect(prepared.bytes, 0);
      expect((await clean(prepared)).records, 1);
    },
  );
  test(
    'shared files are preserved until all independent record owners are gone',
    () async {
      final file = await owned('shared');
      await record('a', file.path);
      await record('b', file.path);
      expect((await plan({'record:a'})).bytes, 0);
      await clean(await plan({'record:a'}));
      expect(await file.exists(), isTrue);
      await clean(await plan({'record:b'}));
      expect(await file.exists(), isFalse);
    },
  );
  test('recent, active and unrecognized directories are protected', () async {
    final recent = await owned('recent');
    await record('recent', recent.path, at: now);
    final active = await owned('active');
    OwnedMaterialActivity.hold(active.parent);
    final unknown = await owned('unknown', marker: false);
    final inventory = await service.inspect(h.database.captureGeneration());
    expect(
      inventory.entries.singleWhere((e) => e.key == 'record:recent').reason,
      'recent',
    );
    expect(
      inventory.entries.singleWhere((e) => e.label == 'import-active').reason,
      'active',
    );
    expect(
      inventory.entries.singleWhere((e) => e.label == 'import-unknown').reason,
      'unknown',
    );
    expect(await unknown.exists(), isTrue);
  });
  test(
    'unreferenced restore material is removable, while one live media path protects its complete directory',
    () async {
      final orphan = await owned('orphan', role: 'restore'),
          live = await owned('live', role: 'restore');
      await record('live', live.path);
      final inventory = await service.inspect(h.database.captureGeneration());
      expect(
        inventory.entries.singleWhere((e) => e.label == 'import-live').reason,
        'referenced',
      );
      final prepared = await plan({'directory:import-orphan'});
      await clean(prepared);
      expect(await orphan.parent.exists(), isFalse);
      expect(await live.exists(), isTrue);
    },
  );
  test(
    'legacy restore layout is recognized only when its snapshot matches all attachment paths',
    () async {
      final dir = await Directory(
        '${documents.path}/media/import-legacy',
      ).create(recursive: true);
      final attachment = await File(
        '${dir.path}/attachment-0.png',
      ).writeAsString('legacy');
      await File('${dir.path}/snapshot.json').writeAsString(
        jsonEncode({
          'version': 16,
          'settings': [],
          'reminders': [],
          'media_records': [
            {'type': 'image', 'content_or_path': attachment.path},
          ],
        }),
      );
      for (final f in await dir.list().toList()) {
        await (f as File).setLastModified(old);
      }
      expect(
        (await service.inspect(
          h.database.captureGeneration(),
        )).entries.single.kind,
        ContentEntryKind.restore,
      );
      await clean(await plan({'directory:import-legacy'}));
      expect(await dir.exists(), isFalse);
    },
  );
  test(
    'new references after preview reject the whole cleanup without deleting any records or files',
    () async {
      final a = await owned('a'), b = await owned('b');
      await record('a', a.path);
      await record('b', b.path);
      final prepared = await plan({'record:a', 'record:b'});
      await task('later', source: 'b');
      await expectLater(clean(prepared), throwsStateError);
      expect(await a.exists(), isTrue);
      expect(await b.exists(), isTrue);
      expect(
        await (await h.database.database).query('MediaRecords'),
        hasLength(2),
      );
    },
  );
  test(
    'equal-size file changes after preview are rejected even when mtime is restored',
    () async {
      final file = await owned('changed');
      await record('changed', file.path);
      final prepared = await plan({'record:changed'});
      final size = await file.length();
      await file.writeAsString('x' * size);
      await file.setLastModified(old);
      await expectLater(clean(prepared), throwsStateError);
      expect(await file.length(), size);
    },
  );
  test('SQL failure restores staged files and retains original rows', () async {
    final file = await owned('rollback');
    await record('rollback', file.path);
    final prepared = await plan({'record:rollback'});
    await (await h.database.database).execute(
      "CREATE TRIGGER fail_cleanup BEFORE DELETE ON MediaRecords BEGIN SELECT RAISE(ABORT, 'synthetic rollback'); END",
    );
    await expectLater(clean(prepared), throwsA(anything));
    expect(await file.readAsString(), 'Public synthetic rollback');
    expect(
      await (await h.database.database).query('MediaRecords'),
      hasLength(1),
    );
    expect(
      (await service.inspect(h.database.captureGeneration())).pendingJobs,
      isEmpty,
    );
  });
  test(
    'purge failure leaves durable work that a fresh service can finish',
    () async {
      final file = await owned('pending');
      await record('pending', file.path);
      final prepared = await plan({'record:pending'});
      final failing = ContentCleanupService(
        h.database,
        documents,
        clock: () => now,
        beforePurge: () async => throw StateError('Synthetic interruption'),
      );
      expect(
        (await failing.clean(
          prepared,
          h.database.captureGeneration(),
          isCurrent: () => true,
        )).pending,
        isTrue,
      );
      await h.close();
      await h.open();
      final reopened = ContentCleanupService(
        h.database,
        documents,
        clock: () => now,
      );
      final inventory = await reopened.inspect(h.database.captureGeneration());
      expect(inventory.pendingJobs, hasLength(1));
      await reopened.repair(
        inventory.pendingJobs.single,
        h.database.captureGeneration(),
        isCurrent: () => true,
      );
      expect(await file.exists(), isFalse);
      expect(
        (await reopened.inspect(h.database.captureGeneration())).pendingJobs,
        isEmpty,
      );
    },
  );
  test(
    'a reference created before retry restores the staged file rather than purging it',
    () async {
      final file = await owned('saved');
      await record('saved', file.path);
      final prepared = await plan({'record:saved'});
      final failing = ContentCleanupService(
        h.database,
        documents,
        clock: () => now,
        beforePurge: () async => throw StateError('Synthetic interruption'),
      );
      await failing.clean(
        prepared,
        h.database.captureGeneration(),
        isCurrent: () => true,
      );
      await record('new-owner', file.path);
      final job = (await service.inspect(
        h.database.captureGeneration(),
      )).pendingJobs.single;
      await service.repair(
        job,
        h.database.captureGeneration(),
        isCurrent: () => true,
      );
      expect(await file.readAsString(), 'Public synthetic saved');
      expect(
        await (await h.database.database).query('MediaRecords'),
        hasLength(1),
      );
    },
  );
  test(
    'uncommitted interrupted staging is restored without trusting SQL to invent deletions',
    () async {
      final file = await owned('staging');
      await record('staging', file.path);
      const job = '.cleanup-11111111-1111-4111-8111-111111111111';
      final quarantine = await Directory(
        '${documents.path}/media/$job',
      ).create();
      await file.rename('${quarantine.path}/file-0');
      await File('${quarantine.path}/cleanup.json').writeAsString(
        jsonEncode({
          'format': 'dontforget.cleanup',
          'version': 1,
          'job': job,
          'moves': [
            {'from': 'import-staging/staging.bin', 'to': 'file-0'},
          ],
        }),
      );
      await service.repair(
        job,
        h.database.captureGeneration(),
        isCurrent: () => true,
      );
      expect(await file.exists(), isTrue);
    },
  );
  test(
    'symlinks, traversal journals, automatic backups and external exports cannot be removed',
    () async {
      final external = await File(
        '${h.directory.path}/protected',
      ).writeAsString('keep');
      await Directory('${documents.path}/media').create();
      await Link(
        '${documents.path}/media/import-link',
      ).create(h.directory.path);
      final backup = await File(
        '${documents.path}/media/automatic-backup.db',
      ).writeAsString('keep backup');
      const job = '.cleanup-22222222-2222-4222-8222-222222222222';
      final dir = await Directory('${documents.path}/media/$job').create();
      await File('${dir.path}/cleanup.json').writeAsString(
        jsonEncode({
          'format': 'dontforget.cleanup',
          'version': 1,
          'job': job,
          'moves': [
            {'from': '../../protected', 'to': 'file-0'},
          ],
        }),
      );
      await expectLater(
        service.repair(
          job,
          h.database.captureGeneration(),
          isCurrent: () => true,
        ),
        throwsFormatException,
      );
      expect(await external.readAsString(), 'keep');
      expect(await backup.exists(), isTrue);
    },
  );
  test('expired runtime sessions cannot prepare or execute cleanup', () async {
    final file = await owned('old');
    await record('old', file.path);
    final prepared = await plan({'record:old'});
    await expectLater(
      service.clean(
        prepared,
        h.database.captureGeneration(),
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    expect(await file.exists(), isTrue);
  });
  test(
    'retained JSON and SQLite mirrors protect their attachment bytes after unused rows are removed',
    () async {
      final file = await owned('historical');
      await record('historical', file.path);
      await h.database.createMirrorBackup();
      final prepared = await plan({'record:historical'});
      expect(prepared.bytes, 0);
      await clean(prepared);
      expect(await file.exists(), isTrue);
      final inventory = await service.inspect(h.database.captureGeneration());
      expect(
        inventory.entries
            .singleWhere((e) => e.label == 'import-historical')
            .reason,
        'backupProtected',
      );
      await h.database.createMirrorBackup();
      await clean(await plan({'directory:import-historical'}));
      expect(await file.exists(), isFalse);
    },
  );
  test(
    'schema rollback references and unreadable retained backups fail closed for physical cleanup',
    () async {
      final file = await owned('rollback-file');
      await record('rollback-file', file.path);
      final rollback = await Directory(
        '${h.directory.path}/schema-upgrade-fixture',
      ).create();
      await File('${rollback.path}/snapshot.json').writeAsString(
        jsonEncode({
          'media_records': [
            {'type': 'image', 'content_or_path': file.path},
          ],
        }),
      );
      expect((await plan({'record:rollback-file'})).bytes, 0);
      await rollback.delete(recursive: true);
      await File(
        '${h.directory.path}/ha_snapshot.json',
      ).writeAsString('corrupt retained data');
      expect((await plan({'record:rollback-file'})).bytes, 0);
      await clean(await plan({'record:rollback-file'}));
      expect(await file.exists(), isTrue);
    },
  );
  test(
    'local imports preserve a source named like the ownership marker',
    () async {
      final original = await File(
        '${h.directory.path}/${OwnedMaterialActivity.markerName}',
      ).writeAsString('user content');
      final copied = await LocalMediaStore(
        documentsDirectory: () async => documents,
      ).importFile(original.path);
      expect(await File(copied).readAsString(), 'user content');
      expect(await original.readAsString(), 'user content');
    },
  );
  test(
    'old cleanup plans cannot cross an actual maintenance generation',
    () async {
      final file = await owned('generation');
      await record('generation', file.path);
      final generation = h.database.captureGeneration();
      final prepared = await plan({'record:generation'});
      final lease = await h.database.beginMaintenance();
      await lease.resume();
      await expectLater(
        Future.sync(
          () => service.clean(prepared, generation, isCurrent: () => true),
        ),
        throwsA(isA<DatabaseAccessException>()),
      );
      expect(await file.exists(), isTrue);
    },
  );
  test(
    'an unmarked legacy original record can be removed without claiming ownership of its file',
    () async {
      final file = await owned('unmarked', marker: false);
      await record('unmarked', file.path);
      final prepared = await plan({'record:unmarked'});
      expect(prepared.bytes, 0);
      await clean(prepared);
      expect(await file.exists(), isTrue);
      expect(
        (await service.inspect(
          h.database.captureGeneration(),
        )).entries.single.reason,
        'unknown',
      );
    },
  );
}
