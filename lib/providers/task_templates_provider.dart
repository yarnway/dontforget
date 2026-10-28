import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/task_template.dart';
import '../models/task_template_transfer.dart';
import 'workspace_drafts_provider.dart';

final taskTemplateStoreProvider = Provider<TaskTemplateStore>(
  (ref) => TaskTemplateStore(ref.watch(workspaceDraftsProvider.notifier)),
);

enum TaskTemplateFailure { duplicateName, limitReached, changed }

class TaskTemplateException implements Exception {
  const TaskTemplateException(this.reason);
  final TaskTemplateFailure reason;
}

class TaskTemplateStore {
  TaskTemplateStore(this._drafts);
  final WorkspaceDrafts _drafts;
  Future<void> _tail = Future.value();

  Future<List<TaskTemplate>> load() async {
    await _drafts.ready;
    _drafts.database.checkGeneration(_drafts.generation);
    return TaskTemplate.decode(
      await _drafts.readPersistedKey(TaskTemplate.storageKey),
    );
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> save({
    TaskTemplate? expected,
    required String name,
    required String title,
    required List<String> items,
    required List<String> tags,
    required String project,
  }) => _enqueue(() async {
    final raw = await _drafts.readPersistedKey(TaskTemplate.storageKey);
    final all = TaskTemplate.decode(raw);
    if (expected != null &&
        !all.any((e) => e.id == expected.id && e.sameAs(expected))) {
      throw const TaskTemplateException(TaskTemplateFailure.changed);
    }
    final next = TaskTemplate.fromJson(
      TaskTemplate(
        id: expected?.id ?? const Uuid().v4(),
        name: name.trim(),
        title: title.trim(),
        items: items,
        tags: tags,
        project: project.trim(),
      ).toJson(),
    );
    if (all.any(
      (e) => e.id != next.id && e.name.toLowerCase() == next.name.toLowerCase(),
    )) {
      throw const TaskTemplateException(TaskTemplateFailure.duplicateName);
    }
    if (expected == null && all.length >= TaskTemplate.maxCount) {
      throw const TaskTemplateException(TaskTemplateFailure.limitReached);
    }
    await _drafts.compareAndPut(
      TaskTemplate.storageKey,
      raw,
      TaskTemplate.encode(
        expected == null
            ? [...all, next]
            : [for (final e in all) e.id == next.id ? next : e],
      ),
    );
  });

  Future<void> remove(TaskTemplate expected) => _enqueue(() async {
    final raw = await _drafts.readPersistedKey(TaskTemplate.storageKey);
    final all = TaskTemplate.decode(raw);
    if (!all.any((e) => e.id == expected.id && e.sameAs(expected))) {
      throw const TaskTemplateException(TaskTemplateFailure.changed);
    }
    await _drafts.compareAndPut(
      TaskTemplate.storageKey,
      raw,
      TaskTemplate.encode(all.where((e) => e.id != expected.id)),
    );
  });

  Future<void> importTemplates(
    List<TaskTemplate> expected,
    List<TemplateImportChoice> choices,
  ) {
    final baseline = TaskTemplate.decode(TaskTemplate.encode(expected));
    final frozen = List<TemplateImportChoice>.unmodifiable(
      choices.map(
        (e) => TemplateImportChoice(
          TaskTemplate.fromJson(e.item.toJson()),
          e.action,
        ),
      ),
    );
    return _enqueue(() async {
      final raw = await _drafts.readPersistedKey(TaskTemplate.storageKey);
      final all = TaskTemplate.decode(raw);
      if (all.length != baseline.length ||
          List.generate(
            all.length,
            (i) => all[i].sameAs(baseline[i]),
          ).contains(false)) {
        throw const TaskTemplateException(TaskTemplateFailure.changed);
      }
      final merged = TaskTemplateTransfer.merge(all, frozen);
      await _drafts.compareAndPut(
        TaskTemplate.storageKey,
        raw,
        TaskTemplate.encode(merged),
      );
    });
  }
}
