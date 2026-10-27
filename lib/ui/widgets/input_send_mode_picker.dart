import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/settings.dart';

class InputSendModePicker extends StatelessWidget {
  const InputSendModePicker({super.key, required this.value, this.onChanged});
  final InputSendMode value;
  final ValueChanged<InputSendMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.keyboard_return_rounded,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.get('inputSendTitle'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButton<InputSendMode>(
              key: const ValueKey('input-send-mode'),
              value: value,
              isExpanded: true,
              itemHeight: null,
              onChanged: onChanged == null
                  ? null
                  : (mode) {
                      if (mode != null) onChanged!(mode);
                    },
              items: [
                for (final mode in InputSendMode.values)
                  DropdownMenuItem(
                    value: mode,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(l10n.get('inputSend_${mode.name}')),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.get('inputSendHint_${value.name}'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.get('inputSendSaveHint'),
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
