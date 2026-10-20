import 'package:flutter/material.dart';
import '../../models/reminder.dart';
import 'quadrant_view.dart';

/// Give narrow windows readable, full-width cards instead of four tiny panes.
class TaskBoard extends StatelessWidget {
  final List<Reminder> reminders;
  final void Function(String) onPlayMedia;

  const TaskBoard({
    super.key,
    required this.reminders,
    required this.onPlayMedia,
  });

  @override
  Widget build(BuildContext context) {
    const colors = [
      Color(0xFFD56B64),
      Color(0xFFBF944E),
      Color(0xFF648FC5),
      Color(0xFF609C89),
    ];
    const icons = [
      Icons.notifications_active_outlined,
      Icons.star_outline_rounded,
      Icons.checklist_rounded,
      Icons.notes_rounded,
    ];
    final panels = List.generate(
      4,
      (i) => QuadrantView(
        key: ValueKey('quadrant-${i + 1}'),
        level: i + 1,
        titleIcon: Icon(icons[i], size: 20, color: colors[i]),
        allReminders: reminders,
        bgColor: colors[i],
        onPlayMedia: onPlayMedia,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            itemCount: panels.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => SizedBox(height: 300, child: panels[i]),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            children: [
              for (var row = 0; row < 2; row++) ...[
                if (row > 0) const SizedBox(height: 12),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: panels[row * 2]),
                      const SizedBox(width: 12),
                      Expanded(child: panels[row * 2 + 1]),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
