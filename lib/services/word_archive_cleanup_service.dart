import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/reminder.dart';
import '../models/task_details.dart';
import '../models/vocabulary_entry.dart';
import 'learning_queue_service.dart';

class WordArchiveCleanupStale implements Exception {
  const WordArchiveCleanupStale();
}

class WordArchiveCleanupPreview {
  WordArchiveCleanupPreview._(
    this.snapshot,
    this.preparedAt,
    List<Reminder> candidates,
    this.eligibleCount,
  ) : candidates = List.unmodifiable(candidates);
  final String snapshot;
  final DateTime preparedAt;
  final List<Reminder> candidates;
  final int eligibleCount;
}

/// Remove only generated, unreferenced retention rows. Ordinary task progress
/// and today's global learning allowance remain intact.
class WordArchiveCleanupService {
  static const maxBatchSize = 200;

  static String snapshot(Iterable<Reminder> source) {
    final rows = source.toList()..sort((a, b) => a.id.compareTo(b.id));
    if (rows.map((r) => r.id).toSet().length != rows.length) {
      throw const FormatException('Duplicate reminder identity');
    }
    return jsonEncode(rows.map((r) => r.toJson()).toList());
  }

  static WordArchiveCleanupPreview preview(
    Iterable<Reminder> source, {
    DateTime? now,
  }) {
    final rows = source.toList(), at = now ?? DateTime.now();
    final protectedWords = <String>{};
    final referencedIds = <String>{};
    final generatedIds = <String>{};
    final decoded = <String, Map<String, WordProgress>>{};
    try {
      for (final row in rows) {
        final progress = LearningQueueService.decode(row.wordProgressJson);
        if (progress.keys.any((k) => k.trim().isEmpty)) {
          throw const FormatException('Empty word identity');
        }
        decoded[row.id] = progress;
        referencedIds.addAll(row.linkedTaskIds);
        if (row.details.planId != null) referencedIds.add(row.details.planId!);
        if (row.details.data['learning_archive'] == true &&
            progress.length == 1 &&
            progress.keys.single ==
                LearningQueueService.wordKey(progress.keys.single) &&
            _generated(row, progress.keys.single)) {
          generatedIds.add(row.id);
        }
        // Imported or edited marker rows can still be ordinary study sources.
        if (!generatedIds.contains(row.id)) {
          protectedWords.addAll(
            progress.keys.map(LearningQueueService.wordKey),
          );
          protectedWords.addAll(
            VocabularyEntry.parseNotes(
              row.taskSummary ?? '',
            ).map((w) => LearningQueueService.wordKey(w.word)),
          );
        }
      }
    } on TypeError {
      throw const FormatException('Invalid word progress');
    }
    final eligible = <Reminder>[];
    for (final row in rows) {
      final progress = decoded[row.id]!;
      if (!generatedIds.contains(row.id)) {
        continue;
      }
      final key = progress.keys.single, p = progress.values.single;
      if (protectedWords.contains(key) ||
          referencedIds.contains(row.id) ||
          p.reviewed.isAfter(at) ||
          LearningQueueService.sameDay(p.reviewed, at) ||
          LearningQueueService.sameDay(p.firstReviewed, at)) {
        continue;
      }
      eligible.add(row);
    }
    eligible.sort((a, b) {
      final title = LearningQueueService.wordKey(
        a.taskTitle,
      ).compareTo(LearningQueueService.wordKey(b.taskTitle));
      return title == 0 ? a.id.compareTo(b.id) : title;
    });
    return WordArchiveCleanupPreview._(
      snapshot(rows),
      at,
      eligible.take(maxBatchSize).toList(),
      eligible.length,
    );
  }

  static bool _generated(Reminder row, String key) {
    final d = row.details;
    final notes = row.taskSummary;
    if (notes != null && notes.trim().isNotEmpty) {
      final words = VocabularyEntry.parseNotes(notes);
      if (words.length != 1 ||
          LearningQueueService.wordKey(words.single.word) != key) {
        return false;
      }
    }
    if (row.id != 'word-history:${sha256.convert(utf8.encode(key))}' ||
        d.archivedAt == null ||
        d.history.any(
          (e) =>
              e.action != 'word_review' || e.note?.startsWith('$key:') != true,
        )) {
      return false;
    }
    final expectedDetails = TaskDetails(
      kind: 'study',
      archivedAt: d.archivedAt,
      history: d.history,
      data: const {'learning_archive': true},
    );
    if (d.encode() != expectedDetails.encode()) return false;
    final expected = Reminder(
      id: row.id,
      taskTitle: row.taskTitle,
      taskSummary: row.taskSummary,
      quadrantLevel: 2,
      isCompleted: true,
      wordProgressJson: row.wordProgressJson,
      createdAt: row.createdAt,
      detailsJson: row.detailsJson,
    );
    return jsonEncode(row.toJson()) == jsonEncode(expected.toJson());
  }
}
