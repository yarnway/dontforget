import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/reminder.dart';
import '../services/task_search_index.dart';
import 'providers.dart';

final taskSearchIndexProvider =
    NotifierProvider.autoDispose<TaskSearchNotifier, TaskSearchIndex>(
      TaskSearchNotifier.new,
    );

class TaskSearchNotifier extends AutoDisposeNotifier<TaskSearchIndex> {
  TaskSearchIndex? _previous;

  @override
  TaskSearchIndex build() {
    return _previous = TaskSearchIndex(
      ref.watch(remindersProvider),
      previous: _previous,
    );
  }
}

final taskSearchResultsProvider = Provider.autoDispose
    .family<List<Reminder>, String>((ref, query) {
      if (query.trim().isEmpty) return const [];
      return ref.watch(taskSearchIndexProvider).search(query);
    });
