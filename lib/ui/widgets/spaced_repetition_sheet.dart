import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/recovery/runtime_gate.dart';
import '../../services/spaced_repetition_service.dart';
import '../../l10n/app_localizations.dart';
import '../formatters/local_date_time.dart';
import 'inline_feedback.dart';

class SpacedRepetitionSheet extends ConsumerStatefulWidget {
  const SpacedRepetitionSheet({super.key});
  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const SpacedRepetitionSheet(),
  );
  @override
  ConsumerState<SpacedRepetitionSheet> createState() =>
      _SpacedRepetitionSheetState();
}

class _SpacedRepetitionSheetState extends ConsumerState<SpacedRepetitionSheet>
    with WidgetsBindingObserver {
  bool _isFlipped = false, _isSaving = false;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken? _birth;
  final _queue = ReviewQueueCache();
  List<Reminder> _due = [];
  int _total = 0;
  String? _shownId;
  Timer? _dayTimer;

  @override
  void initState() {
    super.initState();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.paused ? null : _runtime.capture();
    WidgetsBinding.instance.addObserver(this);
    _armDayRefresh();
  }

  bool get _isCurrent => mounted && _runtime.isCurrent(_birth);
  void _armDayRefresh() {
    _dayTimer?.cancel();
    final now = DateTime.now();
    _dayTimer = Timer(
      DateTime(now.year, now.month, now.day + 1).difference(now),
      () {
        if (!_isCurrent) return;
        setState(_queue.invalidate);
        _armDayRefresh();
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isCurrent) {
      setState(_queue.invalidate);
      _armDayRefresh();
    }
  }

  @override
  void dispose() {
    _dayTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refresh(List<Reminder> tasks, SpacedRepetitionService service) {
    final snapshot = _queue.read(tasks, service);
    _total = snapshot.total;
    _due = snapshot.due;
    final id = _due.firstOrNull?.id;
    if (_shownId != id) _isFlipped = false;
    _shownId = id;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    _refresh(
      ref.watch(remindersProvider),
      ref.watch(spacedRepetitionServiceProvider),
    );
    final task = _due.firstOrNull;
    return SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.85,
            child: Material(
              color: colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              clipBehavior: Clip.antiAlias,
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.3,
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                          child: Row(
                            children: [
                              const Icon(Icons.school_outlined),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  loc.get('spacedRepetitionTitle'),
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              IconButton(
                                tooltip: loc.get('close'),
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: task == null
                            ? Column(
                                children: [
                                  const SizedBox(height: 16),
                                  Icon(
                                    Icons.school_outlined,
                                    size: 48,
                                    color: colors.primary,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    loc.get(
                                      _total == 0
                                          ? 'reviewNoCards'
                                          : 'noReviewsToday',
                                    ),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    loc.get(
                                      _total == 0
                                          ? 'reviewCreateHint'
                                          : 'reviewReturnHint',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 8,
                                    children: [
                                      Text(
                                        '${loc.get('reviewToday')}: ${_due.length}',
                                      ),
                                      Text(
                                        '${loc.get('reviewCardCount')}: $_total',
                                      ),
                                      Text(
                                        '${loc.get('stageLevel')}${task.spacedRepetitionLevel} / 5',
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colors.surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: colors.outlineVariant,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Text(
                                            'Q${task.quadrantLevel}',
                                            style: TextStyle(
                                              color: colors.primary,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            task.taskTitle,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleLarge,
                                          ),
                                          const SizedBox(height: 20),
                                          TextButton.icon(
                                            key: const ValueKey('review-flip'),
                                            onPressed: _isSaving
                                                ? null
                                                : () => setState(
                                                    () => _isFlipped =
                                                        !_isFlipped,
                                                  ),
                                            icon: Icon(
                                              _isFlipped
                                                  ? Icons
                                                        .visibility_off_outlined
                                                  : Icons.visibility_outlined,
                                            ),
                                            label: Text(
                                              loc.get(
                                                _isFlipped
                                                    ? 'reviewHideAnswer'
                                                    : 'flipCard',
                                              ),
                                            ),
                                          ),
                                          if (_isFlipped) ...[
                                            const Divider(height: 24),
                                            Text(
                                              loc.get('reviewNotes'),
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleSmall,
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              task.taskSummary
                                                          ?.trim()
                                                          .isNotEmpty ==
                                                      true
                                                  ? task.taskSummary!
                                                  : loc.get('reviewNoNotes'),
                                            ),
                                            if (task
                                                .subTasksView
                                                .isNotEmpty) ...[
                                              const SizedBox(height: 16),
                                              Text(
                                                loc.get('reviewSteps'),
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleSmall,
                                              ),
                                              for (final step
                                                  in task.subTasksView)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 6,
                                                      ),
                                                  child: Text('• $step'),
                                                ),
                                            ],
                                            const SizedBox(height: 16),
                                            Text(
                                              '${loc.get('triggerTimeLabel')}: ${task.triggerTime == null ? loc.get('notSet') : formatLocalDateTime(task.triggerTime!)}',
                                              style: TextStyle(
                                                color: colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                    if (task != null)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight * 0.4,
                        ),
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_isSaving) ...[
                                  const LinearProgressIndicator(),
                                  const SizedBox(height: 8),
                                  Text(loc.get('reviewSaving')),
                                ],
                                LayoutBuilder(
                                  builder: (context, size) {
                                    final buttons = [
                                      OutlinedButton.icon(
                                        onPressed: _isSaving || !_isCurrent
                                            ? null
                                            : () => _handleReviewResult(
                                                task,
                                                false,
                                              ),
                                        icon: const Icon(Icons.refresh),
                                        label: Text(loc.get('markDifficult')),
                                      ),
                                      ElevatedButton.icon(
                                        onPressed: _isSaving || !_isCurrent
                                            ? null
                                            : () => _handleReviewResult(
                                                task,
                                                true,
                                              ),
                                        icon: const Icon(Icons.check),
                                        label: Text(loc.get('markRemembered')),
                                      ),
                                    ];
                                    return size.maxWidth >= 580 &&
                                            MediaQuery.textScalerOf(
                                                  context,
                                                ).scale(1) <=
                                                1.3
                                        ? Row(
                                            children: [
                                              Expanded(child: buttons[0]),
                                              const SizedBox(width: 12),
                                              Expanded(child: buttons[1]),
                                            ],
                                          )
                                        : Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              buttons[0],
                                              const SizedBox(height: 8),
                                              buttons[1],
                                            ],
                                          );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleReviewResult(Reminder task, bool remembered) async {
    if (!_isCurrent || _isSaving) return;
    // A stale callback must not grade a removed, disabled, or already-reviewed card.
    final current = ref
        .read(remindersProvider)
        .where((r) => r.id == task.id)
        .firstOrNull;
    final service = ref.read(spacedRepetitionServiceProvider);
    if (current == null || !service.isDue(current)) return;
    setState(() => _isSaving = true);
    final loc = AppLocalizations.of(context);
    try {
      final update = service.reviewCard(current, remembered);
      final result = await ref
          .read(remindersProvider.notifier)
          .updateReminder(update, baseline: current);
      if (!mounted || !_isCurrent) return;
      final saved = result.reminder ?? update;
      setState(() => _isFlipped = false);
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${loc.get('reviewSaved')} ${loc.get('stageLevel')}${saved.spacedRepetitionLevel} · ${loc.get('reviewNext')}: ${formatLocalDateTime(saved.nextReviewAt!)}'
            '${result.nativeSyncFailed ? '\n${loc.get('reminderNativeSyncFailed')}' : ''}',
          ),
        ),
      );
    } catch (_) {
      if (mounted && _isCurrent) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(loc.get('reminderUpdateFailed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
