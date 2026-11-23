import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import '../../providers/task_search_provider.dart';
import '../../services/task_search_index.dart';
import '../theme/app_theme.dart';
import 'task_card.dart';

/// Search and browsing share one lazy list, including an empty search query.
class TaskSearchPanel extends ConsumerStatefulWidget {
  const TaskSearchPanel({
    super.key,
    required this.query,
    required this.onClearQuery,
    required this.onPlayMedia,
  });

  final String query;
  final VoidCallback onClearQuery;
  final ValueChanged<String> onPlayMedia;

  @override
  ConsumerState<TaskSearchPanel> createState() => _TaskSearchPanelState();
}

class _TaskSearchPanelState extends ConsumerState<TaskSearchPanel>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  TaskSearchFilter _filter = TaskSearchFilter.all;
  TaskSearchSort _sort = TaskSearchSort.source;
  Timer? _refresh;
  TaskSearchIndex? _projectedIndex;
  String? _projectedQuery;
  TaskSearchFilter? _projectedFilter;
  TaskSearchSort? _projectedSort;
  int? _projectedMinute;
  List<Reminder> _cachedResults = const [];
  Map<TaskSearchFilter, int> _cachedCounts = const {};
  Map<String, int> _cachedPositions = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _startRefresh();
    }
  }

  @override
  void didUpdateWidget(TaskSearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _scrollToTop();
    }
  }

  void _scrollToTop() {
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.jumpTo(0);
    }
  }

  void _ensureProjected(TaskSearchIndex index, DateTime now) {
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    if (identical(_projectedIndex, index) &&
        _projectedQuery == widget.query &&
        _projectedFilter == _filter &&
        _projectedSort == _sort &&
        _projectedMinute == minute) {
      return;
    }
    final projected = index.project(
      widget.query,
      filter: _filter,
      sort: _sort,
      includeAllWhenEmpty: true,
      now: now,
    );
    _projectedIndex = index;
    _projectedQuery = widget.query;
    _projectedFilter = _filter;
    _projectedSort = _sort;
    _projectedMinute = minute;
    _cachedResults = projected.results;
    _cachedCounts = projected.counts;
    _cachedPositions = {
      for (var i = 0; i < projected.results.length; i++)
        projected.results[i].id: i,
    };
  }

  void _startRefresh() {
    _refresh?.cancel();
    _refresh = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) setState(() {});
      _startRefresh();
    } else {
      _refresh?.cancel();
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _scrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _reset() {
    setState(() {
      _filter = TaskSearchFilter.all;
      _sort = TaskSearchSort.source;
    });
    _scrollToTop();
    widget.onClearQuery();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final index = ref.watch(taskSearchIndexProvider);
    final now = DateTime.now();
    _ensureProjected(index, now);
    final filterCounts = _cachedCounts;
    final results = _cachedResults;
    final positions = _cachedPositions;
    final hasConditions =
        widget.query.trim().isNotEmpty ||
        _filter != TaskSearchFilter.all ||
        _sort != TaskSearchSort.source;
    final filterLabels = {
      TaskSearchFilter.all: 'searchAll',
      TaskSearchFilter.pending: 'searchPending',
      TaskSearchFilter.today: 'searchToday',
      TaskSearchFilter.overdue: 'searchOverdue',
      TaskSearchFilter.completed: 'completed',
    };
    final sortLabels = {
      TaskSearchSort.source: 'searchSortDefault',
      TaskSearchSort.dueSoonest: 'searchSortDue',
      TaskSearchSort.newest: 'searchSortNewest',
    };

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.workspaceMaxWidth),
        child: CustomScrollView(
          controller: _scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.get('searchBrowseTitle'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.get('searchBrowseHint'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final filter in TaskSearchFilter.values)
                          Builder(
                            builder: (context) {
                              final count = filterCounts[filter] ?? 0;
                              final highlightOverdue =
                                  filter == TaskSearchFilter.overdue &&
                                  count > 0 &&
                                  filter != _filter;
                              return ChoiceChip(
                                key: ValueKey('search-filter-${filter.name}'),
                                side: highlightOverdue
                                    ? BorderSide(
                                        color: colors.error.withValues(
                                          alpha: 0.45,
                                        ),
                                      )
                                    : null,
                                label: Text(
                                  '${l10n.get(filterLabels[filter]!)} · $count',
                                  style: TextStyle(
                                    fontFeatures: AppTheme.tabularFigures,
                                    color: highlightOverdue
                                        ? colors.error
                                        : null,
                                  ),
                                ),
                                selected: filter == _filter,
                                onSelected: (_) {
                                  if (_filter == filter) return;
                                  setState(() => _filter = filter);
                                  _scrollToTop();
                                },
                              );
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            '${l10n.get('searchResults')} · ${results.length}',
                            key: const ValueKey('search-result-count'),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontFeatures: AppTheme.tabularFigures,
                            ),
                          ),
                        ),
                        PopupMenuButton<TaskSearchSort>(
                          key: const ValueKey('search-sort'),
                          tooltip: l10n.get('searchSort'),
                          initialValue: _sort,
                          onSelected: (value) {
                            if (_sort == value) return;
                            setState(() => _sort = value);
                            _scrollToTop();
                          },
                          itemBuilder: (_) => [
                            for (final sort in TaskSearchSort.values)
                              CheckedPopupMenuItem(
                                value: sort,
                                checked: sort == _sort,
                                child: Text(l10n.get(sortLabels[sort]!)),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.sort_rounded, size: 18),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    l10n.get(sortLabels[_sort]!),
                                    style: theme.textTheme.labelLarge,
                                  ),
                                ),
                                const Icon(
                                  Icons.arrow_drop_down_rounded,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (hasConditions)
                          TextButton.icon(
                            key: const ValueKey('search-reset'),
                            onPressed: _reset,
                            icon: const Icon(
                              Icons.restart_alt_rounded,
                              size: 18,
                            ),
                            label: Text(l10n.get('searchReset')),
                          ),
                      ],
                    ),
                    Divider(color: colors.outlineVariant),
                  ],
                ),
              ),
            ),
            if (results.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer.withValues(
                            alpha: 0.65,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          hasConditions
                              ? Icons.search_off_rounded
                              : Icons.checklist_rounded,
                          color: colors.onPrimaryContainer,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.get(
                          hasConditions ? 'noSearchResult' : 'searchEmptyTitle',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.get(
                          hasConditions
                              ? 'searchEmptyHint'
                              : 'searchCreateHint',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (hasConditions) ...[
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          onPressed: _reset,
                          icon: const Icon(
                            Icons.restart_alt_rounded,
                            size: 18,
                          ),
                          label: Text(l10n.get('searchReset')),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final task = results[index];
                      return TaskCard(
                        key: ValueKey(task.id),
                        task: task,
                        referenceNow: now,
                        onPlayMedia: () {
                          if (task.recordId != null) {
                            widget.onPlayMedia(task.recordId!);
                          }
                        },
                      );
                    },
                    childCount: results.length,
                    findChildIndexCallback: (key) =>
                        key is ValueKey<String> ? positions[key.value] : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
