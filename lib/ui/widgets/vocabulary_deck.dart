import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/vocabulary_entry.dart';

/// Only the current word is built; parsing is cached until notes change.
class VocabularyDeck extends StatefulWidget {
  const VocabularyDeck({
    super.key,
    required this.content,
    this.practice = false,
    this.individualFeedback = false,
  });
  final String content;
  final bool practice;
  final bool individualFeedback;
  @override
  State<VocabularyDeck> createState() => _VocabularyDeckState();
}

class _VocabularyDeckState extends State<VocabularyDeck> {
  late List<VocabularyEntry> _words;
  int _index = 0;
  late bool _revealed;
  @override
  void initState() {
    super.initState();
    _read();
  }

  void _read() {
    _words = VocabularyEntry.parseNotes(widget.content);
    _index = 0;
    _revealed = !widget.practice;
  }

  @override
  void didUpdateWidget(VocabularyDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.practice != widget.practice) {
      _read();
    }
  }

  void _move(int step) => setState(() {
    _index += step;
    _revealed = !widget.practice;
  });

  @override
  Widget build(BuildContext context) {
    if (_words.isEmpty) return SelectableText(widget.content);
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final word = _words[_index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.style_outlined, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                loc.get('vocabCards'),
                style: theme.textTheme.labelLarge,
              ),
            ),
            Text(
              '${_index + 1} / ${_words.length}',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: (_index + 1) / _words.length,
          minHeight: 3,
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: 16),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  word.word,
                  key: const ValueKey('vocab-word'),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                if (word.ipa != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    word.ipa!,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.primary,
                      height: 1.5,
                    ),
                  ),
                ],
                if (word.partOfSpeech != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        child: Text(
                          word.partOfSpeech!,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: colors.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                if (!_revealed)
                  Text(
                    loc.get('vocabRecall'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  )
                else ...[
                  _section(context, loc.get('vocabMeaning'), word.meaning),
                  if (word.usage != null)
                    _section(context, loc.get('vocabUsage'), word.usage!),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          loc.get('vocabExample'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          word.example,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            height: 1.6,
                          ),
                        ),
                        if (word.translation != null) ...[
                          const SizedBox(height: 8),
                          SelectableText(
                            word.translation!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.6,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (widget.practice) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const ValueKey('vocab-reveal'),
                    onPressed: () => setState(() => _revealed = !_revealed),
                    icon: Icon(
                      _revealed
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    label: Text(
                      loc.get(_revealed ? 'reviewHideAnswer' : 'flipCard'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_words.length > 1) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const ValueKey('vocab-previous'),
                  onPressed: _index == 0 ? null : () => _move(-1),
                  child: Text(loc.get('vocabPrevious')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  key: const ValueKey('vocab-next'),
                  onPressed: _index == _words.length - 1
                      ? null
                      : () => _move(1),
                  child: Text(loc.get('vocabNext')),
                ),
              ),
            ],
          ),
        ],
        if (widget.practice)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              loc.get(
                widget.individualFeedback
                    ? 'wordFeedbackHint'
                    : 'vocabBatchFeedback',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _section(BuildContext context, String title, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }
}
