import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';

/// Keeps a deleted link visible for Undo without exposing its storage ID.
class LinkedTaskTile extends StatelessWidget {
  const LinkedTaskTile({
    super.key,
    required this.task,
    required this.categoryColor,
    required this.onOpen,
    required this.onUnlink,
  });

  final Reminder? task;
  final Color categoryColor;
  final VoidCallback? onOpen;
  final VoidCallback? onUnlink;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final title = task?.taskTitle ?? l10n.get('linkedTaskUnavailable');
    final color = task == null ? colors.onSurfaceVariant : categoryColor;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: task == null ? null : onOpen,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                alignment: Alignment.centerLeft,
                foregroundColor: colors.onSurface,
                disabledForegroundColor: colors.onSurfaceVariant,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Row(
                children: [
                  if (task == null)
                    Icon(Icons.link_off, size: 18, color: color)
                  else
                    Text(
                      'Q${task!.quadrantLevel}',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onUnlink,
            tooltip: l10n.get('removeTaskLink').replaceAll('{task}', title),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.link_off, size: 20),
          ),
        ],
      ),
    );
  }
}
