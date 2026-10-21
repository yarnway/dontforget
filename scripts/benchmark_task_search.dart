// Run with `dart run scripts/benchmark_task_search.dart`.
// Synthetic CPU-only comparison; these are not native UI frame timings.
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/task_search_index.dart';

List<Reminder> originalSearch(List<Reminder> reminders, String query) {
  final q = query.trim().toLowerCase();
  return reminders.where((r) {
    return r.taskTitle.toLowerCase().contains(q) ||
        (r.taskSummary ?? '').toLowerCase().contains(q) ||
        r.getSubTasksList().any((sub) => sub.toLowerCase().contains(q));
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
      ),
    );
    final build = Stopwatch()..start();
    final index = TaskSearchIndex(data);
    build.stop();
    final before = originalSearch(data, '发布说明 9');
    final after = index.search('发布说明 9');
    if (before.map((r) => r.id).join(',') != after.map((r) => r.id).join(',')) {
      throw StateError('Search results differ at $count tasks');
    }
    results.add({
      'tasks': count,
      'index_build_us': build.elapsedMicroseconds,
      'previous_search': measure(() => originalSearch(data, '发布说明 9')),
      'indexed_search': measure(() => index.search('发布说明 9')),
      'matching_tasks': after.length,
    });
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'scope':
          'Synthetic single-process Dart search CPU time; 10 warmups, 100 samples; microseconds',
      'results': results,
    }),
  );
}
