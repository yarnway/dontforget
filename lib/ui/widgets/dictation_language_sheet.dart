import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/dictation_strings.dart';
import '../../services/live_dictation_service.dart';

Future<void> showDictationLanguages(
  BuildContext context,
  LiveDictationService service,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _LanguageSheet(service),
);

class _LanguageSheet extends StatefulWidget {
  const _LanguageSheet(this.service);
  final LiveDictationService service;
  @override
  State<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<_LanguageSheet> {
  String? _locale, _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final status = await widget.service.availability();
      if (mounted) {
        setState(() {
          _locale = status.locale;
          if (!status.available) _error = 'dictation_unavailable';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'dictation_unavailable');
    }
  }

  Future<void> _choose(String locale) async {
    setState(() => _busy = true);
    try {
      await widget.service.setLanguage(locale);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'dictation_unavailable';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dictationText(loc, 'title'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(dictationText(loc, 'privacy')),
              for (final entry in const {
                'zh-CN': '中文（普通话）',
                'en-US': 'English (US)',
              }.entries)
                ListTile(
                  key: ValueKey('dictation-language-${entry.key}'),
                  leading: Icon(
                    _locale == entry.key
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(entry.value),
                  selected: _locale == entry.key,
                  enabled: !_busy && _locale != null && !widget.service.active,
                  onTap: () => _choose(entry.key),
                ),
              if (_error != null)
                Text(
                  dictationText(loc, _error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              TextButton.icon(
                icon: const Icon(Icons.settings_voice),
                label: Text(dictationText(loc, 'system')),
                onPressed: _busy
                    ? null
                    : () async {
                        try {
                          await widget.service.openSettings();
                        } catch (_) {
                          if (mounted) {
                            setState(() => _error = 'dictation_unavailable');
                          }
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
