import 'package:flutter/material.dart';
import '../../l10n/routine_policy_strings.dart';
import '../../models/holiday_calendar.dart';
import 'inline_feedback.dart';

class HolidayPolicyEditor extends StatefulWidget {
  const HolidayPolicyEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final HolidayPolicy value;
  final ValueChanged<HolidayPolicy> onChanged;
  final bool enabled;
  @override
  State<HolidayPolicyEditor> createState() => _HolidayPolicyEditorState();
}

class _HolidayPolicyEditorState extends State<HolidayPolicyEditor> {
  Future<void> _import() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => const _CalendarImportDialog(),
    );
    if (!mounted || raw == null) return;
    try {
      final calendar = HolidayCalendar.decode(raw);
      widget.onChanged(
        HolidayPolicy(
          mode: widget.value.mode == 'none'
              ? 'skip_holidays'
              : widget.value.mode,
          calendar: calendar,
        ),
      );
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(routineText(context, 'calendarInvalid'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String t(String k) => routineText(context, k);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('holiday-mode:${widget.value.mode}'),
          initialValue: widget.value.mode,
          isExpanded: true,
          decoration: InputDecoration(labelText: t('holiday')),
          items: [
            for (final mode in ['none', 'skip_holidays', 'workdays'])
              DropdownMenuItem(
                value: mode,
                child: Text(
                  t(mode),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: !widget.enabled
              ? null
              : (mode) => widget.onChanged(
                  HolidayPolicy(
                    mode: mode!,
                    calendar: mode == 'none'
                        ? null
                        : widget.value.calendar ?? HolidayCalendar.mainland2026,
                  ),
                ),
        ),
        Text(t('calendarHint')),
        if (widget.value.calendar != null) ...[
          Text(
            '${t('calendarSource')}: ${widget.value.calendar!.region} · ${widget.value.calendar!.from} – ${widget.value.calendar!.to}',
          ),
          SelectableText(widget.value.calendar!.source),
          if (!widget.value.calendar!.covers(DateTime.now()) ||
              !widget.value.calendar!.covers(
                DateTime(
                  DateTime.now().year,
                  DateTime.now().month,
                  DateTime.now().day + 60,
                ),
              ))
            Text(t('calendarMissing')),
          TextButton(
            onPressed: widget.enabled ? _import : null,
            child: Text(t('calendarImport')),
          ),
        ],
      ],
    );
  }
}

class _CalendarImportDialog extends StatefulWidget {
  const _CalendarImportDialog();
  @override
  State<_CalendarImportDialog> createState() => _CalendarImportDialogState();
}

class _CalendarImportDialogState extends State<_CalendarImportDialog> {
  final _text = TextEditingController();
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(routineText(context, 'calendarImport')),
    content: SizedBox(
      width: 560,
      child: TextField(
        key: const ValueKey('calendar-import-json'),
        controller: _text,
        maxLines: 10,
        maxLength: HolidayCalendar.maxBytes,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(routineText(context, 'cancel')),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text),
        child: Text(routineText(context, 'confirm')),
      ),
    ],
  );
}
