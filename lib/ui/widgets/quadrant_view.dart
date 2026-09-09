import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
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

  String _getEmptyStateText() {
    switch (level) {
      case 1:
        return '暂无火急事务';
      case 2:
        return '暂无重点规划';
      case 3:
        return '暂无突发杂事';
      case 4:
      default:
        return '一身轻松，无琐事';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = allReminders.where((r) => r.quadrantLevel == level).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final finalBgColor = isDark ? bgColor.withOpacity(0.05) : bgColor.withOpacity(0.4);

    return DragTarget<Reminder>(
      onAcceptWithDetails: (details) {
        final task = details.data;
        if (task.quadrantLevel != level) {
          ref.read(remindersProvider.notifier).updateReminder(task.copyWith(quadrantLevel: level));
        }
      },
      builder: (context, candidateData, rejectedData) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: candidateData.isNotEmpty ? finalBgColor.withOpacity(0.8) : finalBgColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
                boxShadow: candidateData.isNotEmpty 
                    ? [BoxShadow(color: finalBgColor, blurRadius: 10, spreadRadius: 2)] 
                    : [],
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: titleIcon,
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: tasks.isEmpty
                          ? Center(
                              key: const ValueKey('empty'),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(_getEmptyStateIcon(), size: 42, color: Colors.grey.withOpacity(0.4)),
                                  const SizedBox(height: 8),
                                  Text(
                                    _getEmptyStateText(),
                                    style: TextStyle(color: Colors.grey.withOpacity(0.6), fontSize: 12, fontWeight: FontWeight.w500),
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
                                    elevation: 12,
                                    borderRadius: BorderRadius.circular(16),
                                    color: Colors.transparent,
                                    child: SizedBox(
                                      width: 260,
                                      child: TaskCard(task: task, onPlayMedia: () {}),
                                    ),
                                  ),
                                  childWhenDragging: Opacity(
                                    opacity: 0.3,
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
            ),
          ),
        );
      },
    );
  }
}
