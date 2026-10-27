import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/settings.dart';
import '../theme/app_theme.dart';

class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key, required this.value, this.onChanged});

  final AppAppearance value;
  final ValueChanged<AppAppearance>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.get('appearanceTitle'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final stacked =
                    constraints.maxWidth < 270 ||
                    MediaQuery.textScalerOf(context).scale(14) > 20;
                final choices = AppAppearance.values.map((appearance) {
                  final selected = value == appearance;
                  final icon = switch (appearance) {
                    AppAppearance.system => Icons.brightness_auto_outlined,
                    AppAppearance.light => Icons.light_mode_outlined,
                    AppAppearance.dark => Icons.dark_mode_outlined,
                  };
                  final label = l10n.get('appearance_${appearance.name}');
                  return Semantics(
                    selected: selected,
                    child: OutlinedButton(
                      key: ValueKey('appearance-${appearance.name}'),
                      onPressed: onChanged == null
                          ? null
                          : () => onChanged!(appearance),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(12),
                        foregroundColor: theme.colorScheme.onSurface,
                        backgroundColor: selected
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerLow,
                        side: BorderSide(
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: selected ? 2 : 1,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: stacked
                          ? Row(
                              children: [
                                Icon(icon, size: 20),
                                const SizedBox(width: 12),
                                Expanded(child: Text(label)),
                                if (selected)
                                  Icon(
                                    Icons.check_circle,
                                    size: 20,
                                    color: theme.colorScheme.primary,
                                  ),
                              ],
                            )
                          : Column(
                              children: [
                                ExcludeSemantics(child: _Preview(appearance)),
                                const SizedBox(height: 10),
                                Icon(
                                  selected ? Icons.check_circle : icon,
                                  size: 20,
                                  color: selected
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 6),
                                Text(label, textAlign: TextAlign.center),
                              ],
                            ),
                    ),
                  );
                }).toList();
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < choices.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        choices[i],
                      ],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < choices.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: choices[i]),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Text(
              l10n.get('appearanceSaveHint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview(this.appearance);
  final AppAppearance appearance;

  Widget _half(ColorScheme colors) => Expanded(
    child: ColoredBox(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          children: [
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 5),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Container(height: 5, color: colors.outlineVariant),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: SizedBox(
      height: 58,
      child: Row(
        children: [
          if (appearance != AppAppearance.dark)
            _half(AppTheme.light.colorScheme),
          if (appearance != AppAppearance.light)
            _half(AppTheme.dark.colorScheme),
        ],
      ),
    ),
  );
}
