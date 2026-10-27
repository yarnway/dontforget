import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/database_helper.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/planning_strings.dart';
import '../../models/saved_task_filter.dart';
import '../../providers/providers.dart';
import '../../providers/saved_task_filters_provider.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../../services/recovery/runtime_gate.dart';
import 'inline_feedback.dart';

class SavedTaskFiltersBar extends ConsumerStatefulWidget {
  const SavedTaskFiltersBar({
    super.key,
    required this.view,
    required this.query,
    required this.onSelected,
  });
  final String view, query;
  final ValueChanged<SavedTaskFilter> onSelected;

  @override
  ConsumerState<SavedTaskFiltersBar> createState() =>
      _SavedTaskFiltersBarState();
}

class _SavedTaskFiltersBarState extends ConsumerState<SavedTaskFiltersBar> {
  late final DatabaseHelper _database;
  late final DataGeneration _generation;
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken _birth;
  late Future<List<SavedTaskFilter>> _items;
  bool _busy = false;
  bool get _current =>
      mounted && _database.isCurrent(_generation) && _runtime.isCurrent(_birth);
  String t(String key) => planningText(context, key);

  @override
  void initState() {
    super.initState();
    _database = ref.read(databaseHelperProvider);
    _generation = _database.captureGeneration();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.capture();
    _items = _load();
  }

  Future<List<SavedTaskFilter>> _load() {
    final result = ref.read(savedTaskFilterStoreProvider).load();
    // A draft event can arrive before FutureBuilder attaches on the next frame.
    result.ignore();
    return result;
  }

  String _error(Object error) => t(switch (error) {
    SavedTaskFilterException(reason: SavedTaskFilterFailure.duplicateName) =>
      'filterDuplicateName',
    SavedTaskFilterException(reason: SavedTaskFilterFailure.limitReached) =>
      'filterLimit',
    SavedTaskFilterException(reason: SavedTaskFilterFailure.changed) =>
      'filterChanged',
    _ => 'failed',
  });

  Future<void> _edit({SavedTaskFilter? item}) async {
    if (!_current || _busy) return;
    // Capture the selection before opening the name dialog.
    final view = widget.view, query = widget.query;
    final store = ref.read(savedTaskFilterStoreProvider);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _FilterNameDialog(
        name: item?.name ?? '',
        title: t(item == null ? 'saveCurrentFilter' : 'renameSavedFilter'),
        isCurrent: () => _current,
        onSave: (name) => item == null
            ? store.save(name, view, query)
            : store.rename(item, name),
        errorText: _error,
      ),
    );
    if (saved == true && mounted && _current) {
      InlineFeedback.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('saved'))));
    }
  }

  Future<void> _remove(SavedTaskFilter item) async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    final store = ref.read(savedTaskFilterStoreProvider);
    try {
      final index = await store.remove(item);
      if (!mounted || !_current) return;
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text(t('filterDeleted')),
          action: SnackBarAction(
            label: AppLocalizations.of(context).get('undo'),
            onPressed: () async {
              if (!_current || _busy) return;
              setState(() => _busy = true);
              try {
                await store.restore(item, index);
                if (mounted && _current) {
                  InlineFeedback.of(context).hideCurrentSnackBar();
                }
              } catch (error) {
                if (mounted && _current) {
                  InlineFeedback.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(_error(error))));
                }
              } finally {
                if (_current) setState(() => _busy = false);
              }
            },
          ),
        ),
      );
    } catch (error) {
      if (mounted && _current) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_error(error))));
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _choose(List<SavedTaskFilter> items) async {
    if (!_current || _busy) return;
    final action = await showDialog<(String, SavedTaskFilter)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('savedFilters')),
        content: SizedBox(
          width: 480,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .55,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final item = items[i];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  selected: item.matches(widget.view, widget.query),
                  title: Text(item.name),
                  subtitle: Text(
                    '${t(item.view)}${item.query.isEmpty ? '' : ' · ${item.query}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(dialogContext).pop(('apply', item)),
                  trailing: PopupMenuButton<String>(
                    tooltip: t('filterOptions'),
                    onSelected: (value) =>
                        Navigator.of(dialogContext).pop((value, item)),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text(t('renameSavedFilter')),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(t('deleteSavedFilter')),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppLocalizations.of(context).get('cancel')),
          ),
        ],
      ),
    );
    if (action == null || !_current) return;
    switch (action.$1) {
      case 'apply':
        // A menu opened before another edit must not apply its stale snapshot.
        try {
          final fresh = await ref.read(savedTaskFilterStoreProvider).load();
          if (!_current) return;
          if (!fresh.any((item) => item.sameAs(action.$2))) {
            throw const SavedTaskFilterException(
              SavedTaskFilterFailure.changed,
            );
          }
          widget.onSelected(action.$2);
        } catch (error) {
          if (mounted && _current) {
            InlineFeedback.of(
              context,
            ).showSnackBar(SnackBar(content: Text(_error(error))));
          }
        }
      case 'rename':
        await _edit(item: action.$2);
      case 'delete':
        await _remove(action.$2);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(workspaceDraftsProvider, (_, _) {
      if (_current) {
        setState(() {
          _items = _load();
        });
      }
    });
    return FutureBuilder<List<SavedTaskFilter>>(
      future: _items,
      builder: (context, snapshot) {
        final ready =
            snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError &&
            _current &&
            !_busy;
        final items = snapshot.data ?? const <SavedTaskFilter>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const ValueKey('save-task-filter'),
                  onPressed:
                      ready &&
                          widget.query.trim().length <=
                              SavedTaskFilter.maxQueryLength
                      ? _edit
                      : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: Text(t('saveCurrentFilter')),
                ),
                TextButton.icon(
                  key: const ValueKey('choose-task-filter'),
                  onPressed: ready && items.isNotEmpty
                      ? () => _choose(items)
                      : null,
                  icon: const Icon(Icons.bookmarks_outlined),
                  label: Text('${t('savedFilters')} (${items.length})'),
                ),
              ],
            ),
            if (snapshot.hasError)
              Text(
                t('filtersUnreadable'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        );
      },
    );
  }
}

class _FilterNameDialog extends StatefulWidget {
  const _FilterNameDialog({
    required this.name,
    required this.title,
    required this.isCurrent,
    required this.onSave,
    required this.errorText,
  });
  final String name, title;
  final bool Function() isCurrent;
  final Future<void> Function(String) onSave;
  final String Function(Object) errorText;
  @override
  State<_FilterNameDialog> createState() => _FilterNameDialogState();
}

class _FilterNameDialogState extends State<_FilterNameDialog> {
  late final _name = TextEditingController(text: widget.name);
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !widget.isCurrent()) return;
    final name = _name.text.trim();
    if (!SavedTaskFilter.validName(name)) {
      setState(() => _error = planningText(context, 'filterNameInvalid'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(name);
      if (mounted && widget.isCurrent()) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted && widget.isCurrent()) {
        setState(() => _error = widget.errorText(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: TextField(
          key: const ValueKey('task-filter-name'),
          controller: _name,
          autofocus: true,
          enabled: !_busy,
          maxLength: SavedTaskFilter.maxNameLength,
          decoration: InputDecoration(
            labelText: planningText(context, 'savedFilterName'),
            errorText: _error,
          ),
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.of(context).get('cancel')),
        ),
        FilledButton(
          key: const ValueKey('confirm-task-filter'),
          onPressed: _busy ? null : _save,
          child: Text(AppLocalizations.of(context).get('save')),
        ),
      ],
    ),
  );
}
