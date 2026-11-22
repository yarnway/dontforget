import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Shows the 4-quadrant category picker dialog and returns the selected level
/// (1..4) or `null` when dismissed.
Future<int?> showTaskCategoryPickerDialog(
  BuildContext context, {
  required int currentLevel,
}) {
  final l10n = AppLocalizations.of(context);
  final colors = Theme.of(context).colorScheme;
  final brightness = Theme.of(context).brightness;
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      key: const ValueKey('task-move-category-dialog'),
      title: Text(l10n.get('moveCategory')),
      children: [
        for (var level = 1; level <= 4; level++)
          SimpleDialogOption(
            key: ValueKey('task-move-category-$level'),
            onPressed: () => Navigator.pop(dialogContext, level),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: currentLevel == level
                    ? colors.primaryContainer.withValues(alpha: 0.38)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppTheme.quadrantColor(
                        brightness,
                        level,
                      ).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      AppTheme.quadrantIcon(level),
                      size: 18,
                      color: AppTheme.quadrantColor(brightness, level),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.get('cat$level'),
                      style: TextStyle(
                        fontWeight: currentLevel == level
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (currentLevel == level)
                    Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: colors.primary,
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
