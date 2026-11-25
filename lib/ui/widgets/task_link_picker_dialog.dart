import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../theme/app_theme.dart';
import 'editable_text_menu.dart';
import 'ime_composition_guard.dart';

Future<String?> showTaskLinkPickerDialog(
  BuildContext context, {
  required List<Reminder> available,
}) {
  final l10n = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => _TaskLinkPickerDialog(l10n: l10n, available: available),
  );
}

class _TaskLinkPickerDialog extends StatefulWidget {
  const _TaskLinkPickerDialog({required this.l10n, required this.available});

  final AppLocalizations l10n;
  final List<Reminder> available;

  @override
  State<_TaskLinkPickerDialog> createState() => _TaskLinkPickerDialogState();
}

class _TaskLinkPickerDialogState extends State<_TaskLinkPickerDialog> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _updateQuery(String value) {
    if (isImeComposing(_search)) return;
    setState(() => _query = value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final brightness = Theme.of(context).brightness;
    final normalized = _query.trim().toLowerCase();
    final filtered = normalized.isEmpty
        ? widget.available
        : widget.available
              .where(
                (item) =>
                    item.taskTitle.toLowerCase().contains(normalized) ||
                    (item.taskSummary?.toLowerCase().contains(normalized) ??
                        false),
              )
              .toList();
    return AlertDialog(
      title: Text(l10n.get('addLinkedTask')),
      content: SizedBox(
        width: double.maxFinite,
        height: 340,
        child: widget.available.isEmpty
            ? Center(child: Text(l10n.get('noAvailableTasksToLink')))
            : Column(
                children: [
                  TextField(
                    key: const ValueKey('link-task-search'),
                    controller: _search,
                    autofocus: true,
                    contextMenuBuilder: buildEditableTextMenu,
                    decoration: InputDecoration(
                      hintText: l10n.get('searchLinkHint'),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _search,
                        builder: (_, value, __) => value.text.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(
                                tooltip: l10n.get('clearSearch'),
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: () {
                                  _search.clear();
                                  setState(() => _query = '');
                                },
                              ),
                      ),
                      isDense: true,
                    ),
                    onChanged: _updateQuery,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(child: Text(l10n.get('noSearchResult')))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final item = filtered[i];
                              final qColor = AppTheme.quadrantColor(
                                brightness,
                                item.quadrantLevel,
                              );
                              return ListTile(
                                leading: CircleAvatar(
                                  radius: 12,
                                  backgroundColor: qColor.withValues(
                                    alpha: 0.2,
                                  ),
                                  child: Text(
                                    'Q${item.quadrantLevel}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: qColor,
                                      fontWeight: FontWeight.bold,
                                      fontFeatures: AppTheme.tabularFigures,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  item.taskTitle,
                                  style: const TextStyle(fontSize: 13),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => Navigator.pop(context, item.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.get('cancel')),
        ),
      ],
    );
  }
}
