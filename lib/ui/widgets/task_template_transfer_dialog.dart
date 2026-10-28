import 'package:flutter/material.dart';
import '../../l10n/content_management_strings.dart';
import '../../models/task_template.dart';
import '../../models/task_template_transfer.dart';

class TaskTemplateTransferDialog extends StatefulWidget {
  const TaskTemplateTransferDialog({
    super.key,
    required this.current,
    required this.imported,
  });
  final List<TaskTemplate> current, imported;
  @override
  State<TaskTemplateTransferDialog> createState() =>
      _TaskTemplateTransferDialogState();
}

class _TaskTemplateTransferDialogState
    extends State<TaskTemplateTransferDialog> {
  late List<TemplateImportAction> _actions;
  String? _error;
  bool conflict(TaskTemplate item) => widget.current.any(
    (e) => e.name.toLowerCase() == item.name.toLowerCase(),
  );
  @override
  void initState() {
    super.initState();
    _actions = widget.imported
        .map(
          (e) => conflict(e)
              ? TemplateImportAction.skip
              : TemplateImportAction.copy,
        )
        .toList();
  }

  List<TemplateImportChoice> get _choices => [
    for (var i = 0; i < widget.imported.length; i++)
      TemplateImportChoice(widget.imported[i], _actions[i]),
  ];
  @override
  Widget build(BuildContext context) {
    String t(String key) => contentText(context, key);
    return AlertDialog(
      title: Text(t('templateImport')),
      content: SizedBox(
        width: 580,
        height: 420,
        child: ListView(
          children: [
            Text(t('templateHint')),
            if (_error != null) Text(t(_error!)),
            for (var i = 0; i < widget.imported.length; i++)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.imported[i].name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(widget.imported[i].title),
                      if (widget.imported[i].items.isNotEmpty)
                        Text(
                          widget.imported[i].items.join(' / '),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (conflict(widget.imported[i])) Text(t('conflict')),
                      DropdownButtonFormField<TemplateImportAction>(
                        key: ValueKey('template-import-choice:$i'),
                        initialValue: _actions[i],
                        isExpanded: true,
                        items: [
                          for (final action in TemplateImportAction.values)
                            if (action != TemplateImportAction.replace ||
                                conflict(widget.imported[i]))
                              DropdownMenuItem(
                                value: action,
                                child: Text(t(action.name)),
                              ),
                        ],
                        onChanged: (value) => setState(() {
                          _actions[i] = value!;
                          _error = null;
                        }),
                      ),
                    ],
                  ),
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
        FilledButton(
          key: const ValueKey('template-import-confirm'),
          onPressed: _actions.every((e) => e == TemplateImportAction.skip)
              ? null
              : () {
                  try {
                    TaskTemplateTransfer.merge(widget.current, _choices);
                    Navigator.pop(context, _choices);
                  } catch (_) {
                    setState(() => _error = 'templateInvalid');
                  }
                },
          child: Text(t('templateImport')),
        ),
      ],
    );
  }
}
