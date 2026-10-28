import 'package:flutter/material.dart';
import '../../l10n/content_management_strings.dart';
import '../../models/reminder.dart';
import '../../models/task_metadata_patch.dart';

class TaskMetadataDialog extends StatefulWidget {
  const TaskMetadataDialog({super.key, required this.rows});
  final List<Reminder> rows;
  @override
  State<TaskMetadataDialog> createState() => _TaskMetadataDialogState();
}

class _TaskMetadataDialogState extends State<TaskMetadataDialog> {
  final _project = TextEditingController(), _tags = TextEditingController();
  String _projectMode = 'keep';
  TagEditMode _tagMode = TagEditMode.keep;
  TaskMetadataPatch? _preview;
  bool _invalid = false;
  @override
  void dispose() {
    _project.dispose();
    _tags.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
    _preview = null;
    _invalid = false;
  });
  void _buildPreview() {
    try {
      final tags = _tagMode == TagEditMode.keep
          ? <String>[]
          : _tags.text
                .split(RegExp(r'[,，\n]'))
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
      final patch = TaskMetadataPatch(
        project: _projectMode == 'keep'
            ? null
            : _projectMode == 'clear'
            ? ''
            : _project.text.trim(),
        tagMode: _tagMode,
        tags: tags,
      );
      for (final row in widget.rows) {
        patch.apply(row.details).encode();
      }
      setState(() => _preview = patch);
    } catch (_) {
      setState(() => _invalid = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    String t(String k) => contentText(context, k);
    return AlertDialog(
      title: Text(t('metadata')),
      content: SizedBox(
        width: 600,
        height: 440,
        child: ListView(
          children: [
            Text(t('metadataHint')),
            DropdownButtonFormField<String>(
              key: const ValueKey('metadata-project-mode'),
              initialValue: _projectMode,
              isExpanded: true,
              decoration: InputDecoration(labelText: t('project')),
              items: [
                for (final mode in ['keep', 'set', 'clear'])
                  DropdownMenuItem(value: mode, child: Text(t(mode))),
              ],
              onChanged: (value) {
                _projectMode = value!;
                _changed();
              },
            ),
            if (_projectMode == 'set')
              TextField(
                key: const ValueKey('metadata-project'),
                controller: _project,
                maxLength: 128,
                decoration: InputDecoration(labelText: t('project')),
                onChanged: (_) => _changed(),
              ),
            DropdownButtonFormField<TagEditMode>(
              key: const ValueKey('metadata-tag-mode'),
              initialValue: _tagMode,
              isExpanded: true,
              decoration: InputDecoration(labelText: t('tags')),
              items: [
                for (final mode in TagEditMode.values)
                  DropdownMenuItem(value: mode, child: Text(t(mode.name))),
              ],
              onChanged: (value) {
                _tagMode = value!;
                _changed();
              },
            ),
            if (_tagMode != TagEditMode.keep)
              TextField(
                key: const ValueKey('metadata-tags'),
                controller: _tags,
                maxLines: 2,
                decoration: InputDecoration(labelText: t('tags')),
                onChanged: (_) => _changed(),
              ),
            if (_invalid) Text(t('metadataInvalid')),
            if (_preview != null)
              for (final row in widget.rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.taskTitle,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '${t('project')}: ${row.details.project} → ${_preview!.apply(row.details).project}',
                      ),
                      Text(
                        '${t('tags')}: ${row.details.tags.join(' / ')} → ${_preview!.apply(row.details).tags.join(' / ')}',
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('cancel')),
        ),
        TextButton(
          key: const ValueKey('metadata-preview'),
          onPressed: _buildPreview,
          child: Text(t('preview')),
        ),
        FilledButton(
          key: const ValueKey('metadata-save'),
          onPressed: _preview == null
              ? null
              : () => Navigator.pop(context, _preview),
          child: Text(t('save')),
        ),
      ],
    );
  }
}
