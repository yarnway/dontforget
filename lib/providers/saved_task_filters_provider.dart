import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/saved_task_filter.dart';
import 'workspace_drafts_provider.dart';

final savedTaskFilterStoreProvider = Provider<SavedTaskFilterStore>((ref) {
  return SavedTaskFilterStore(
    ref.watch(workspaceDraftsProvider.notifier),
    () => ref.read(workspaceDraftsProvider),
  );
});

enum SavedTaskFilterFailure { duplicateName, limitReached, changed }

class SavedTaskFilterException implements Exception {
  const SavedTaskFilterException(this.reason);
  final SavedTaskFilterFailure reason;
}

/// Serializes named-view edits while WorkspaceDrafts merges unrelated keys and
/// enforces the database generation, maintenance gate and durable transaction.
class SavedTaskFilterStore {
  SavedTaskFilterStore(this._drafts, this._read);
  final WorkspaceDrafts _drafts;
  final Map<String, dynamic> Function() _read;
  Future<void> _tail = Future.value();

  Future<List<SavedTaskFilter>> load() async {
    await _drafts.ready;
    _drafts.database.checkGeneration(_drafts.generation);
    return SavedTaskFilter.decode(_read()[SavedTaskFilter.storageKey]);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _write(List<SavedTaskFilter> items) =>
      _drafts.put(SavedTaskFilter.storageKey, SavedTaskFilter.encode(items));

  void _checkName(List<SavedTaskFilter> items, String name, {String? except}) {
    if (items.any(
      (e) => e.id != except && e.name.toLowerCase() == name.toLowerCase(),
    )) {
      throw const SavedTaskFilterException(
        SavedTaskFilterFailure.duplicateName,
      );
    }
  }

  Future<void> save(String name, String view, String query) =>
      _enqueue(() async {
        final items = await load();
        final next = SavedTaskFilter.fromJson(
          SavedTaskFilter(
            id: const Uuid().v4(),
            name: name.trim(),
            view: view,
            query: query.trim(),
          ).toJson(),
        );
        _checkName(items, next.name);
        if (items.length >= SavedTaskFilter.maxCount) {
          throw const SavedTaskFilterException(
            SavedTaskFilterFailure.limitReached,
          );
        }
        await _write([...items, next]);
      });

  Future<void> rename(SavedTaskFilter expected, String name) =>
      _enqueue(() async {
        final items = await load();
        final current = items.where((e) => e.id == expected.id).firstOrNull;
        if (current == null || !current.sameAs(expected)) {
          throw const SavedTaskFilterException(SavedTaskFilterFailure.changed);
        }
        final next = SavedTaskFilter.fromJson(current.renamed(name).toJson());
        _checkName(items, next.name, except: next.id);
        await _write([
          for (final item in items) item.id == next.id ? next : item,
        ]);
      });

  Future<int> remove(SavedTaskFilter expected) => _enqueue(() async {
    final items = await load();
    final index = items.indexWhere((e) => e.id == expected.id);
    if (index < 0 || !items[index].sameAs(expected)) {
      throw const SavedTaskFilterException(SavedTaskFilterFailure.changed);
    }
    await _write([
      for (final item in items)
        if (item.id != expected.id) item,
    ]);
    return index;
  });

  Future<void> restore(SavedTaskFilter filter, int index) => _enqueue(() async {
    final items = await load();
    final existing = items.where((e) => e.id == filter.id).firstOrNull;
    if (existing != null) {
      if (existing.sameAs(filter)) return;
      throw const SavedTaskFilterException(SavedTaskFilterFailure.changed);
    }
    _checkName(items, filter.name);
    if (items.length >= SavedTaskFilter.maxCount) {
      throw const SavedTaskFilterException(SavedTaskFilterFailure.limitReached);
    }
    final next = [...items]..insert(index.clamp(0, items.length), filter);
    await _write(next);
  });
}
