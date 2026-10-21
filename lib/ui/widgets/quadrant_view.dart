import 'inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';
import 'task_card.dart';

class QuadrantView extends ConsumerStatefulWidget {
  final int level;
  final Widget titleIcon;
  final List<Reminder> allReminders;
  final Color bgColor;
  final bool showHeader;
  final void Function(String recordId) onPlayMedia;

  const QuadrantView({
    super.key,
    required this.level,
    required this.titleIcon,
    required this.allReminders,
    required this.bgColor,
    this.showHeader = true,
    required this.onPlayMedia,
  });

  @override
  ConsumerState<QuadrantView> createState() => _QuadrantViewState();
}

class _QuadrantViewState extends ConsumerState<QuadrantView> {
  bool _isQ4FoldExpanded = false;
  bool _completedExpanded = false;
  final _pendingMoves = <String>{};

  IconData _getEmptyStateIcon() => switch (widget.level) {
    1 => Icons.local_fire_department_outlined,
    2 => Icons.star_outline_rounded,
    3 => Icons.bolt_outlined,
    _ => Icons.coffee_outlined,
  };

  String _getLevelTitle(AppLocalizations l10n) =>
      l10n.get('cat${widget.level}');

  Future<void> _moveReminder(Reminder task) async {
    if (task.quadrantLevel == widget.level || !_pendingMoves.add(task.id)) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final title = _getLevelTitle(l10n);
    try {
      await ref
          .read(remindersProvider.notifier)
          .updateReminder(task.copyWith(quadrantLevel: widget.level));
      if (!mounted) return;
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.get('movedToQuadrant')}$title: ${task.taskTitle}',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      InlineFeedback.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.get('reminderUpdateFailed'))));
    } finally {
      _pendingMoves.remove(task.id);
    }
  }

  Widget _buildDraggableCard(Reminder task) {
    return LongPressDraggable<Reminder>(
      key: ValueKey('task-${task.id}'),
      data: task,
      // Keep ordinary clicks on the card's controls out of the drag gesture.
      delay: const Duration(milliseconds: 500),
      feedback: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(8),
        color: Colors.transparent,
        child: SizedBox(
          width: 260,
          child: Opacity(
            opacity: 0.95,
            child: TaskCard(task: task, onPlayMedia: () {}),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.2,
        child: TaskCard(
          task: task,
          onPlayMedia: () => widget.onPlayMedia(task.recordId ?? ''),
        ),
      ),
      child: TaskCard(
        task: task,
        onPlayMedia: () => widget.onPlayMedia(task.recordId ?? ''),
      ),
    );
  }

  Widget _taskList(
    AppLocalizations l10n,
    List<Reminder> active,
    List<Reminder> completed,
    List<Reminder> folded,
  ) {
    // Only lightweight data is flattened. Cards, including expanded completed
    // and stagnant sections, are constructed only for the viewport + cache.
    final rows = <Object>[
      ...active,
      if (completed.isNotEmpty) 'completed',
      if (_completedExpanded) ...completed,
      if (folded.isNotEmpty) 'folded',
      if (_isQ4FoldExpanded) ...folded,
    ];
    final indices = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      indices[row is Reminder ? 'task-${row.id}' : '$row-${widget.level}'] = i;
    }
    return ListView.builder(
      key: PageStorageKey('quadrant-list-${widget.level}'),
      primary: false,
      itemCount: rows.length,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        return indices[key.value];
      },
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row is Reminder) return _buildDraggableCard(row);
        final isCompleted = row == 'completed';
        final expanded = isCompleted ? _completedExpanded : _isQ4FoldExpanded;
        final label = isCompleted
            ? l10n.get('completed')
            : l10n.get('autoCollapsedNotice');
        final count = isCompleted ? completed.length : folded.length;
        return Semantics(
          key: ValueKey('$row-${widget.level}'),
          expanded: expanded,
          child: TextButton.icon(
            onPressed: () => setState(() {
              if (isCompleted) {
                _completedExpanded = !_completedExpanded;
              } else {
                _isQ4FoldExpanded = !_isQ4FoldExpanded;
              }
            }),
            icon: Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
            ),
            label: Text('$label ($count)'),
            style: TextButton.styleFrom(
              animationDuration: Duration.zero,
              foregroundColor: Theme.of(context).colorScheme.primary,
              alignment: Alignment.centerLeft,
              minimumSize: const Size(0, 44),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dynamicService = ref.watch(dynamicUrgencyServiceProvider);
    final active = <Reminder>[];
    final completed = <Reminder>[];
    final folded = <Reminder>[];
    for (final task in widget.allReminders) {
      if (task.quadrantLevel != widget.level) continue;
      if (task.isCompleted) {
        completed.add(task);
      } else if (widget.level == 4 && dynamicService.isQ4StagnantFolded(task)) {
        folded.add(task);
      } else {
        active.add(task);
      }
    }
    final isEmpty = active.isEmpty && completed.isEmpty && folded.isEmpty;
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DragTarget<Reminder>(
      onWillAcceptWithDetails: (details) =>
          details.data.quadrantLevel != widget.level &&
          !_pendingMoves.contains(details.data.id),
      onAcceptWithDetails: (details) => _moveReminder(details.data),
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        // Theme already animates its color pairs together. Animating only this
        // surface again leaves an old background behind the new foreground.
        return Container(
          key: ValueKey('quadrant-surface-${widget.level}'),
          decoration: BoxDecoration(
            color: isHovered
                ? Color.alphaBlend(
                    widget.bgColor.withValues(alpha: isDark ? 0.22 : 0.12),
                    colors.surfaceContainerLow,
                  )
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isHovered
                  ? widget.bgColor
                  : colors.outlineVariant.withValues(alpha: 0.65),
              width: isHovered ? 2.0 : 1.0,
            ),
          ),
          padding: widget.showHeader
              ? const EdgeInsets.all(12)
              : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showHeader)
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 2, bottom: 6),
                  child: Row(
                    children: [
                      widget.titleIcon,
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _getLevelTitle(l10n),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Semantics(
                        label:
                            '${l10n.get('pending')}: ${active.length + folded.length}',
                        excludeSemantics: true,
                        child: Text(
                          '${active.length + folded.length}',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: isEmpty
                    ? Center(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _getEmptyStateIcon(),
                                  size: 32,
                                  color: colors.onSurfaceVariant,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  l10n.get('emptyQ${widget.level}'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : _taskList(l10n, active, completed, folded),
              ),
            ],
          ),
        );
      },
    );
  }
}
