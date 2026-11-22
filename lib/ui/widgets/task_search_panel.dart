import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/task_search_provider.dart';
import '../../services/task_search_index.dart';
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
  TaskSearchFilter _filter = TaskSearchFilter.all;
  TaskSearchSort _sort = TaskSearchSort.source;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _startRefresh();
    }
  }

  TaskSearchIndex? _countsIndex;
  String? _countsQuery;
  int? _countsMinute;
  Map<TaskSearchFilter, int> _cachedCounts = const {};

  Map<TaskSearchFilter, int> _filterCounts(
    TaskSearchIndex index,
    String query,
    DateTime now,
  ) {
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    if (identical(_countsIndex, index) &&
        _countsQuery == query &&
        _countsMinute == minute) {
      return _cachedCounts;
    }
    final allMatches = index.search(
      query,
      filter: TaskSearchFilter.all,
      includeAllWhenEmpty: true,
    );
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    var pending = 0;
    var today = 0;
    var overdue = 0;
    var completed = 0;
    for (final task in allMatches) {
      if (task.isCompleted) {
        completed++;
      } else {
        pending++;
        final trigger = task.triggerTime;
        final deadline = task.eventTime;
        if (trigger != null && trigger.isBefore(now)) {
          overdue++;
        }
        final due = deadline ?? trigger;
        if (task.isPinned ||
            (due != null && due.isBefore(tomorrow)) ||
            (trigger != null && trigger.isBefore(tomorrow))) {
          today++;
        }
      }
    }
    _countsIndex = index;
    _countsQuery = query;
    _countsMinute = minute;
    return _cachedCounts = {
      TaskSearchFilter.all: allMatches.length,
      TaskSearchFilter.pending: pending,
      TaskSearchFilter.today: today,
      TaskSearchFilter.overdue: overdue,
      TaskSearchFilter.completed: completed,
    };
  }

  void _startRefresh() {
    _refresh?.cancel();
    _refresh = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted &&
          (_filter == TaskSearchFilter.today ||
              _filter == TaskSearchFilter.overdue)) {
        setState(() {});
      }
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _reset() {
    setState(() {
      _filter = TaskSearchFilter.all;
      _sort = TaskSearchSort.source;
    });
    widget.onClearQuery();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final index = ref.watch(taskSearchIndexProvider);
    final now = DateTime.now();
    final filterCounts = _filterCounts(index, widget.query, now);
    final results = index.search(
      widget.query,
      filter: _filter,
      sort: _sort,
      includeAllWhenEmpty: true,
    );
    final positions = {
      for (var i = 0; i < results.length; i++) results[i].id: i,
    };
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
        constraints: const BoxConstraints(maxWidth: 960),
        child: CustomScrollView(
          key: ValueKey(('task-search-results', widget.query, _filter, _sort)),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                          ChoiceChip(
                            key: ValueKey('search-filter-${filter.name}'),
                            label: Text(
                              '${l10n.get(filterLabels[filter]!)} · ${filterCounts[filter] ?? 0}',
                            ),
                            selected: filter == _filter,
                            onSelected: (_) => setState(() => _filter = filter),
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
                            ),
                          ),
                        ),
                        PopupMenuButton<TaskSearchSort>(
                          key: const ValueKey('search-sort'),
                          tooltip: l10n.get('searchSort'),
                          initialValue: _sort,
                          onSelected: (value) => setState(() => _sort = value),
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
