import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/reminder.dart';
import '../services/task_search_index.dart';
import 'providers.dart';

final taskSearchIndexProvider = Provider.autoDispose<TaskSearchIndex>((ref) {
  return TaskSearchIndex(ref.watch(remindersProvider));
});

final taskSearchResultsProvider = Provider.autoDispose
    .family<List<Reminder>, String>((ref, query) {
      if (query.trim().isEmpty) return const [];
      return ref.watch(taskSearchIndexProvider).search(query);
    });
