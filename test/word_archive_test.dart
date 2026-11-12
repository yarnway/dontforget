import 'dart:convert';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/learning_queue_service.dart';
import 'package:dont_forget/services/word_archive_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'study_plan_management_test.dart' show batch;

Reminder archivedWord(
  String id,
  String word, {
  int day = 1,
  int level = 1,
  int reviews = 1,
  int? shifted,
  String meaning = 'fruit',
  bool missingNotes = false,
}) => batch(id, archived: DateTime(2030)).copyWith(
  taskSummary: missingNotes
      ? 'Edited plain notes'
      : '$word — $meaning\nAn example.',
  wordProgressJson: jsonEncode({
    LearningQueueService.wordKey(word): WordProgress(
      level: level,
      due: DateTime(2030, 2, shifted ?? day),
      reviewed: DateTime(2030, 1, day),
      firstReviewed: DateTime(2030, 1),
      reviews: reviews,
      grade: 2,
      rescheduledAt: shifted == null ? null : DateTime(2030, 1, day, shifted),
    ).toJson(),
  }),
);

void main() {
  test(
    'archive follows global queue history including retained and trashed rows',
    () {
      final rows = [
        batch('active'),
        archivedWord('history', 'apple', day: 2, level: 3, reviews: 4),
        archivedWord('trashed', 'banana', day: 3).copyWith(
          detailsJson: batch('x', deleted: DateTime(2030)).detailsJson,
        ),
      ];
      final before = jsonEncode(rows.map((r) => r.toJson()).toList());
      final entries = WordArchiveService.project(rows);
      expect(entries.map((e) => e.key), ['banana', 'apple']);
      final queue = LearningQueueService.progress(rows);
      for (final entry in entries) {
        expect(entry.progress.toJson(), queue[entry.key]!.toJson());
      }
      expect(jsonEncode(rows.map((r) => r.toJson()).toList()), before);
      expect(() => entries.clear(), throwsUnsupportedError);
    },
  );
  test(
    'latest manual date edit and latest matching vocabulary document win',
    () {
      final old = archivedWord('old', 'Apple', day: 2, meaning: 'old');
      final newer = archivedWord(
        'new',
        'APPLE',
        day: 2,
        shifted: 7,
        meaning: 'new',
      );
      for (final rows in [
        [old, newer],
        [newer, old],
      ]) {
        final entry = WordArchiveService.project(rows).single;
        expect(entry.word!.meaning, 'new');
        expect(entry.progress.due, DateTime(2030, 2, 7));
      }
    },
  );
  test(
    'a later review supersedes a manual edit without changing original records',
    () {
      final entry = WordArchiveService.project([
        archivedWord('shifted', 'apple', day: 2, shifted: 7),
        archivedWord('reviewed', 'apple', day: 3, reviews: 2),
      ]).single;
      expect(entry.progress.reviews, 2);
      expect(entry.progress.rescheduledAt, isNull);
    },
  );
  test(
    'missing or corrected notes retain orphan progress with an honest identity',
    () {
      final orphan = archivedWord('orphan', 'pear', missingNotes: true);
      final entry = WordArchiveService.project([orphan]).single;
      expect(entry.key, 'pear');
      expect(entry.title, 'pear');
      expect(entry.word, isNull);
      expect(
        WordArchiveService.project([
          orphan,
          batch(
            'notes',
          ).copyWith(taskSummary: 'pear — 梨\nA pear.', wordProgressJson: null),
        ]).single.word!.meaning,
        '梨',
      );
    },
  );
  test(
    'search normalizes case and spaces and includes meanings and examples',
    () {
      final entry = WordArchiveService.project([
        archivedWord('a', ' Ice cream ', meaning: '冰淇淋'),
      ]).single;
      for (final q in ['ICE   CREAM', ' 冰淇淋 ', 'an EXAMPLE', '']) {
        expect(entry.matches(q), isTrue);
      }
      expect(entry.matches('banana'), isFalse);
    },
  );
  test(
    'new words without feedback are not represented as historical reviews',
    () {
      expect(
        WordArchiveService.project([
          batch('new').copyWith(wordProgressJson: null),
        ]),
        isEmpty,
      );
    },
  );
  test(
    'malformed history is surfaced rather than presented as an empty archive',
    () {
      for (final raw in [
        'bad',
        '[]',
        '{"apple":[]}',
        '{"apple":{"level":"bad"}}',
      ]) {
        expect(
          () => WordArchiveService.project([
            batch('bad').copyWith(wordProgressJson: raw),
          ]),
          throwsFormatException,
        );
      }
      final raw =
          jsonDecode(archivedWord('a', 'apple').wordProgressJson!) as Map;
      expect(
        () => WordArchiveService.project([
          batch(
            'blank',
          ).copyWith(wordProgressJson: jsonEncode({' ': raw['apple']})),
        ]),
        throwsFormatException,
      );
    },
  );
  test('same-time records have stable alphabetical display order', () {
    final entries = WordArchiveService.project([
      archivedWord('b', 'banana'),
      archivedWord('a', 'apple'),
    ]);
    expect(entries.map((e) => e.key), ['apple', 'banana']);
  });
}
