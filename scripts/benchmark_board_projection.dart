// Pure Dart diagnostic: list projection only, not Flutter frame timings.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/dynamic_urgency_service.dart';
import 'package:dont_forget/ui/widgets/task_board_data.dart';

const usage =
    'Usage: dart --packages=.dart_tool/package_config.json scripts/benchmark_board_projection.dart --fixture PATH\n'
    'Reads the closed synthetic 10000-task snapshot. Alternates the old and new\n'
    'projection for 30 warmups and 100 measured iterations, without UI or writes.\n';

List<String> legacy(List<Reminder> tasks, bool compact) {
  const urgency = DynamicUrgencyService();
  final grouped = List.generate(4, (_) => <Reminder>[]);
  final pending = List.filled(4, 0);
  for (final task in tasks) {
    final index = task.quadrantLevel - 1;
    if (index < 0 || index >= 4) continue;
    grouped[index].add(task);
    if (!task.isCompleted) pending[index]++;
  }
  final signature = pending.map((n) => '$n').toList();
  for (var index = 0; index < (compact ? 1 : 4); index++) {
    final active = <Reminder>[];
    final completed = <Reminder>[];
    final folded = <Reminder>[];
    for (final task in grouped[index]) {
      if (task.quadrantLevel != index + 1) continue;
      if (task.isCompleted) {
        completed.add(task);
      } else if (index == 3 && urgency.isQ4StagnantFolded(task)) {
        folded.add(task);
      } else {
        active.add(task);
      }
    }
    final rows = <Object>[
      ...active,
      if (completed.isNotEmpty) 'completed',
      if (folded.isNotEmpty) 'folded',
    ];
    signature.add('${rows.length}');
    signature.addAll(
      rows.take(40).map((r) => r is Reminder ? r.id : r as String),
    );
  }
  return signature;
}

List<String> projected(List<Reminder> tasks, bool compact) {
  final data = TaskBoardData.project(
    tasks,
    visibleCategory: compact ? 0 : null,
    isFolded: const DynamicUrgencyService().isQ4StagnantFolded,
  );
  final signature = data.pending.map((n) => '$n').toList();
  for (final section in data.sections.take(compact ? 1 : 4)) {
    final n = section.rowCount(completedExpanded: false, foldedExpanded: false);
    signature.add('$n');
    for (var i = 0; i < n && i < 40; i++) {
      final row = section.rowAt(
        i,
        completedExpanded: false,
        foldedExpanded: false,
      );
      signature.add(row is Reminder ? row.id : row as String);
    }
  }
  return signature;
}

Map<String, int> stats(List<int> samples) {
  samples.sort();
  return {
    'samples': samples.length,
    'p50_us': samples[49],
    'p95_us': samples[94],
    'max_us': samples.last,
  };
}

void main(List<String> args) {
  if (args.length == 1 && args.single == '--help') {
    stdout.write(usage);
    return;
  }
  if (args.length != 2 || args.first != '--fixture') {
    stderr.write(usage);
    exitCode = 64;
    return;
  }
  final bytes = File(args[1]).readAsBytesSync();
  final rows = (jsonDecode(utf8.decode(bytes)) as Map)['reminders'] as List;
  if (rows.length != 10000 ||
      rows.asMap().entries.any((e) => e.value['id'] != 'synthetic-${e.key}')) {
    throw StateError('Expected ordered synthetic 10000-task fixture');
  }
  final tasks = rows
      .map((r) => Reminder.fromJson(Map<String, dynamic>.from(r as Map)))
      .toList();
  final results = <Object>[];
  for (final compact in [true, false]) {
    final old = <int>[];
    final current = <int>[];
    for (var i = 0; i < 130; i++) {
      for (final newer in i.isEven ? [false, true] : [true, false]) {
        final timer = Stopwatch()..start();
        final value = (newer ? projected : legacy)(tasks, compact);
        final elapsed = timer.elapsedMicroseconds;
        if (jsonEncode(value) != jsonEncode(legacy(tasks, compact))) {
          throw StateError('Projection differs');
        }
        if (i >= 30) (newer ? current : old).add(elapsed);
      }
    }
    results.add({
      'layout': compact ? 'compact' : 'four_panels',
      'legacy': stats(old),
      'projected': stats(current),
    });
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'scope':
          'Alternating pure Dart JIT projection only, not frame or product startup timings',
      'fixture_sha256': sha256.convert(bytes).toString(),
      'runtime': Platform.version,
      'results': results,
    }),
  );
}
