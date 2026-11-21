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
    this.activeView,
    this.missedReminders,
  });
  final List<Reminder> reminders;
  final ValueChanged<String> onPlayMedia;
  final VoidCallback? onOpenLearning;
  final String? activeView;
  // Home supplies the same selection used by its missed-reminder banner.
  final List<Reminder>? missedReminders;
  @override
  ConsumerState<TaskWorkspaceOverview> createState() =>
      _TaskWorkspaceOverviewState();
}

class _TaskWorkspaceOverviewState extends ConsumerState<TaskWorkspaceOverview>
    with WidgetsBindingObserver {
  Timer? _timer;
  String? _selected;
  bool _showCompleted = false;
  int _refreshRevision = 0;
  List<Reminder>? _cachedReminders;
  List<Reminder>? _cachedMissedProp;
  String? _cachedView;
  bool? _cachedShowCompleted;
  int? _cachedMinuteBucket;
  int? _cachedRefreshRevision;
  List<Reminder> _cachedMissedTasks = const [];
  List<Reminder> _cachedCompleted = const [];
  List<Object> _cachedRows = const [];
  Map<String, int> _cachedRowIndexByTaskId = const {};
  int _cachedCompletedCount = 0;

  void _ensureProjected(String view, DateTime now) {
    final minuteBucket = now.millisecondsSinceEpoch ~/ 60000;
    if (identical(_cachedReminders, widget.reminders) &&
        identical(_cachedMissedProp, widget.missedReminders) &&
        _cachedView == view &&
        _cachedShowCompleted == _showCompleted &&
        _cachedMinuteBucket == minuteBucket &&
        _cachedRefreshRevision == _refreshRevision) {
      return;
    }
    final missedTasks =
        (widget.missedReminders ?? selectMissedReminders(widget.reminders, now))
            .where((r) => r.isWorkspaceItem)
            .toList();
    final todayStart = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final rows = <Object>[];
    final completedList = <Reminder>[];
    final tasks = <Reminder>[];
    var completedCount = 0;
    for (final r in widget.reminders) {
      if (r.isCompleted) {
        completedCount++;
        if (view == 'all' && _showCompleted && r.isWorkspaceItem) {
          completedList.add(r);
        }
      } else if (r.isWorkspaceItem) {
        tasks.add(r);
      }
    }
    final completed = view == 'all' && _showCompleted
        ? completedList
        : const <Reminder>[];
    tasks.sort((a, b) {
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
                      task.createdAt?.isBefore(todayStart) == false))
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
        if (group.value.isNotEmpty) {
          rows.addAll([
            (key: group.key, count: group.value.length),
            ...group.value,
          ]);
        }
      }
    } else if (view == 'missed') {
      rows.addAll(missedTasks);
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
    final rowIndexByTaskId = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is Reminder) {
        rowIndexByTaskId[row.id] = i;
      }
    }
    _cachedReminders = widget.reminders;
    _cachedMissedProp = widget.missedReminders;
    _cachedView = view;
    _cachedShowCompleted = _showCompleted;
    _cachedMinuteBucket = minuteBucket;
    _cachedRefreshRevision = _refreshRevision;
    _cachedMissedTasks = missedTasks;
    _cachedCompleted = completed;
    _cachedRows = rows;
    _cachedRowIndexByTaskId = rowIndexByTaskId;
    _cachedCompletedCount = completedCount;
  }
  @override
  void initState() {
    super.initState();
    if (widget.activeView != null) {
      _selected = widget.activeView;
    }
    WidgetsBinding.instance.addObserver(this);
    _startClock();
  }

  @override
  void didUpdateWidget(TaskWorkspaceOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeView != null &&
        widget.activeView != oldWidget.activeView) {
      _selected = widget.activeView;
    }
  }

  void _startClock() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _refreshRevision++);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _refreshRevision++);
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
        (const ['today', 'future', 'all', 'board', 'missed'].contains(stored)
            ? stored as String
            : 'today');
    final now = DateTime.now();
    _ensureProjected(view, now);
    final missedTasks = _cachedMissedTasks;
    final rows = _cachedRows;
    final completed = _cachedCompleted;
    final missedCount = missedTasks.length;
    final choices = <String, String>{
      'today': 'viewToday',
      'future': 'viewFuture',
      'all': 'viewAll',
      'board': 'viewBoard',
      if (missedCount > 0 || view == 'missed') 'missed': 'viewMissed',
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 96) return const SizedBox.shrink();
        return Column(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      children: [
                        for (final entry in choices.entries)
                          ChoiceChip(
                            key: ValueKey('workspace-view-${entry.key}'),
                            label: Text(
                              entry.key == 'missed'
                                  ? '${loc.get(entry.value)} · $missedCount'
                                  : loc.get(entry.value),
                            ),
                            selected: view == entry.key,
                            onSelected: (_) => _select(entry.key),
                          ),
                      ],
                    ),
                  ),
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
                        constraints: const BoxConstraints(maxWidth: 1040),
                        child: rows.isEmpty && view != 'all'
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 56,
                                        height: 56,
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primaryContainer
                                              .withValues(alpha: 0.65),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          view == 'today'
                                              ? Icons.wb_sunny_outlined
                                              : view == 'missed'
                                              ? Icons.notifications_none_rounded
                                              : Icons.event_available_outlined,
                                          size: 28,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onPrimaryContainer,
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      Text(
                                        loc.get(
                                          view == 'today'
                                              ? 'todayEmpty'
                                              : view == 'missed'
                                              ? 'emptyMissed'
                                              : 'futureEmpty',
                                        ),
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                              height: 1.5,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextButton(
                                        onPressed: () => _select('all'),
                                        child: Text(loc.get('viewAll')),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : CustomScrollView(
                                key: ValueKey('workspace-$view'),
                                slivers: [
                                  SliverPadding(
                                    padding: const EdgeInsets.all(12),
                                    sliver: SliverList(
                                      delegate: SliverChildBuilderDelegate((
                                        context,
                                        index,
                                      ) {
                                        final row = rows[index];
                                        if (row
                                            is ({String key, int count})) {
                                          if (row.key == 'todayReview' &&
                                              widget.onOpenLearning != null) {
                                            return TextButton.icon(
                                              onPressed: widget.onOpenLearning,
                                              icon: const Icon(
                                                Icons.auto_stories_outlined,
                                              ),
                                              label: Text(
                                                '${loc.get('learningQueueTitle')} (${row.count})',
                                              ),
                                            );
                                          }
                                          final colors = Theme.of(
                                            context,
                                          ).colorScheme;
                                          final (icon, accent) =
                                              switch (row.key) {
                                                'todayUrgent' => (
                                                  Icons
                                                      .notifications_active_outlined,
                                                  colors.error,
                                                ),
                                                'todayPinned' => (
                                                  Icons.push_pin_outlined,
                                                  colors.primary,
                                                ),
                                                'todayOverdue' => (
                                                  Icons.schedule_rounded,
                                                  colors.error,
                                                ),
                                                'captureInbox' => (
                                                  Icons.inbox_outlined,
                                                  colors.tertiary,
                                                ),
                                                _ => (
                                                  Icons.today_outlined,
                                                  colors.primary,
                                                ),
                                              };
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              top: 12,
                                              bottom: 8,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  icon,
                                                  size: 16,
                                                  color: accent,
                                                ),
                                                const SizedBox(width: 6),
                                                Flexible(
                                                  child: Text(
                                                    loc.get(row.key),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleSmall
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 7,
                                                        vertical: 1,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: colors
                                                        .surfaceContainer,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '${row.count}',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                          color: colors
                                                              .onSurfaceVariant,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                ),
                                              ],
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
                                      },
                                      childCount: rows.length,
                                      findChildIndexCallback: (key) =>
                                          key is ValueKey<String>
                                          ? _cachedRowIndexByTaskId[key.value]
                                          : null,
                                    ),
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
                                          '${loc.get('completed')} · $_cachedCompletedCount',
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
