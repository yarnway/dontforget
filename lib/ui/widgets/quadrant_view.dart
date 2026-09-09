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
  final void Function(String recordId) onPlayMedia;

  const QuadrantView({
    super.key,
    required this.level,
    required this.titleIcon,
    required this.allReminders,
    required this.bgColor,
    required this.onPlayMedia,
  });

  @override
  ConsumerState<QuadrantView> createState() => _QuadrantViewState();
}

class _QuadrantViewState extends ConsumerState<QuadrantView> {
  bool _isQ4FoldExpanded = false;

  IconData _getEmptyStateIcon() {
    switch (widget.level) {
      case 1:
        return Icons.local_fire_department_outlined;
      case 2:
        return Icons.star_outline_rounded;
      case 3:
        return Icons.bolt_outlined;
      case 4:
      default:
        return Icons.coffee_outlined;
    }
  }

  String _getEmptyStateText(AppLocalizations l10n) {
    switch (widget.level) {
      case 1:
        return l10n.get('emptyQ1');
      case 2:
        return l10n.get('emptyQ2');
      case 3:
        return l10n.get('emptyQ3');
      case 4:
      default:
        return l10n.get('emptyQ4');
    }
  }

  String _getLevelTitle(AppLocalizations l10n) {
    switch (widget.level) {
      case 1:
        return l10n.get('cat1');
      case 2:
        return l10n.get('cat2');
      case 3:
        return l10n.get('cat3');
      case 4:
      default:
        return l10n.get('cat4');
    }
  }

  Widget _buildDraggableCard(Reminder task) {
    return LongPressDraggable<Reminder>(
      data: task,
      delay: const Duration(milliseconds: 160),
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tasks = widget.allReminders.where((r) => r.quadrantLevel == widget.level).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Subtle wireframe container styling
    final Color outlineColor = widget.bgColor.withValues(alpha: isDark ? 0.45 : 0.7);
    final Color surfaceColor = isDark
        ? Colors.black.withValues(alpha: 0.25)
        : Colors.white.withValues(alpha: 0.5);

    // Q4 自动折叠逻辑：将停滞超 48 小时的低优先级任务归入可折叠区
    final dynamicService = ref.watch(dynamicUrgencyServiceProvider);
    final List<Reminder> activeTasks;
    final List<Reminder> foldedTasks;

    if (widget.level == 4) {
      activeTasks = tasks.where((t) => !dynamicService.isQ4StagnantFolded(t)).toList();
      foldedTasks = tasks.where((t) => dynamicService.isQ4StagnantFolded(t)).toList();
    } else {
      activeTasks = tasks;
      foldedTasks = const [];
    }

    return DragTarget<Reminder>(
      onAcceptWithDetails: (details) {
        final task = details.data;
        if (task.quadrantLevel != widget.level) {
          ref.read(remindersProvider.notifier).updateReminder(task.copyWith(quadrantLevel: widget.level));
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              content: Text('${l10n.get('movedToQuadrant')}${_getLevelTitle(l10n)}: ${task.taskTitle}'),
            ),
          );
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isHovered
                ? widget.bgColor.withValues(alpha: isDark ? 0.22 : 0.12)
                : surfaceColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isHovered ? widget.bgColor : outlineColor,
              width: isHovered ? 2.0 : 1.0,
            ),
            boxShadow: isHovered
                ? [
                    BoxShadow(
                      color: widget.bgColor.withValues(alpha: 0.3),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : [],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header bar with minimal title icon and professional reminder term
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 2, bottom: 6),
                child: Row(
                  children: [
                    widget.titleIcon,
                    const SizedBox(width: 6),
                    Text(
                      _getLevelTitle(l10n),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        color: isDark ? Colors.grey.shade300 : Colors.grey.shade800,
                      ),
                    ),
                  ],
                ),
              ),

              // Tasks information feed
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: tasks.isEmpty
                      ? Center(
                          key: const ValueKey('empty'),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(_getEmptyStateIcon(), size: 32, color: Colors.grey.withValues(alpha: 0.35)),
                              const SizedBox(height: 6),
                              Text(
                                _getEmptyStateText(l10n),
                                style: TextStyle(
                                  color: Colors.grey.withValues(alpha: 0.6),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView(
                          key: const ValueKey('list'),
                          physics: const BouncingScrollPhysics(),
                          children: [
                            // 活跃待办列表
                            for (final task in activeTasks)
                              _buildDraggableCard(task),

                            // Q4 长期停滞冗余备忘自动折叠面板
                            if (foldedTasks.isNotEmpty) ...[
                              InkWell(
                                onTap: () {
                                  setState(() => _isQ4FoldExpanded = !_isQ4FoldExpanded);
                                },
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.withValues(alpha: isDark ? 0.14 : 0.08),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Colors.grey.withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        _isQ4FoldExpanded
                                            ? Icons.keyboard_arrow_down
                                            : Icons.keyboard_arrow_right,
                                        size: 16,
                                        color: Colors.grey.shade500,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          '${l10n.get('autoCollapsedNotice')} (${foldedTasks.length})',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey.shade500,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (_isQ4FoldExpanded)
                                for (final task in foldedTasks)
                                  _buildDraggableCard(task),
                            ],
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

