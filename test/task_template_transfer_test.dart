import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/models/task_template.dart';
import 'package:dont_forget/models/task_template_transfer.dart';
import 'package:dont_forget/providers/task_templates_provider.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/backup_file_exporter.dart';
import 'package:dont_forget/services/task_template_file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';

const sample = TaskTemplate(
  id: 'remote',
  name: 'Travel',
  title: 'Pack',
  items: ['Passport'],
  tags: ['personal'],
  project: 'Trip',
);

class TemplateExporter extends BackupFileExporter {
  TemplateExporter(this.destination, {this.fail = false});
  final File destination;
  final bool fail;
  @override
  Future<String?> saveWithExtension(
    File source,
    String filename, {
    required String extension,
  }) async {
    expect(extension, 'json');
    if (fail) throw StateError('Synthetic export failure');
    await source.copy(destination.path);
    return destination.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  late TaskTemplateStore store;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    store = h.container.read(taskTemplateStoreProvider);
  });
  tearDown(() async => h.dispose());
  test(
    'portable format round-trips only reusable content with strict bounds',
    () {
      final encoded = TaskTemplateTransfer.encode([sample]);
      expect(
        TaskTemplateTransfer.decode(encoded).single.sameAs(sample),
        isTrue,
      );
      for (final bad in [
        encoded.replaceFirst('"version":1', '"version":2'),
        encoded.replaceFirst('"version":1', '"version":1.0'),
        encoded.replaceFirst('"items":', '"api_key":"secret","items":'),
        encoded.replaceFirst(
          '"name":"Travel"',
          '"name":"Travel","name":"Other"',
        ),
        'x' * (TaskTemplateTransfer.maxBytes + 1),
      ]) {
        expect(() => TaskTemplateTransfer.decode(bad), throwsFormatException);
      }
    },
  );
  test(
    'skip, copy with unique name and replace-by-name are explicit and preserve the local identity on replacement',
    () {
      final existing = TaskTemplate.fromJson({
        ...sample.toJson(),
        'id': 'local',
      });
      expect(
        TaskTemplateTransfer.merge(
          [existing],
          [const TemplateImportChoice(sample, TemplateImportAction.skip)],
        ).single.id,
        'local',
      );
      final copies = TaskTemplateTransfer.merge(
        [existing],
        [const TemplateImportChoice(sample, TemplateImportAction.copy)],
      );
      expect(copies.last.name, 'Travel (2)');
      expect(copies.last.id, isNot(anyOf('local', 'remote')));
      final replaced = TaskTemplateTransfer.merge(
        [existing],
        [
          TemplateImportChoice(
            TaskTemplate.fromJson({...sample.toJson(), 'title': 'New'}),
            TemplateImportAction.replace,
          ),
        ],
      );
      expect(replaced.single.id, 'local');
      expect(replaced.single.title, 'New');
    },
  );
  test(
    'remote ID collisions never replace a differently named local template',
    () {
      final other = TaskTemplate.fromJson({
        ...sample.toJson(),
        'name': 'Different',
      });
      final result = TaskTemplateTransfer.merge(
        [other],
        [const TemplateImportChoice(sample, TemplateImportAction.copy)],
      );
      expect(result.first.sameAs(other), isTrue);
      expect(result.last.id, isNot(other.id));
    },
  );
  test(
    'imports save together, survive reopen and do not overwrite unrelated drafts',
    () async {
      await h.container.read(workspaceDraftsProvider.notifier).put('input', {
        'text': 'keep',
      });
      await store.importTemplates([], [
        const TemplateImportChoice(sample, TemplateImportAction.copy),
      ]);
      final saved = await store.load();
      expect(saved.single.name, 'Travel');
      expect(jsonDecode((await h.drafts())!)['input']['text'], 'keep');
      await h.close();
      await h.open();
      expect(
        (await h.container.read(taskTemplateStoreProvider).load()).single.id,
        saved.single.id,
      );
    },
  );
  test(
    'library changes while preview is open reject the import without overwriting new entries',
    () async {
      final expected = await store.load();
      await store.save(
        name: 'New',
        title: 'Keep',
        items: [],
        tags: [],
        project: '',
      );
      await expectLater(
        store.importTemplates(expected, [
          const TemplateImportChoice(sample, TemplateImportAction.copy),
        ]),
        throwsA(isA<TaskTemplateException>()),
      );
      expect((await store.load()).single.name, 'New');
    },
  );
  test(
    'a second provider reads current persisted templates and CAS refuses a stale key replacement',
    () async {
      final drafts = h.container.read(workspaceDraftsProvider.notifier);
      final old = await drafts.readPersistedKey(TaskTemplate.storageKey);
      await store.importTemplates([], [
        const TemplateImportChoice(sample, TemplateImportAction.copy),
      ]);
      await expectLater(
        drafts.compareAndPut(
          TaskTemplate.storageKey,
          old,
          TaskTemplate.encode([]),
        ),
        throwsStateError,
      );
      expect((await TaskTemplateStore(drafts).load()).single.name, 'Travel');
    },
  );
  test(
    'full library and failed persistence leave every existing template untouched',
    () async {
      final rows = List.generate(
        24,
        (i) => TaskTemplate.fromJson({
          ...sample.toJson(),
          'id': 'local-$i',
          'name': 'Name $i',
        }),
      );
      await h.container
          .read(workspaceDraftsProvider.notifier)
          .put(TaskTemplate.storageKey, TaskTemplate.encode(rows));
      await expectLater(
        store.importTemplates(rows, [
          const TemplateImportChoice(sample, TemplateImportAction.copy),
        ]),
        throwsFormatException,
      );
      expect(await store.load(), hasLength(24));
    },
  );
  test(
    'native file boundary exports JSON and cleans only its own temporary directory on success or failure',
    () async {
      final exported = File('${h.directory.path}/templates.json');
      final io = TaskTemplateFileService(
        temporaryDirectory: () async => h.directory,
        exporter: TemplateExporter(exported),
        pickPath: () async => exported.path,
      );
      expect(await io.save([sample]), isTrue);
      expect((await io.pick())!.single.sameAs(sample), isTrue);
      expect(
        (await h.directory.list().toList()).where(
          (e) => e.path.contains('dontforget-template-export-'),
        ),
        isEmpty,
      );
      await expectLater(
        TaskTemplateFileService(
          temporaryDirectory: () async => h.directory,
          exporter: TemplateExporter(exported, fail: true),
        ).save([sample]),
        throwsStateError,
      );
      expect(await exported.exists(), isTrue);
      expect(
        (await h.directory.list().toList()).where(
          (e) => e.path.contains('dontforget-template-export-'),
        ),
        isEmpty,
      );
    },
  );
  test('cancelled and oversized file picks make no changes', () async {
    expect(
      await TaskTemplateFileService(pickPath: () async => null).pick(),
      isNull,
    );
    final big = await File(
      '${h.directory.path}/large.json',
    ).writeAsString('x' * (TaskTemplateTransfer.maxBytes + 1));
    await expectLater(
      TaskTemplateFileService(pickPath: () async => big.path).pick(),
      throwsFormatException,
    );
    expect(await store.load(), isEmpty);
  });
}
