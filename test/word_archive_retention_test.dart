import 'dart:convert';
import 'package:dont_forget/services/word_archive_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'word_archive_test.dart' show archivedWord;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() => h.dispose());
  test(
    'deleting an edited source retains orphan progress without inventing a definition',
    () async {
      final source = archivedWord(
        'source',
        'pear',
        missingNotes: true,
        day: 3,
        reviews: 6,
        level: 4,
      );
      await h.seed(source);
      final before = WordArchiveService.project(
        await h.rows(),
      ).single.progress.toJson();
      await h.notifier.deleteReminder('source');
      final rows = await h.rows();
      expect(rows.where((r) => r.id == 'source'), isEmpty);
      final kept = rows.single;
      expect(kept.details.data['learning_archive'], isTrue);
      expect(kept.taskTitle, 'pear');
      expect(kept.taskSummary, isNull);
      final history = WordArchiveService.project(rows).single;
      expect(history.progress.toJson(), before);
      expect(history.word, isNull);
      await h.close();
      await h.open();
      expect(
        WordArchiveService.project(await h.rows()).single.progress.toJson(),
        before,
      );
    },
  );
  test(
    'newer orphan progress keeps previously archived vocabulary and ignores a different word identity',
    () async {
      await h.seed(archivedWord('original', 'apple', day: 2, meaning: '苹果'));
      await h.notifier.deleteReminder('original');
      final archived = (await h.rows()).single;
      final notes = archived.taskSummary;
      await h.seed(
        archivedWord(
          'edited',
          'apple',
          day: 3,
          shifted: 7,
          reviews: 5,
        ).copyWith(taskSummary: 'pear — 梨\nA pear.'),
      );
      await h.notifier.deleteReminder('edited');
      final rows = await h.rows();
      expect(rows.single.id, archived.id);
      expect(rows.single.taskSummary, notes);
      final record = WordArchiveService.project(rows).single;
      expect(record.key, 'apple');
      expect(record.word!.meaning, '苹果');
      expect(record.progress.reviews, 5);
      expect(record.progress.due, DateTime(2030, 2, 7));
      expect(
        WordArchiveService.project(rows).where((e) => e.key == 'pear'),
        isEmpty,
      );
    },
  );
  test(
    'clearing completed sources preserves orphan histories and unrelated rows',
    () async {
      await h.seed(archivedWord('orphan', 'pear', missingNotes: true));
      await h.seed(
        archivedWord('control', 'apple').copyWith(isCompleted: false),
      );
      final control = (await h.row('control')).toJson();
      await h.notifier.clearCompletedReminders();
      expect((await h.row('control')).toJson(), control);
      final entries = WordArchiveService.project(await h.rows());
      expect(entries.map((e) => e.key), ['apple', 'pear']);
      final before = jsonEncode(
        (await h.rows()).map((r) => r.toJson()).toList(),
      );
      await h.notifier.clearCompletedReminders();
      expect(
        jsonEncode((await h.rows()).map((r) => r.toJson()).toList()),
        before,
      );
    },
  );
  test(
    'an older orphan source cannot overwrite a newer archived manual date adjustment',
    () async {
      await h.seed(archivedWord('latest', 'apple', day: 2, shifted: 7));
      await h.notifier.deleteReminder('latest');
      final before = jsonEncode((await h.rows()).single.toJson());
      await h.seed(archivedWord('old', 'apple', day: 2, missingNotes: true));
      await h.notifier.deleteReminder('old');
      expect(jsonEncode((await h.rows()).single.toJson()), before);
    },
  );
  test(
    'archive write failure rolls back source deletion without native side effects',
    () async {
      await h.seed(archivedWord('source', 'pear', missingNotes: true));
      final before = (await h.row('source')).toJson();
      h.notifications.scheduled.clear();
      h.notifications.cancelled.clear();
      await h.database.writeTransaction(
        h.database.captureGeneration(),
        (db) => db.execute(
          "CREATE TRIGGER reject_orphan_archive BEFORE INSERT ON Reminders WHEN NEW.id LIKE 'word-history:%' BEGIN SELECT RAISE(ABORT, 'synthetic archive failure'); END",
        ),
      );
      await expectLater(h.notifier.deleteReminder('source'), throwsA(anything));
      expect((await h.rows()).single.toJson(), before);
      expect(h.notifications.scheduled, isEmpty);
      expect(h.notifications.cancelled, isEmpty);
    },
  );
}
