import '../widgets/workspace_tool_panel.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../services/bidirectional_link_service.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/editable_text_menu.dart';
import '../widgets/knowledge_graph_view.dart';
import 'task_detail_screen.dart';

/// A bounded graph page plus a virtualized list for the complete result set.
class KnowledgeGraphScreen extends ConsumerStatefulWidget {
  final String? initialFocusTaskId;
  const KnowledgeGraphScreen({
    super.key,
    this.initialFocusTaskId,
    this.embedded = false,
    this.onClose,
  });
  final bool embedded;
  final VoidCallback? onClose;
  @override
  ConsumerState<KnowledgeGraphScreen> createState() =>
      _KnowledgeGraphScreenState();
}

class _KnowledgeGraphScreenState extends ConsumerState<KnowledgeGraphScreen> {
  static const pageSize = 120;
  static const canvasSize = 1400.0;
  final _transform = TransformationController();
  final _search = TextEditingController();
  Timer? _debounce;
  List<Reminder>? _source;
  List<Reminder> _filtered = [];
  Map<String, Reminder> _byId = {};
  KnowledgeGraphData? _graph;
  String? _selected;
  String _query = '';
  int _quadrant = 0;
  int _page = 0;
  bool _listMode = false;
  bool _initialFocusApplied = false;
  Size? _viewport;
  bool _needsFit = true;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialFocusTaskId;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _filter() {
    final terms = _query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((q) => q.isNotEmpty)
        .toList();
    _filtered = [
      for (final task in _source!)
        if ((_quadrant == 0 || task.quadrantLevel == _quadrant) &&
            (terms.isEmpty ||
                terms.every(
                  ('${task.taskTitle}\n${task.taskSummary ?? ''}')
                      .toLowerCase()
                      .contains,
                )))
          task,
    ];
    _page = math.min(_page, math.max(0, (_filtered.length - 1) ~/ pageSize));
    if (!_initialFocusApplied) {
      _initialFocusApplied = true;
      final index = _filtered.indexWhere((task) => task.id == _selected);
      if (index >= 0) _page = index ~/ pageSize;
    }
    _graph = null;
  }

  void _setQuery(String query) {
    _debounce?.cancel();
    void apply() {
      if (!mounted) return;
      setState(() {
        _query = query.trim();
        _page = 0;
        _filter();
      });
    }

    if (query.trim().isEmpty) {
      apply();
    } else {
      _debounce = Timer(const Duration(milliseconds: 180), apply);
    }
  }

  void _reset() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _query = '';
      _quadrant = 0;
      _page = 0;
      _filter();
    });
  }

  void _fit() {
    final viewport = _viewport;
    final nodes = _graph?.nodes;
    if (viewport == null || nodes == null || nodes.isEmpty) return;
    var extentX = 100.0, extentY = 100.0;
    for (final node in nodes) {
      extentX = math.max(extentX, node.x.abs() + 75);
      extentY = math.max(extentY, node.y.abs() + 65);
    }
    final scale = math
        .min(viewport.width / (extentX * 2), viewport.height / (extentY * 2))
        .clamp(0.1, 1.5);
    _transform.value = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, (viewport.width - canvasSize * scale) / 2)
      ..setEntry(1, 3, (viewport.height - canvasSize * scale) / 2);
  }

  void _open(Reminder task) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => TaskDetailScreen(task: task)));

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final tasks = ref.watch(remindersProvider);
    if (!identical(tasks, _source)) {
      _source = tasks;
      _byId = {for (final task in tasks) task.id: task};
      _filter();
    }
    if (_graph == null) {
      final page = _filtered.skip(_page * pageSize).take(pageSize).toList();
      _graph = ref.read(biDirectionalLinkServiceProvider).buildGraphData(page);
      final columns = math.max(1, math.sqrt(page.length).ceil());
      final rows = (page.length / columns).ceil();
      for (var i = 0; i < _graph!.nodes.length; i++) {
        final node = _graph!.nodes[i];
        node.x = (i % columns - (columns - 1) / 2) * 110;
        node.y = (i ~/ columns - (rows - 1) / 2) * 110;
      }
      if (!_graph!.nodes.any((node) => node.id == _selected)) _selected = null;
      _needsFit = true;
    }
    final selected = _byId[_selected];
    final pageCount = math.max(1, (_filtered.length / pageSize).ceil());
    final body = SafeArea(
      child: LayoutBuilder(
        builder: (context, bodyConstraints) => Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: bodyConstraints.maxHeight * 0.45,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _search,
                        contextMenuBuilder: buildEditableTextMenu,
                        decoration: InputDecoration(
                          labelText: loc.get('searchGraphHint'),
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: IconButton(
                            tooltip: loc.get('clearSearch'),
                            onPressed: () {
                              _search.clear();
                              _setQuery('');
                            },
                            icon: const Icon(Icons.clear),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: _setQuery,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final q in [0, 1, 2, 3, 4])
                            ChoiceChip(
                              label: Text(q == 0 ? loc.get('all') : 'Q$q'),
                              selected: _quadrant == q,
                              onSelected: (_) => setState(() {
                                _quadrant = q;
                                _page = 0;
                                _filter();
                              }),
                            ),
                          TextButton.icon(
                            onPressed: () => setState(() {
                              _listMode = !_listMode;
                              _needsFit = true;
                            }),
                            icon: Icon(
                              _listMode
                                  ? Icons.hub_outlined
                                  : Icons.view_list_outlined,
                            ),
                            label: Text(
                              loc.get(
                                _listMode ? 'graphView' : 'graphListView',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${loc.get('graphMatches')}: ${_filtered.length} · ${_graph!.nodes.length} ${loc.get('graphNodes')} · ${_graph!.edges.length} ${loc.get('graphEdges')}',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      if (!_listMode && _filtered.length > pageSize)
                        Text(
                          loc.get('graphPageScope'),
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _filtered.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.hub_outlined,
                              size: 40,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              loc.get(
                                tasks.isEmpty ? 'graphEmpty' : 'noSearchResult',
                              ),
                              textAlign: TextAlign.center,
                            ),
                            if (tasks.isNotEmpty)
                              TextButton(
                                onPressed: _reset,
                                child: Text(loc.get('graphResetFilters')),
                              ),
                          ],
                        ),
                      ),
                    )
                  : _listMode
                  ? ListView.builder(
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final task = _filtered[index];
                        return ListTile(
                          leading: Text('Q${task.quadrantLevel}'),
                          title: Text(
                            task.taskTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: task.taskSummary == null
                              ? null
                              : Text(
                                  task.taskSummary!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(task),
                        );
                      },
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final size = constraints.biggest;
                        if (_viewport != size || _needsFit) {
                          _viewport = size;
                          _needsFit = false;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && _viewport == size && !_listMode) {
                              _fit();
                            }
                          });
                        }
                        return InteractiveViewer(
                          transformationController: _transform,
                          constrained: false,
                          minScale: 0.1,
                          maxScale: 3.5,
                          boundaryMargin: const EdgeInsets.all(1400),
                          child: SizedBox(
                            width: canvasSize,
                            height: canvasSize,
                            child: KnowledgeGraphView(
                              graphData: _graph!,
                              selectedNodeId: _selected,
                              onNodeSelected: (node) =>
                                  setState(() => _selected = node?.id),
                              onNodeDoubleTap: (node) {
                                final task = _byId[node.id];
                                if (task != null) _open(task);
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (!_listMode && selected != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: bodyConstraints.maxHeight * 0.25,
                ),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                selected.taskTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              if (selected.taskSummary != null)
                                Text(
                                  selected.taskSummary!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              TextButton.icon(
                                onPressed: () => _open(selected),
                                icon: const Icon(Icons.open_in_new),
                                label: Text(loc.get('openTaskDetail')),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: loc.get('close'),
                          onPressed: () => setState(() => _selected = null),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (!_listMode && pageCount > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: loc.get('graphPreviousPage'),
                    onPressed: _page == 0
                        ? null
                        : () => setState(() {
                            _page--;
                            _graph = null;
                          }),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${_page + 1} / $pageCount'),
                  IconButton(
                    tooltip: loc.get('graphNextPage'),
                    onPressed: _page + 1 == pageCount
                        ? null
                        : () => setState(() {
                            _page++;
                            _graph = null;
                          }),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
    if (widget.embedded) {
      return WorkspaceToolFrame(
        title: loc.get('knowledgeGraphTitle'),
        icon: Icons.hub_outlined,
        embedded: true,
        onClose: widget.onClose,
        actions: [
          IconButton(
            tooltip: loc.get('resetGraphView'),
            onPressed: _fit,
            icon: const Icon(Icons.center_focus_strong_outlined),
          ),
        ],
        body: body,
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          loc.get('knowledgeGraphTitle'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: loc.get('resetGraphView'),
            onPressed: _fit,
            icon: const Icon(Icons.center_focus_strong_outlined),
          ),
        ],
      ),
      body: body,
    );
  }
}
