import 'package:flutter/material.dart';
import '../../l10n/planning_strings.dart';
import '../../models/calendar_exceptions.dart';

class CalendarExceptionsEditor extends StatefulWidget {
  const CalendarExceptionsEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    required this.scopeHint,
    this.raw,
    this.enabled = true,
  });
  final CalendarExceptions initial;
  final Map<String, dynamic>? raw;
  final bool enabled;
  final String scopeHint;
  final void Function(CalendarExceptions?, Map<String, String>) onChanged;
  @override
  State<CalendarExceptionsEditor> createState() =>
      _CalendarExceptionsEditorState();
}

class _CalendarExceptionsEditorState extends State<CalendarExceptionsEditor> {
  late final TextEditingController _skip, _add;
  bool _invalid = false;
  @override
  void initState() {
    super.initState();
    _skip = TextEditingController(
      text: widget.raw?['skip'] as String? ?? widget.initial.skip.join('\n'),
    );
    _add = TextEditingController(
      text: widget.raw?['add'] as String? ?? widget.initial.add.join('\n'),
    );
    if (widget.raw != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _changed();
      });
    }
  }

  @override
  void dispose() {
    _skip.dispose();
    _add.dispose();
    super.dispose();
  }

  void _changed() {
    List<String> dates(String v) =>
        v.split(RegExp('[,，\\s]+')).where((e) => e.isNotEmpty).toList();
    CalendarExceptions? value;
    try {
      value = CalendarExceptions.fromJson({
        'skip': dates(_skip.text),
        'add': dates(_add.text),
      });
    } on FormatException {
      value = null;
    }
    setState(() => _invalid = value == null);
    widget.onChanged(value, {'skip': _skip.text, 'add': _add.text});
  }

  @override
  Widget build(BuildContext context) {
    String t(String key) => planningText(context, key);
    return ExpansionTile(
      title: Text(t('dateExceptions')),
      childrenPadding: const EdgeInsets.only(bottom: 12),
      children: [
        Text(t(widget.scopeHint)),
        Text(t('dateExceptionsHint')),
        for (final entry in [
          (key: 'skip', controller: _skip),
          (key: 'add', controller: _add),
        ])
          TextField(
            key: ValueKey('exceptions-${entry.key}'),
            controller: entry.controller,
            enabled: widget.enabled,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: t(entry.key == 'skip' ? 'skipDates' : 'addDates'),
              hintText: 'YYYY-MM-DD',
              errorText: _invalid ? t('invalidDateExceptions') : null,
            ),
            onChanged: (_) => _changed(),
          ),
      ],
    );
  }
}
