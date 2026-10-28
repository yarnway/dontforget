import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/holiday_calendar_file_service.dart';
import '../../l10n/routine_policy_strings.dart';
import '../../models/holiday_calendar.dart';
import 'inline_feedback.dart';

final holidayCalendarFilesProvider = Provider<HolidayCalendarFileService>(
  (_) => const HolidayCalendarFileService(),
);

class HolidayPolicyEditor extends ConsumerStatefulWidget {
  const HolidayPolicyEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.isCurrent,
  });
  final HolidayPolicy value;
  final ValueChanged<HolidayPolicy> onChanged;
  final bool enabled;
  final bool Function()? isCurrent;
  @override
  ConsumerState<HolidayPolicyEditor> createState() =>
      _HolidayPolicyEditorState();
}

class _HolidayPolicyEditorState extends ConsumerState<HolidayPolicyEditor> {
  bool _busy = false;
  Future<void> _import({bool file = false}) async {
    if (_busy || !widget.enabled || widget.isCurrent?.call() == false) return;
    final baseline = jsonEncode(widget.value.toJson());
    bool active() =>
        mounted &&
        widget.enabled &&
        widget.isCurrent?.call() != false &&
        jsonEncode(widget.value.toJson()) == baseline;
    setState(() => _busy = true);
    try {
      final HolidayCalendar? incoming;
      if (file) {
        incoming = await ref.read(holidayCalendarFilesProvider).pick();
      } else {
        final raw = await showDialog<String>(
          context: context,
          builder: (_) => const _CalendarImportDialog(),
        );
        incoming = raw == null ? null : HolidayCalendar.decode(raw);
      }
      if (!active() || incoming == null) return;
      HolidayCalendar calendar;
      var replacement = false;
      final regionChange =
          widget.value.calendar != null &&
          widget.value.calendar!.region != incoming.region;
      if (regionChange) {
        calendar = incoming;
      } else {
        try {
          calendar = widget.value.calendar?.merge(incoming) ?? incoming;
        } on CalendarUpdateConflict {
          calendar = widget.value.calendar!.merge(
            incoming,
            replaceOverlaps: true,
          );
          replacement = true;
        }
      }
      if (!mounted || !context.mounted || !active()) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(routineText(context, 'calendarUpdatePreview')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  routineText(
                    context,
                    regionChange
                        ? 'calendarChangeRegion'
                        : replacement
                        ? 'calendarReplaceCoverage'
                        : 'calendarKeepYears',
                  ),
                ),
                for (final part in calendar.snapshots)
                  Text(
                    '${part.region} · ${part.from} – ${part.to}\n${part.source}',
                  ),
                Text(routineText(context, 'calendarUnverifiedSource')),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(routineText(context, 'cancel')),
            ),
            FilledButton(
              key: const ValueKey('calendar-apply-update'),
              onPressed: () => Navigator.pop(c, true),
              child: Text(routineText(context, 'confirm')),
            ),
          ],
        ),
      );
      if (confirmed == true && active()) {
        widget.onChanged(
          HolidayPolicy(
            mode: widget.value.mode == 'none'
                ? 'skip_holidays'
                : widget.value.mode,
            calendar: calendar,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(routineText(context, 'calendarInvalid'))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_busy ||
        !widget.enabled ||
        widget.isCurrent?.call() == false ||
        widget.value.calendar == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(holidayCalendarFilesProvider).save(widget.value.calendar!);
    } catch (_) {
      if (mounted) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(routineText(context, 'calendarInvalid'))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
          onChanged: !widget.enabled || _busy
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
          for (final part in widget.value.calendar!.snapshots) ...[
            Text(
              '${t('calendarSource')}: ${part.region} · ${part.from} – ${part.to}',
            ),
            SelectableText(part.source),
          ],
          if (widget.value.calendar!.missingYears(DateTime.now()).isNotEmpty)
            Text(
              '${t('calendarMissing')} ${widget.value.calendar!.missingYears(DateTime.now()).join(', ')}',
            ),
          TextButton(
            onPressed: widget.enabled && !_busy ? () => _import() : null,
            child: Text(t('calendarImport')),
          ),
          Wrap(
            children: [
              TextButton(
                key: const ValueKey('calendar-import-file'),
                onPressed: widget.enabled && !_busy
                    ? () => _import(file: true)
                    : null,
                child: Text(t('calendarFile')),
              ),
              TextButton(
                key: const ValueKey('calendar-export'),
                onPressed: widget.enabled && !_busy ? _export : null,
                child: Text(t('calendarExport')),
              ),
            ],
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
