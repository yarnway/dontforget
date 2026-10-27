import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../providers/workspace_drafts_provider.dart';
import 'inline_feedback.dart';
import 'task_board.dart';
import 'task_card.dart';

/// Daily work and the existing priority board share the same persisted tasks.
class TaskWorkspaceOverview extends ConsumerStatefulWidget {
  const TaskWorkspaceOverview({
    super.key,
    required this.reminders,
    required this.onPlayMedia,
    this.onOpenLearning,
  });
  final List<Reminder> reminders;
  final ValueChanged<String> onPlayMedia;
  final VoidCallback? onOpenLearning;
  @override
  ConsumerState<TaskWorkspaceOverview> createState() =>
      _TaskWorkspaceOverviewState();
}

class _TaskWorkspaceOverviewState extends ConsumerState<TaskWorkspaceOverview>
    with WidgetsBindingObserver {
  Timer? _timer;
  String? _selected;
  bool _showCompleted = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startClock();
  }

  void _startClock() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() {});
      _startClock();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _select(String value) {
    setState(() => _selected = value);
    unawaited(
      ref
          .read(workspaceDraftsProvider.notifier)
          .put('homeView', value)
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

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final stored = ref.watch(
      workspaceDraftsProvider.select((drafts) => drafts['homeView']),
    );
    final view =
        _selected ??
        (const ['today', 'future', 'all', 'board'].contains(stored)
            ? stored as String
            : 'today');
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final rows = <Object>[];
    final completed = view == 'all' && _showCompleted
        ? widget.reminders.where((task) => task.isCompleted).toList()
        : const <Reminder>[];
    final tasks = widget.reminders.where((r) => !r.isCompleted).toList()
      ..sort((a, b) {
        final learning = (a.spacedRepetitionLevel > 0 ? 1 : 0).compareTo(
          b.spacedRepetitionLevel > 0 ? 1 : 0,
        );
        if (learning != 0) return learning;
        if ((a.quadrantLevel == 1) != (b.quadrantLevel == 1)) {
          return a.quadrantLevel == 1 ? -1 : 1;
        }
        final at = a.eventTime ?? a.triggerTime ?? a.nextReviewAt;
        final bt = b.eventTime ?? b.triggerTime ?? b.nextReviewAt;
        if (at == null) return bt == null ? a.id.compareTo(b.id) : 1;
        if (bt == null) return -1;
        return at.compareTo(bt);
      });
    if (view == 'today') {
      final groups = <String, List<Reminder>>{
        'todayUrgent': [],
        'todayPinned': [],
        'todayOverdue': [],
        'todayTasks': [],
        'captureInbox': [],
        'todayReview': [],
      };
      for (final task in tasks) {
        final deadline = task.eventTime;
        final reminder = task.triggerTime;
        final time = deadline ?? reminder;
        final review =
            task.spacedRepetitionLevel > 0 &&
            (task.nextReviewAt == null ||
                task.nextReviewAt!.isBefore(tomorrow));
        final group = task.spacedRepetitionLevel > 0
            ? (review ? 'todayReview' : null)
            : (task.capturePending ||
                  task.captureProposalJson != null ||
                  (task.triggerTime == null &&
                      task.sourceText != null &&
                      task.createdAt?.isBefore(
                            DateTime(now.year, now.month, now.day),
                          ) ==
                          false))
            ? 'captureInbox'
            : task.quadrantLevel == 1 &&
                  (task.isPinned || (time?.isBefore(tomorrow) ?? false))
            ? 'todayUrgent'
            : task.isPinned
            ? 'todayPinned'
            : deadline != null && deadline.isBefore(now)
            ? 'todayOverdue'
            : (deadline != null && deadline.isBefore(tomorrow)) ||
                  (reminder != null && reminder.isBefore(tomorrow))
            ? 'todayTasks'
            : null;
        if (group != null) groups[group]!.add(task);
      }
      for (final group in groups.entries) {
        if (group.value.isNotEmpty) rows.addAll([group.key, ...group.value]);
      }
    } else if (view != 'board') {
      rows.addAll(
        tasks.where(
          (task) =>
              view == 'all' ||
              (task.eventTime ?? task.triggerTime ?? task.nextReviewAt)
                      ?.isBefore(tomorrow) ==
                  false,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 96) return const SizedBox.shrink();
        return Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    for (final entry in const {
                      'today': 'viewToday',
                      'future': 'viewFuture',
                      'all': 'viewAll',
                      'board': 'viewBoard',
                    }.entries)
                      ChoiceChip(
                        key: ValueKey('workspace-view-${entry.key}'),
                        label: Text(loc.get(entry.value)),
                        selected: view == entry.key,
                        onSelected: (_) => _select(entry.key),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: view == 'board'
                  ? TaskBoard(
                      reminders: widget.reminders,
                      onPlayMedia: widget.onPlayMedia,
                    )
                  : Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 960),
                        child: rows.isEmpty && view != 'all'
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      loc.get(
                                        view == 'today'
                                            ? 'todayEmpty'
                                            : 'futureEmpty',
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => _select('all'),
                                      child: Text(loc.get('viewAll')),
                                    ),
                                  ],
                                ),
                              )
                            : CustomScrollView(
                                key: ValueKey('workspace-$view'),
                                slivers: [
                                  SliverPadding(
                                    padding: const EdgeInsets.all(16),
                                    sliver: SliverList(
                                      delegate: SliverChildBuilderDelegate((
                                        context,
                                        index,
                                      ) {
                                        final row = rows[index];
                                        if (row is String) {
                                          if (row == 'todayReview' &&
                                              widget.onOpenLearning != null) {
                                            return TextButton.icon(
                                              onPressed: widget.onOpenLearning,
                                              icon: const Icon(
                                                Icons.auto_stories_outlined,
                                              ),
                                              label: Text(
                                                loc.get('learningQueueTitle'),
                                              ),
                                            );
                                          }
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              top: 10,
                                              bottom: 10,
                                            ),
                                            child: Text(
                                              loc.get(row),
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleSmall,
                                            ),
                                          );
                                        }
                                        final task = row as Reminder;
                                        return TaskCard(
                                          key: ValueKey(task.id),
                                          task: task,
                                          onPlayMedia: () {
                                            if (task.recordId != null) {
                                              widget.onPlayMedia(
                                                task.recordId!,
                                              );
                                            }
                                          },
                                        );
                                      }, childCount: rows.length),
                                    ),
                                  ),
                                  if (view == 'all')
                                    SliverToBoxAdapter(
                                      child: TextButton.icon(
                                        key: const ValueKey(
                                          'workspace-completed-toggle',
                                        ),
                                        onPressed: () => setState(
                                          () =>
                                              _showCompleted = !_showCompleted,
                                        ),
                                        icon: Icon(
                                          _showCompleted
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                        ),
                                        label: Text(
                                          '${loc.get('completed')} · ${widget.reminders.where((r) => r.isCompleted).length}',
                                        ),
                                      ),
                                    ),
                                  if (view == 'all' && _showCompleted)
                                    SliverPadding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      sliver: SliverList(
                                        delegate: SliverChildBuilderDelegate((
                                          context,
                                          index,
                                        ) {
                                          final task = completed[index];
                                          return TaskCard(
                                            key: ValueKey(task.id),
                                            task: task,
                                            onPlayMedia: () {
                                              if (task.recordId != null) {
                                                widget.onPlayMedia(
                                                  task.recordId!,
                                                );
                                              }
                                            },
                                          );
                                        }, childCount: completed.length),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
