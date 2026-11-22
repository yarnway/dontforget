import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../models/task_details.dart';
import 'editable_text_menu.dart';

/// Edits one task's metadata draft. Persistence and navigation belong to the
/// host editor; this deliberately has no planning or database responsibilities.
class TaskMetadataEditor extends StatefulWidget {
  const TaskMetadataEditor({
    super.key,
    required this.details,
    required this.onChanged,
    this.enabled = true,
    required this.onValidityChanged,
  });
  final TaskDetails details;
  final ValueChanged<TaskDetails> onChanged;
  final bool enabled;
  final ValueChanged<bool> onValidityChanged;

  @override
  State<TaskMetadataEditor> createState() => _TaskMetadataEditorState();
}

class _TaskMetadataEditorState extends State<TaskMetadataEditor> {
  late final TextEditingController _project;
  final _newTag = TextEditingController();
  final _newItem = TextEditingController();
  final _invalidLabels = <String>{};

  // Stored JSON bounds use UTF-16 code units, whereas TextField.maxLength
  // counts graphemes. Keep emoji input within the same persistence limits.
  TextInputFormatter _storedLimit(int limit) => TextInputFormatter.withFunction(
    (before, after) => after.text.length <= limit ? after : before,
  );

  @override
  void initState() {
    super.initState();
    _project = TextEditingController(text: widget.details.project);
  }

  @override
  void dispose() {
    _project.dispose();
    _newTag.dispose();
    _newItem.dispose();
    super.dispose();
  }

  void _patch(Map<String, dynamic> changes) =>
      widget.onChanged(widget.details.patch(changes));

  void _addTag() {
    final tag = _newTag.text.trim();
    if (tag.isEmpty ||
        widget.details.tags.contains(tag) ||
        widget.details.tags.length >= 16) {
      return;
    }
    _patch({
      'tags': [...widget.details.tags, tag],
    });
    _newTag.clear();
  }

  void _addItem() {
    final label = _newItem.text.trim();
    if (label.isEmpty || widget.details.checklist.length >= 64) return;
    _patch({
      'checklist': [
        ...widget.details.checklist.map((e) => e.toJson()),
        ChecklistItem(const Uuid().v4(), label).toJson(),
      ],
    });
    _newItem.clear();
  }

  void _changeItem(int index, ChecklistItem? replacement, {int? moveTo}) {
    final items = List<ChecklistItem>.of(widget.details.checklist);
    final item = items.removeAt(index);
    if (replacement == null && moveTo == null) {
      _invalidLabels.remove(item.id);
      widget.onValidityChanged(_invalidLabels.isEmpty);
    }
    if (moveTo != null) {
      items.insert(moveTo, item);
    } else if (replacement != null) {
      items.insert(index, replacement);
    }
    _patch({'checklist': items.map((e) => e.toJson()).toList()});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final checklist = widget.details.checklist;
    final doneCount = checklist.where((e) => e.done).length;
    return Column(
      key: const ValueKey('detail-task-metadata'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('detail-project'),
          controller: _project,
          enabled: widget.enabled,
          maxLength: 128,
          inputFormatters: [_storedLimit(128)],
          decoration: InputDecoration(labelText: l10n.get('taskProject')),
          onChanged: (value) => _patch({'project': value}),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.get('taskTags'),
          style: theme.textTheme.titleSmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        if (widget.details.tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in widget.details.tags)
                InputChip(
                  label: Text(tag),
                  onDeleted: !widget.enabled
                      ? null
                      : () => _patch({
                          'tags': widget.details.tags
                              .where((e) => e != tag)
                              .toList(),
                        }),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('detail-new-tag'),
          controller: _newTag,
          enabled: widget.enabled && widget.details.tags.length < 16,
          maxLength: 64,
          inputFormatters: [_storedLimit(64)],
          onSubmitted: (_) => _addTag(),
          decoration: InputDecoration(
            labelText: l10n.get('taskAddTag'),
            suffixIcon: IconButton(
              key: const ValueKey('detail-add-tag'),
              tooltip: l10n.get('taskAddTag'),
              onPressed: widget.enabled ? _addTag : null,
              icon: const Icon(Icons.add),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.get('taskChecklist'),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            if (checklist.isNotEmpty)
              Text(
                '$doneCount / ${checklist.length}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (checklist.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.get('taskChecklistEmpty'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        for (var i = 0; i < checklist.length; i++)
          Container(
            key: ValueKey('detail-item-${checklist[i].id}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(6, 6, 8, 2),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: 0.55),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      key: ValueKey('detail-item-done-${checklist[i].id}'),
                      value: checklist[i].done,
                      semanticLabel: checklist[i].label,
                      onChanged: !widget.enabled
                          ? null
                          : (value) => _changeItem(
                              i,
                              checklist[i].copyWith(done: value),
                            ),
                    ),
                    Expanded(
                      child: TextFormField(
                        key: ValueKey('detail-item-label-${checklist[i].id}'),
                        initialValue: checklist[i].label,
                        enabled: widget.enabled,
                        maxLength: 512,
                        inputFormatters: [_storedLimit(512)],
                        maxLines: null,
                        decoration: const InputDecoration(counterText: ''),
                        onChanged: (value) {
                          if (value.trim().isEmpty) {
                            _invalidLabels.add(checklist[i].id);
                          } else {
                            _invalidLabels.remove(checklist[i].id);
                            _changeItem(i, checklist[i].copyWith(label: value));
                          }
                          widget.onValidityChanged(_invalidLabels.isEmpty);
                        },
                      ),
                    ),
                  ],
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    IconButton(
                      key: ValueKey('detail-item-up-${checklist[i].id}'),
                      tooltip: l10n.get('taskMoveUp'),
                      onPressed: widget.enabled && i > 0
                          ? () => _changeItem(i, null, moveTo: i - 1)
                          : null,
                      icon: const Icon(Icons.arrow_upward, size: 18),
                    ),
                    IconButton(
                      key: ValueKey('detail-item-down-${checklist[i].id}'),
                      tooltip: l10n.get('taskMoveDown'),
                      onPressed: widget.enabled && i < checklist.length - 1
                          ? () => _changeItem(i, null, moveTo: i + 1)
                          : null,
                      icon: const Icon(Icons.arrow_downward, size: 18),
                    ),
                    IconButton(
                      key: ValueKey('detail-item-remove-${checklist[i].id}'),
                      tooltip: l10n.get('taskRemoveItem'),
                      onPressed: widget.enabled
                          ? () => _changeItem(i, null)
                          : null,
                      icon: const Icon(Icons.delete_outline, size: 18),
                    ),
                  ],
                ),
              ],
            ),
          ),
        TextField(
          key: const ValueKey('detail-new-checklist-item'),
          controller: _newItem,
          enabled: widget.enabled && checklist.length < 64,
          maxLength: 512,
          inputFormatters: [_storedLimit(512)],
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          minLines: 1,
          maxLines: 3,
          contextMenuBuilder: buildEditableTextMenu,
          onSubmitted: (_) => _addItem(),
          decoration: InputDecoration(
            labelText: l10n.get('taskAddChecklistItem'),
            suffixIcon: IconButton(
              key: const ValueKey('detail-add-checklist-item'),
              tooltip: l10n.get('taskAddChecklistItem'),
              onPressed: widget.enabled ? _addItem : null,
              icon: const Icon(Icons.add),
            ),
          ),
        ),
      ],
    );
  }
}
