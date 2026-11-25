import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

Future<String?> showPendingCaptureDialog(
  BuildContext context,
  String draftText,
) {
  final l10n = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.get('failedInputTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.get('failedInputHint')),
            const SizedBox(height: 12),
            SelectableText(draftText),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'discard'),
          child: Text(l10n.get('failedInputDiscard')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, 'copy'),
          child: Text(l10n.get('failedInputCopy')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, 'restore'),
          child: Text(l10n.get('failedInputRestore')),
        ),
      ],
    ),
  );
}
