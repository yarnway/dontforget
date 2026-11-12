import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/study_management_strings.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/word_archive_service.dart';
import '../formatters/local_date_time.dart';

class WordArchiveScreen extends ConsumerStatefulWidget {
  const WordArchiveScreen({super.key});
  @override
  ConsumerState<WordArchiveScreen> createState() => _WordArchiveScreenState();
}

class _WordArchiveScreenState extends ConsumerState<WordArchiveScreen> {
  final _search = TextEditingController();
  List<Reminder>? _source;
  List<WordArchiveEntry>? _entries;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    String t(String key) => studyManagementText(loc.locale.languageCode, key);
    final rows = ref.watch(remindersProvider);
    if (!identical(rows, _source)) {
      _source = rows;
      try {
        _entries = WordArchiveService.project(rows);
      } on FormatException {
        _entries = null;
      }
    }
    final all = _entries;
    final visible = all?.where((e) => e.matches(_search.text)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(t('wordArchive'))),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    key: const ValueKey('word-archive-search'),
                    controller: _search,
                    enabled: all != null,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: t('archiveSearch'),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: loc.get('clearSearch'),
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(_search.clear),
                            ),
                    ),
                  ),
                ),
                if (visible != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      '${visible.length} / ${all!.length} ${t('archiveCount')}',
                    ),
                  ),
                Expanded(
                  child: all == null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(loc.get('learningProgressInvalid')),
                          ),
                        )
                      : visible!.isEmpty
                      ? Center(
                          child: Text(
                            t(
                              all.isEmpty ? 'archiveEmpty' : 'archiveNoMatches',
                            ),
                          ),
                        )
                      : ListView.builder(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final entry = visible[index], p = entry.progress;
                            return Card.outlined(
                              margin: const EdgeInsets.only(bottom: 16),
                              clipBehavior: Clip.antiAlias,
                              child: ExpansionTile(
                                key: ValueKey('word-archive-${entry.key}'),
                                title: Text(entry.title),
                                subtitle: entry.word == null
                                    ? null
                                    : Text(
                                        entry.word!.meaning,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                childrenPadding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  16,
                                ),
                                expandedCrossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  if (entry.word != null) ...[
                                    SelectableText(entry.word!.toNotes()),
                                    const SizedBox(height: 16),
                                  ],
                                  Text(
                                    '${t('archiveLevel')} ${p.level}/5 · ${t('archiveReviews')} ${p.reviews}',
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${t('archiveFirst')} · ${formatLocalDateTime(p.firstReviewed)}',
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${t('archiveLast')} · ${formatLocalDateTime(p.reviewed)}',
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${t('archiveDue')} · ${formatLocalDateTime(p.due)}',
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
