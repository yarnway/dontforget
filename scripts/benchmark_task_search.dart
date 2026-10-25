// Run with `dart run scripts/benchmark_task_search.dart`.
// Synthetic CPU-only comparison; these are not native UI frame timings.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/task_search_index.dart';

// Same multi-keyword semantics, without a retained normalized index.
List<Reminder> scanSearch(List<Reminder> reminders, String query) {
  final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
  return reminders.where((r) {
    final fields = [
      r.taskTitle.toLowerCase(),
      (r.taskSummary ?? '').toLowerCase(),
      ...r.getSubTasksList().map((text) => text.toLowerCase()),
    ];
    return terms.every((term) => fields.any((field) => field.contains(term)));
  }).toList();
}

Map<String, int> measure(void Function() action) {
  for (var i = 0; i < 10; i++) {
    action();
  }
  final samples = <int>[];
  for (var i = 0; i < 100; i++) {
    final watch = Stopwatch()..start();
    action();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return {'p50_us': samples[49], 'p95_us': samples[94]};
}

void main() {
  final results = <Map<String, Object>>[];
  for (final count in [100, 1000, 10000]) {
    final data = List.generate(
      count,
      (i) => Reminder(
        id: '$i',
        taskTitle: 'Project planning $i',
        taskSummary: 'Review documentation and milestones $i',
        subTasks: jsonEncode(['Review release checklist $i', '准备发布说明 $i']),
        quadrantLevel: i % 4 + 1,
        createdAt: DateTime.utc(2026, 10, 25),
      ),
    );
    final build = Stopwatch()..start();
    final index = TaskSearchIndex(data);
    build.stop();
    final before = scanSearch(data, '发布说明 9');
    final after = index.search('发布说明 9');
    if (before.map((r) => r.id).join(',') != after.map((r) => r.id).join(',')) {
      throw StateError('Search results differ at $count tasks');
    }
    final changed = [...data];
    changed[count ~/ 2] = changed[count ~/ 2].copyWith(
      taskTitle: 'Edited task',
    );
    final full = TaskSearchIndex(changed);
    final incremental = TaskSearchIndex(changed, previous: index);
    for (final query in [
      '发布说明 9',
      'edited task',
      'project checklist',
      'missing',
    ]) {
      if (full.search(query).map((r) => r.id).join(',') !=
          incremental.search(query).map((r) => r.id).join(',')) {
        throw StateError(
          'Incremental results differ for $query at $count tasks',
        );
      }
    }
    results.add({
      'tasks': count,
      'fixture_sha256': sha256
          .convert(
            utf8.encode(jsonEncode(data.map((r) => r.toJson()).toList())),
          )
          .toString(),
      'index_build_us': build.elapsedMicroseconds,
      'uncached_keyword_search': measure(() => scanSearch(data, '发布说明 9')),
      'indexed_search': measure(() => index.search('发布说明 9')),
      'full_rebuild_one_edit': measure(() => TaskSearchIndex(changed)),
      'incremental_rebuild_one_edit': measure(
        () => TaskSearchIndex(changed, previous: index),
      ),
      'matching_tasks': after.length,
    });
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'dataset':
          'search-v2; IDs 0..N-1; fixed createdAt 2026-10-25 UTC; edit middle title only',
      'semantics':
          'All whitespace-separated keywords must occur across title, summary or subtasks',
      'scope':
          'Synthetic single-process Dart search CPU time; 10 warmups, 100 samples; microseconds',
      'results': results,
    }),
  );
}
