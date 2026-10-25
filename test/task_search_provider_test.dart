import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/task_search_provider.dart';
import 'package:dont_forget/services/task_search_index.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Source extends RemindersNotifier {
  _Source(super.database) : super(runLoadEffects: false);
  void replace(List<Reminder> tasks) => state = tasks;
}

class _Reminder extends Reminder {
  _Reminder({bool completed = false})
    : super(
        id: 'one',
        taskTitle: 'Current task',
        subTasks: '["Checklist"]',
        quadrantLevel: 2,
        isCompleted: completed,
      );
  int decodes = 0;
  @override
  List<String> getSubTasksList() {
    decodes++;
    return super.getSubTasksList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'provider reuses text across revisions and drops removed data on invalidation',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'search-provider-',
      );
      final db = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
      final source = _Source(db);
      await source.ready;
      final container = ProviderContainer(
        overrides: [remindersProvider.overrideWith((_) => source)],
      );
      final subscription = container.listen(taskSearchIndexProvider, (_, _) {});
      try {
        final first = _Reminder();
        source.replace([first]);
        final initial = container.read(taskSearchIndexProvider);
        expect(initial.search('checklist').single, same(first));
        expect(first.decodes, 1);
        final completed = _Reminder(completed: true);
        source.replace([completed]);
        final updated = container.read(taskSearchIndexProvider);
        expect(
          updated
              .search('checklist', filter: TaskSearchFilter.completed)
              .single,
          same(completed),
        );
        expect(completed.decodes, 0);
        source.replace([]);
        expect(
          container.read(taskSearchIndexProvider).search('checklist'),
          isEmpty,
        );
        container.invalidate(taskSearchIndexProvider);
        expect(
          container.read(taskSearchIndexProvider).search('checklist'),
          isEmpty,
        );
        source.replace([_Reminder()]);
        expect(
          container
              .read(taskSearchResultsProvider('current'))
              .single
              .isCompleted,
          isFalse,
        );
        expect(initial.search('checklist').single.isCompleted, isFalse);
      } finally {
        subscription.close();
        container.dispose();
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
