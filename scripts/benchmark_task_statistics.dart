// Synthetic aggregation CPU timing, not native layout or product startup.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_statistics.dart';

typedef Counts = ({int total, int completed, List<int> categories});
Counts previousStatistics(List<Reminder> tasks) => (
  total: tasks.length,
  completed: tasks.where((r) => r.isCompleted).length,
  categories: [
    for (var q = 1; q <= 4; q++)
      tasks.where((r) => r.quadrantLevel == q).length,
  ],
);
int sink = 0;
Map<String, int> measure(int Function() action) {
  for (var i = 0; i < 20; i++) {
    sink ^= action();
  }
  final samples = <int>[];
  for (var i = 0; i < 200; i++) {
    final watch = Stopwatch()..start();
    sink ^= action();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return {'p50_us': samples[99], 'p95_us': samples[189]};
}

int checksum(int total, int completed, List<int> categories) =>
    total + completed + categories.fold(0, (sum, value) => sum + value);

void main() {
  final results = <Map<String, Object>>[];
  for (final count in [100, 1000, 10000]) {
    final tasks = List.generate(
      count,
      (i) => Reminder(
        id: '$i',
        taskTitle: 'Planning task $i',
        quadrantLevel: i % 4 + 1,
        isCompleted: i % 3 == 0,
        createdAt: DateTime.utc(2026, 10, 26),
      ),
    );
    final old = previousStatistics(tasks);
    final stats = TaskStatistics.from(tasks);
    if (old.total != stats.total ||
        old.completed != stats.completed ||
        jsonEncode(old.categories) != jsonEncode(stats.categories)) {
      throw StateError('Statistics differ at $count tasks');
    }
    results.add({
      'tasks': count,
      'fixture_sha256': sha256
          .convert(
            utf8.encode(jsonEncode(tasks.map((r) => r.toJson()).toList())),
          )
          .toString(),
      'previous_five_scans': measure(() {
        final s = previousStatistics(tasks);
        return checksum(s.total, s.completed, s.categories);
      }),
      'single_pass_with_bounded_title_samples': measure(() {
        final s = TaskStatistics.from(tasks);
        return checksum(s.total, s.completed, s.categories);
      }),
      'completion_percent': stats.completionPercent,
    });
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'scope':
          'Single-process synthetic Dart aggregation CPU; 20 warmups and 200 samples per metric; microseconds. No native frame or startup claim.',
      'dataset':
          'statistics-v1; fixed createdAt 2026-10-26 UTC, round-robin categories, every third task completed',
      'results': results,
      'checksum_sink': sink,
    }),
  );
}
