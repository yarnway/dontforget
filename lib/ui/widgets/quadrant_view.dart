import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';
import 'task_card.dart';

class QuadrantView extends ConsumerWidget {
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

  IconData _getEmptyStateIcon() {
    switch (level) {
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
    switch (level) {
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
    switch (level) {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final tasks = allReminders.where((r) => r.quadrantLevel == level).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Subtle wireframe container styling
    final Color outlineColor = bgColor.withValues(alpha: isDark ? 0.45 : 0.7);
    final Color surfaceColor = isDark
        ? Colors.black.withValues(alpha: 0.25)
        : Colors.white.withValues(alpha: 0.5);

    return DragTarget<Reminder>(
      onAcceptWithDetails: (details) {
        final task = details.data;
        if (task.quadrantLevel != level) {
          ref.read(remindersProvider.notifier).updateReminder(task.copyWith(quadrantLevel: level));
        }
      },
      builder: (context, candidateData, rejectedData) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: candidateData.isNotEmpty ? surfaceColor.withValues(alpha: 0.8) : surfaceColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: candidateData.isNotEmpty ? bgColor : outlineColor,
              width: candidateData.isNotEmpty ? 1.5 : 1.0,
            ),
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
                    titleIcon,
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
                      : ListView.builder(
                          key: const ValueKey('list'),
                          physics: const BouncingScrollPhysics(),
                          itemCount: tasks.length,
                          itemBuilder: (context, index) {
                            final task = tasks[index];
                            return Draggable<Reminder>(
                              data: task,
                              feedback: Material(
                                elevation: 8,
                                borderRadius: BorderRadius.circular(6),
                                color: Colors.transparent,
                                child: SizedBox(
                                  width: 250,
                                  child: TaskCard(task: task, onPlayMedia: () {}),
                                ),
                              ),
                              childWhenDragging: Opacity(
                                opacity: 0.25,
                                child: TaskCard(
                                  task: task,
                                  onPlayMedia: () => onPlayMedia(task.recordId ?? ''),
                                ),
                              ),
                              child: TaskCard(
                                task: task,
                                onPlayMedia: () => onPlayMedia(task.recordId ?? ''),
                              ),
                            );
                          },
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
