import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/global_capture_strings.dart';
import '../../providers/global_capture_provider.dart';

class GlobalCaptureShortcutPanel extends ConsumerWidget {
  const GlobalCaptureShortcutPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(globalCaptureShortcutProvider);
    String t(String key) => globalCaptureText(
      AppLocalizations.of(context).locale.languageCode,
      key,
    );
    return Card.outlined(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('global-capture-enabled'),
            title: Text(t('title')),
            subtitle: const Text('Ctrl + Alt + Space'),
            value: service.enabled,
            onChanged: !service.ready || service.busy
                ? null
                : (value) => unawaited(service.setEnabled(value)),
          ),
          if (service.busy) const LinearProgressIndicator(),
          if (service.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      t(service.error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: !service.ready || service.busy
                        ? null
                        : () => unawaited(service.setEnabled(true)),
                    child: Text(t('retry')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
