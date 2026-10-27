/// A readable, version-independent vocabulary document stored in task notes.
/// Unknown or partially edited formats remain plain text: never discard notes.
class VocabularyEntry {
  const VocabularyEntry({
    required this.word,
    required this.meaning,
    required this.example,
    this.ipa,
    this.partOfSpeech,
    this.usage,
    this.translation,
  });
  final String word, meaning, example;
  final String? ipa, partOfSpeech, usage, translation;

  factory VocabularyEntry.fromModel(Map data) {
    String field(String key, int max) {
      final value = data[key];
      if (value is! String || value.trim().isEmpty || value.length > max) {
        throw const FormatException('Incomplete vocabulary entry');
      }
      return value.trim().replaceAll(RegExp(r'\s+'), ' ');
    }

    final ipa = field('ipa', 100);
    if (!RegExp(r'^/[^/]+/$').hasMatch(ipa)) {
      throw const FormatException('Expected IPA between slashes');
    }
    return VocabularyEntry(
      word: field('word', 80),
      meaning: field('meaning', 180),
      example: field('example', 240),
      ipa: ipa,
      partOfSpeech: field('part_of_speech', 40),
      usage: field('usage', 180),
      translation: field('translation', 240),
    );
  }

  String toNotes() => [
    '$word — $meaning',
    if (ipa != null) 'IPA: $ipa',
    if (partOfSpeech != null) 'POS: $partOfSpeech',
    if (usage != null) 'Usage: $usage',
    if (ipa == null) example else 'Example: $example',
    if (translation != null) 'Translation: $translation',
  ].join('\n');

  static List<VocabularyEntry> parseNotes(String source) {
    if (source.trim().isEmpty || source.length > 24000) return const [];
    final blocks = source
        .trim()
        .replaceAll('\r\n', '\n')
        .split(RegExp(r'\n\s*\n'));
    if (blocks.length > 20) return const [];
    final entries = <VocabularyEntry>[];
    for (final block in blocks) {
      final lines = block.split('\n');
      if (lines.length != 2 && lines.length != 6) return const [];
      final split = lines.first.indexOf(' — ');
      if (split < 1) return const [];
      final word = lines.first.substring(0, split).trim();
      final meaning = lines.first.substring(split + 3).trim();
      if (word.length > 80 || meaning.isEmpty || meaning.length > 180) {
        return const [];
      }
      if (lines.length == 2) {
        // rc.27 legacy batches contain only a definition and an example.
        if (lines[1].trim().isEmpty || lines[1].length > 240) return const [];
        entries.add(
          VocabularyEntry(
            word: word,
            meaning: meaning,
            example: lines[1].trim(),
          ),
        );
        continue;
      }
      const prefixes = [
        'IPA: ',
        'POS: ',
        'Usage: ',
        'Example: ',
        'Translation: ',
      ];
      if ([
        for (var i = 0; i < prefixes.length; i++)
          lines[i + 1].startsWith(prefixes[i]),
      ].contains(false)) {
        return const [];
      }
      try {
        entries.add(
          VocabularyEntry.fromModel({
            'word': word,
            'meaning': meaning,
            'ipa': lines[1].substring(5),
            'part_of_speech': lines[2].substring(5),
            'usage': lines[3].substring(7),
            'example': lines[4].substring(9),
            'translation': lines[5].substring(13),
          }),
        );
      } on FormatException {
        return const [];
      }
    }
    return List.unmodifiable(entries);
  }
}
