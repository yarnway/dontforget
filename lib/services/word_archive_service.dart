import '../models/reminder.dart';
import '../models/vocabulary_entry.dart';
import 'learning_queue_service.dart';

class WordArchiveEntry {
  WordArchiveEntry(this.key, this.word, this.progress)
    : _searchable = LearningQueueService.wordKey(
        '$key ${word?.toNotes() ?? ''}',
      );
  final String key;
  final VocabularyEntry? word;
  final WordProgress progress;
  final String _searchable;
  String get title => word?.word ?? key;
  bool matches(String query) {
    final term = LearningQueueService.wordKey(query);
    return term.isEmpty || _searchable.contains(term);
  }
}

/// Read the same global progress as the queue, including retained histories.
/// A missing or corrected vocabulary document never hides an existing record.
class WordArchiveService {
  static List<WordArchiveEntry> project(Iterable<Reminder> source) {
    final progress = <String, WordProgress>{};
    final words = <String, VocabularyEntry>{};
    final winningWords = <String, VocabularyEntry?>{};
    try {
      for (final task in source) {
        final notes = {
          for (final word in VocabularyEntry.parseNotes(task.taskSummary ?? ''))
            LearningQueueService.wordKey(word.word): word,
        };
        for (final entry in notes.entries) {
          words.putIfAbsent(entry.key, () => entry.value);
        }
        for (final entry in LearningQueueService.decode(
          task.wordProgressJson,
        ).entries) {
          final previous = progress[entry.key];
          if (previous == null ||
              LearningQueueService.isNewerProgress(entry.value, previous)) {
            progress[entry.key] = entry.value;
            winningWords[entry.key] = notes[entry.key];
          }
        }
      }
    } on TypeError {
      throw const FormatException('Invalid word progress');
    }
    final entries = <WordArchiveEntry>[];
    for (final entry in progress.entries) {
      if (entry.key.trim().isEmpty) {
        throw const FormatException('Empty word identity');
      }
      entries.add(
        WordArchiveEntry(
          entry.key,
          winningWords[entry.key] ?? words[entry.key],
          entry.value,
        ),
      );
    }
    entries.sort((a, b) {
      final time = b.progress.reviewed.compareTo(a.progress.reviewed);
      return time == 0 ? a.key.compareTo(b.key) : time;
    });
    return List.unmodifiable(entries);
  }
}
