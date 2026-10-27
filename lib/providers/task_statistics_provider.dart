import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/task_statistics.dart';
import 'providers.dart';

final taskStatisticsProvider = Provider.autoDispose<TaskStatistics>((ref) {
  return TaskStatistics.from(
    ref.watch(remindersProvider).where((r) => r.isVisible),
  );
});
