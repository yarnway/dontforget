import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/study_management_strings.dart';
import '../../data/database_helper.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/word_archive_service.dart';
import '../../services/word_archive_cleanup_service.dart';
import '../../services/recovery/runtime_gate.dart';
import '../formatters/local_date_time.dart';
import '../widgets/inline_feedback.dart';

class WordArchiveScreen extends ConsumerStatefulWidget {
  const WordArchiveScreen({super.key});
  @override
  ConsumerState<WordArchiveScreen> createState() => _WordArchiveScreenState();
}

class _WordArchiveScreenState extends ConsumerState<WordArchiveScreen> {
  final _search = TextEditingController();
  List<Reminder>? _source;
  List<WordArchiveEntry>? _entries;
  late final DatabaseHelper _database;
  late final RuntimeRecoveryGate _runtime;
  RuntimeRecoveryToken? _birth;
  DataGeneration? _generation;
  bool _busy = false;
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      _generation != null &&
      _database.isCurrent(_generation!);
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _runtime = ref.read(runtimeRecoveryGateProvider);
    if (!_runtime.paused) {
      _birth = _runtime.capture();
      try {
        _generation = _database.captureGeneration();
      } on DatabaseAccessException {
        _generation = null;
      }
    }
  }

  Future<void> _cleanup() async {
    if (_busy || !_current) return;
    final loc = AppLocalizations.of(context);
    String t(String key) => studyManagementText(loc.locale.languageCode, key);
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final preview = WordArchiveCleanupService.preview(
        ref.read(remindersProvider),
      );
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('word-archive-cleanup-preview'),
          title: Text(t('archiveCleanup')),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t('archiveCleanupScope')),
                const SizedBox(height: 16),
                Text(
                  '${preview.candidates.length} / ${preview.eligibleCount} ${t('archiveCleanupCount')}',
                ),
                const SizedBox(height: 12),
                if (preview.candidates.isEmpty)
                  Text(t('archiveCleanupEmpty'))
                else
                  SizedBox(
                    height: (preview.candidates.length * 52.0).clamp(
                      52.0,
                      280.0,
                    ),
                    child: ListView.builder(
                      itemCount: preview.candidates.length,
                      itemBuilder: (_, index) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(preview.candidates[index].taskTitle),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          scrollable: true,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(loc.get('cancel')),
            ),
            FilledButton(
              key: const ValueKey('word-archive-cleanup-apply'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: preview.candidates.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(t('archiveCleanupApply')),
            ),
          ],
        ),
      );
      if (confirmed != true || !_current) return;
      await ref
          .read(remindersProvider.notifier)
          .clearWordArchives(preview, _generation!);
    } catch (error) {
      if (mounted && _current) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is WordArchiveCleanupStale
                  ? t('archiveCleanupStale')
                  : error is FormatException
                  ? loc.get('learningProgressInvalid')
                  : t('archiveCleanupFailed'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
      appBar: AppBar(
        title: Text(t('wordArchive')),
        actions: [
          IconButton(
            key: const ValueKey('word-archive-cleanup'),
            tooltip: t('archiveCleanup'),
            onPressed: all == null || all.isEmpty || _busy || !_current
                ? null
                : _cleanup,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
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
