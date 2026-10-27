import '../../data/database_helper.dart';
import '../../services/recovery/runtime_gate.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/providers.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/learning_queue_service.dart';
import '../formatters/local_date_time.dart';
import 'inline_feedback.dart';
import 'vocabulary_deck.dart';
import 'workspace_tool_panel.dart';
import '../screens/notification_repair_screen.dart';

class LearningQueuePanel extends ConsumerStatefulWidget {
  const LearningQueuePanel({super.key, this.onClose, this.embedded = true});
  final VoidCallback? onClose;
  final bool embedded;
  @override
  ConsumerState<LearningQueuePanel> createState() => _LearningQueuePanelState();
}

class _LearningQueuePanelState extends ConsumerState<LearningQueuePanel>
    with WidgetsBindingObserver {
  Timer? _clock;
  bool _saving = false;
  late final DatabaseHelper _database;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken? _birth;
  DataGeneration? _generation;
  bool get _current =>
      mounted &&
      _runtime.isCurrent(_birth) &&
      _generation != null &&
      _database.isCurrent(_generation!);

  int? _daily, _new;
  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.paused ? null : _runtime.capture();
    try {
      _generation = _database.captureGeneration();
    } on DatabaseAccessException {
      _generation = null;
    }

    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _limits(int daily, int fresh) {
    if (!_current) return;
    setState(() {
      _daily = daily;
      _new = fresh.clamp(0, daily);
    });
    unawaited(
      ref
          .read(workspaceDraftsProvider.notifier)
          .put('learningPreferences', {'daily': daily, 'new': _new})
          .catchError((Object _) {
            if (mounted) {
              InlineFeedback.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    AppLocalizations.of(context).get('draftSaveFailed'),
                  ),
                ),
              );
            }
          }),
    );
  }

  Future<void> _grade(
    LearningItem item,
    int grade,
    int daily,
    int fresh,
  ) async {
    if (_saving || !_current) return;
    setState(() => _saving = true);
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .gradeWord(
            item.task,
            item.key,
            grade,
            dailyLimit: daily,
            newLimit: fresh,
            intervals:
                (ref.read(workspaceDraftsProvider)['learningIntervals']
                        as List?)
                    ?.cast<int>() ??
                const [1, 2, 4, 7, 15],
            generation: _generation,
          );
      if (mounted && result.nativeSyncFailures > 0) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('reminderNativeSyncFailed'),
            ),
            action: notificationRepairAction(context),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).get('reminderUpdateFailed'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final preferences = ref.watch(
      workspaceDraftsProvider.select((s) => s['learningPreferences']),
    );
    final stored = preferences is Map ? preferences : const {};
    final daily =
        _daily ??
        (const [5, 10, 20, 40].contains(stored['daily'])
            ? stored['daily'] as int
            : 20);
    final fresh = (_new ?? (stored['new'] is int ? stored['new'] as int : 10))
        .clamp(0, daily);
    LearningSnapshot? snapshot;
    try {
      snapshot = LearningQueueService.queue(
        ref.watch(remindersProvider),
        dailyLimit: daily,
        newLimit: fresh,
      );
    } on FormatException {
      snapshot = null;
    }
    final item = snapshot?.items.firstOrNull;
    return WorkspaceToolFrame(
      title: loc.get('learningQueueTitle'),
      icon: Icons.auto_stories_outlined,
      onClose: widget.onClose,
      canClose: !_saving,
      embedded: widget.embedded,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(loc.get('learningBudgetHint')),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loc.get('learningDailyLimit')),
                    DropdownButton<int>(
                      key: const ValueKey('learning-daily-limit'),
                      value: daily,
                      items: [
                        for (final limit in [5, 10, 20, 40])
                          DropdownMenuItem(value: limit, child: Text('$limit')),
                      ],
                      onChanged: _saving
                          ? null
                          : (limit) {
                              if (limit != null) _limits(limit, fresh);
                            },
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loc.get('learningNewLimit')),
                    DropdownButton<int>(
                      key: const ValueKey('learning-new-limit'),
                      value: fresh,
                      items: [
                        for (final limit in {
                          0,
                          5,
                          10,
                          20,
                          fresh,
                        }.where((n) => n <= daily).toList()..sort())
                          DropdownMenuItem(value: limit, child: Text('$limit')),
                      ],
                      onChanged: _saving
                          ? null
                          : (limit) {
                              if (limit != null) _limits(daily, limit);
                            },
                    ),
                  ],
                ),
              ],
            ),
            if (snapshot == null)
              Text(loc.get('learningProgressInvalid'))
            else ...[
              Text(
                '${loc.get('learningCompleted')}: ${snapshot.completedToday} / $daily',
              ),
              Text(
                '${loc.get('learningQueued')}: ${snapshot.items.length} · ${loc.get('learningDeferred')}: ${snapshot.deferred}',
              ),
              const SizedBox(height: 12),
              if (item == null)
                Text(
                  loc.get(
                    snapshot.dueCount > 0
                        ? 'learningLimitReached'
                        : 'noReviewsToday',
                  ),
                )
              else ...[
                Text(
                  item.task.taskTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (item.progress != null)
                  Text(
                    '${loc.get('learningMastery')}: ${item.progress!.level} / 5 · ${formatLocalDateTime(item.progress!.due)}',
                  ),
                const SizedBox(height: 12),
                VocabularyDeck(
                  key: ValueKey(item.key),
                  content: item.word.toNotes(),
                  practice: true,
                  individualFeedback: true,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final grade in [0, 1, 2])
                      FilledButton.tonal(
                        key: ValueKey('word-grade-$grade'),
                        onPressed: _saving
                            ? null
                            : () => _grade(item, grade, daily, fresh),
                        child: Text(
                          loc.get(
                            const [
                              'wordUnknown',
                              'wordFuzzy',
                              'wordKnown',
                            ][grade],
                          ),
                        ),
                      ),
                  ],
                ),
                if (_saving) const LinearProgressIndicator(),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
