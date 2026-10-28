import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../../models/task_template.dart';
import '../../models/task_template_transfer.dart';
import '../../services/task_template_file_service.dart';
import '../../l10n/content_management_strings.dart';
import 'task_template_transfer_dialog.dart';
import '../../providers/task_templates_provider.dart';

final taskTemplateFileServiceProvider = Provider<TaskTemplateFileService>(
  (_) => const TaskTemplateFileService(),
);

String _failure(Object error) => switch (error) {
  TaskTemplateException(reason: TaskTemplateFailure.duplicateName) =>
    'templateDuplicate',
  TaskTemplateException(reason: TaskTemplateFailure.limitReached) =>
    'templateLimit',
  TaskTemplateException(reason: TaskTemplateFailure.changed) =>
    'templateChanged',
  _ => 'templateSaveFailed',
};

class TaskTemplateLibrary extends ConsumerStatefulWidget {
  const TaskTemplateLibrary({super.key, this.allowApply = false});
  final bool allowApply;
  @override
  ConsumerState<TaskTemplateLibrary> createState() =>
      _TaskTemplateLibraryState();
}

class _TaskTemplateLibraryState extends ConsumerState<TaskTemplateLibrary> {
  late final TaskTemplateStore _store;
  List<TaskTemplate> _items = [];
  bool _busy = true;
  String? _error;
  bool _transferError = false;
  bool _transferPrompting = false;
  String t(String key) => planningText(context, key);
  @override
  void initState() {
    super.initState();
    _store = ref.read(taskTemplateStoreProvider);
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final items = await _store.load();
      if (mounted) setState(() => _items = items);
    } catch (_) {
      if (mounted) setState(() => _error = 'templatesUnreadable');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _transfer(bool importing) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _transferError = false;
    });
    try {
      final files = ref.read(taskTemplateFileServiceProvider);
      if (importing) {
        final imported = await files.pick();
        if (!mounted || imported == null) return;
        final expected = await _store.load();
        if (!mounted) return;
        setState(() => _transferPrompting = true);
        final choices = await showDialog<List<TemplateImportChoice>>(
          context: context,
          builder: (_) =>
              TaskTemplateTransferDialog(current: expected, imported: imported),
        );
        if (mounted) setState(() => _transferPrompting = false);
        if (!mounted || choices == null) return;
        await _store.importTemplates(expected, choices);
        if (mounted) await _load();
      } else {
        await files.save(await _store.load());
      }
    } catch (_) {
      if (mounted) setState(() => _transferError = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(TaskTemplate? item) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => TaskTemplateEditorDialog(template: item),
    );
    if (mounted && saved == true) await _load();
  }

  Future<void> _remove(TaskTemplate item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('deleteTemplate')),
        content: Text(item.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context).get('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('deleteTemplate')),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    setState(() => _busy = true);
    try {
      await _store.remove(item);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = _failure(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply(TaskTemplate item) async {
    setState(() => _busy = true);
    try {
      final items = await _store.load();
      if (!items.any((e) => e.id == item.id && e.sameAs(item))) {
        throw const TaskTemplateException(TaskTemplateFailure.changed);
      }
      if (mounted) Navigator.pop(context, item);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _failure(e);
          _busy = false;
        });
      }
    }
  }

  Widget _card(TaskTemplate item) => Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(item.name, style: Theme.of(context).textTheme.titleSmall),
          Text(item.title),
          if (item.items.isNotEmpty)
            Text(
              item.items.join(' / '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          Wrap(
            spacing: 6,
            children: [
              if (widget.allowApply)
                TextButton(
                  key: ValueKey('template-use:${item.id}'),
                  onPressed: _busy ? null : () => _apply(item),
                  child: Text(t('useTemplate')),
                ),
              TextButton(
                key: ValueKey('template-edit:${item.id}'),
                onPressed: _busy ? null : () => _edit(item),
                child: Text(t('edit')),
              ),
              TextButton(
                key: ValueKey('template-delete:${item.id}'),
                onPressed: _busy ? null : () => _remove(item),
                child: Text(t('deleteTemplate')),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('templates')),
    content: SizedBox(
      width: 540,
      height: 420,
      child: ListView(
        children: [
          Text(t('templateHint')),
          Wrap(
            spacing: 6,
            children: [
              TextButton.icon(
                key: const ValueKey('templates-import'),
                onPressed: _busy || _error != null
                    ? null
                    : () => _transfer(true),
                icon: const Icon(Icons.file_open_outlined),
                label: Text(contentText(context, 'templateImport')),
              ),
              TextButton.icon(
                key: const ValueKey('templates-export'),
                onPressed: _busy || _error != null || _items.isEmpty
                    ? null
                    : () => _transfer(false),
                icon: const Icon(Icons.save_alt),
                label: Text(contentText(context, 'templateExport')),
              ),
            ],
          ),
          if (_transferError) Text(contentText(context, 'templateInvalid')),
          if (_busy && !_transferPrompting) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                t(_error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_error != null)
            TextButton(
              onPressed: _busy ? null : _load,
              child: Text(t('reloadTemplates')),
            ),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(child: Text(t('empty'))),
            ),
          for (final item in _items) _card(item),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(AppLocalizations.of(context).get('cancel')),
      ),
      FilledButton.icon(
        key: const ValueKey('template-new'),
        onPressed: _busy || _error != null ? null : () => _edit(null),
        icon: const Icon(Icons.add),
        label: Text(t('newTemplate')),
      ),
    ],
  );
}

class TaskTemplateEditorDialog extends ConsumerStatefulWidget {
  const TaskTemplateEditorDialog({
    super.key,
    this.template,
    this.seedTitle = '',
    this.seedItems = const [],
    this.seedTags = const [],
    this.seedProject = '',
  });
  final TaskTemplate? template;
  final String seedTitle, seedProject;
  final List<String> seedItems, seedTags;
  @override
  ConsumerState<TaskTemplateEditorDialog> createState() =>
      _TaskTemplateEditorDialogState();
}

class _TaskTemplateEditorDialogState
    extends ConsumerState<TaskTemplateEditorDialog> {
  late final TaskTemplateStore _store;
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _title, _items, _tags, _project;
  bool _saving = false;
  String? _error;
  String t(String key) => planningText(context, key);
  @override
  void initState() {
    super.initState();
    _store = ref.read(taskTemplateStoreProvider);
    final item = widget.template;
    _name = TextEditingController(text: item?.name ?? '');
    _title = TextEditingController(text: item?.title ?? widget.seedTitle);
    _items = TextEditingController(
      text: (item?.items ?? widget.seedItems).join('\n'),
    );
    _tags = TextEditingController(
      text: (item?.tags ?? widget.seedTags).join(', '),
    );
    _project = TextEditingController(text: item?.project ?? widget.seedProject);
  }

  @override
  void dispose() {
    for (final c in [_name, _title, _items, _tags, _project]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _store.save(
        expected: widget.template,
        name: _name.text,
        title: _title.text,
        items: _items.text
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        tags: _tags.text
            .split(RegExp('[,，]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList(),
        project: _project.text,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = _failure(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t(widget.template == null ? 'newTemplate' : 'editTemplate')),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t('templateHint')),
              TextFormField(
                key: const ValueKey('template-name'),
                controller: _name,
                enabled: !_saving,
                maxLength: 64,
                decoration: InputDecoration(labelText: t('templateName')),
                validator: (v) => v == null || v.trim().isEmpty
                    ? t('templateRequired')
                    : null,
              ),
              TextFormField(
                key: const ValueKey('template-title'),
                controller: _title,
                enabled: !_saving,
                maxLength: 160,
                decoration: InputDecoration(labelText: t('title')),
                validator: (v) => v == null || v.trim().isEmpty
                    ? t('templateRequired')
                    : null,
              ),
              TextFormField(
                key: const ValueKey('template-items'),
                controller: _items,
                enabled: !_saving,
                maxLines: 4,
                decoration: InputDecoration(labelText: t('checklist')),
              ),
              TextFormField(
                key: const ValueKey('template-tags'),
                controller: _tags,
                enabled: !_saving,
                decoration: InputDecoration(labelText: t('tags')),
              ),
              TextFormField(
                key: const ValueKey('template-project'),
                controller: _project,
                enabled: !_saving,
                maxLength: 128,
                decoration: InputDecoration(labelText: t('project')),
              ),
              if (_error != null)
                Text(
                  t(_error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(AppLocalizations.of(context).get('cancel')),
      ),
      FilledButton(
        key: const ValueKey('template-save'),
        onPressed: _saving ? null : _save,
        child: Text(t('saveTemplate')),
      ),
    ],
  );
}
