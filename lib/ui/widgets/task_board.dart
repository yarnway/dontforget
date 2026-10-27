import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/providers.dart';
import 'task_board_data.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reminder.dart';
import 'quadrant_view.dart';

/// A single readable category on phones, four quadrants on larger workspaces.
class TaskBoard extends ConsumerStatefulWidget {
  final List<Reminder> reminders;
  final void Function(String) onPlayMedia;

  const TaskBoard({
    super.key,
    required this.reminders,
    required this.onPlayMedia,
  });

  @override
  ConsumerState<TaskBoard> createState() => _TaskBoardState();
}

class _TaskBoardState extends ConsumerState<TaskBoard>
    with WidgetsBindingObserver {
  static const _icons = [
    Icons.notifications_active_outlined,
    Icons.star_outline_rounded,
    Icons.checklist_rounded,
    Icons.notes_rounded,
  ];
  List<FocusNode>? _categoryFocus;
  List<FocusNode> get _categoryNodes =>
      _categoryFocus ??= List.generate(4, (_) => FocusNode());
  int? _manualCategory;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startRefresh();
  }

  void _startRefresh() {
    _refresh?.cancel();
    // Time labels and the 48-hour memo fold need no page-wide heartbeat.
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
    WidgetsBinding.instance.removeObserver(this);
    for (final node in _categoryFocus ?? const <FocusNode>[]) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleCategoryKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final next = switch (key) {
      LogicalKeyboardKey.arrowRight => (index + 1) % 4,
      LogicalKeyboardKey.arrowLeft => (index + 3) % 4,
      LogicalKeyboardKey.arrowDown => (index + 2) % 4,
      LogicalKeyboardKey.arrowUp => (index + 2) % 4,
      LogicalKeyboardKey.home => 0,
      LogicalKeyboardKey.end => 3,
      _ => null,
    };
    if (next == null) return KeyEventResult.ignored;
    setState(() => _manualCategory = next);
    _categoryNodes[next].requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _categoryNodes[next].context;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 150),
        );
      }
    });
    return KeyEventResult.handled;
  }

  Widget _categoryButton(
    BuildContext context,
    int index,
    int pending,
    int selection, {
    bool singleLine = false,
  }) {
    final selected = selection == index;
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? colors.onPrimaryContainer : colors.onSurface;
    return Semantics(
      selected: selected,
      child: Focus(
        onKeyEvent: (_, event) => _handleCategoryKey(index, event),
        child: TextButton(
          key: ValueKey('category-${index + 1}'),
          focusNode: _categoryNodes[index],
          onPressed: () => setState(() => _manualCategory = index),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 56),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            // AnimatedTheme already interpolates the matching foreground and
            // surface. A second button transition would lag behind that pair.
            animationDuration: Duration.zero,
            foregroundColor: foreground,
            backgroundColor: selected
                ? colors.primaryContainer
                : colors.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: selected ? colors.primary : colors.outlineVariant,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(_icons[index], size: 18, color: foreground),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  l10n.get('cat${index + 1}'),
                  maxLines: singleLine ? 1 : null,
                  overflow: singleLine ? TextOverflow.ellipsis : null,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Semantics(
                label: '${l10n.get('pending')}: $pending',
                excludeSemantics: true,
                child: Text(
                  '$pending',
                  style: TextStyle(color: foreground, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final categoryColors = [
      colors.error,
      colors.tertiary,
      colors.secondary,
      colors.primary,
    ];
    final urgency = ref.watch(dynamicUrgencyServiceProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        // One clock reading gives every row the same boundary and avoids
        // thousands of DateTime allocations in a large wide-board frame.
        final compact =
            constraints.maxWidth < 640 || constraints.maxHeight < 320;
        final projectionTime = DateTime.now();
        final data = TaskBoardData.project(
          widget.reminders,
          visibleCategory: compact ? _manualCategory : null,
          selectFirstNonEmpty: compact && _manualCategory == null,
          isFolded: (task) =>
              urgency.isQ4StagnantFolded(task, now: projectionTime),
        );
        final pending = data.pending;
        final selection = data.visibleCategory ?? 0;
        Widget panel(int index, {bool showHeader = true}) => QuadrantView(
          key: ValueKey('quadrant-${index + 1}'),
          level: index + 1,
          showHeader: showHeader,
          titleIcon: Icon(
            _icons[index],
            size: 20,
            color: categoryColors[index],
          ),
          allReminders: const [],
          sections: data.sections[index],
          bgColor: categoryColors[index],
          onPlayMedia: widget.onPlayMedia,
        );
        if (compact) {
          return Padding(
            padding: constraints.maxHeight < 320
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
                : const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              key: const ValueKey('compact-task-board'),
              children: [
                FocusTraversalGroup(
                  child: constraints.maxHeight < 320
                      ? SingleChildScrollView(
                          key: const ValueKey('short-category-picker'),
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (var index = 0; index < 4; index++) ...[
                                if (index > 0) const SizedBox(width: 8),
                                SizedBox(
                                  width: 180,
                                  child: _categoryButton(
                                    context,
                                    index,
                                    pending[index],
                                    selection,
                                    singleLine: true,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        )
                      : Column(
                          children: [
                            for (var row = 0; row < 2; row++) ...[
                              if (row > 0) const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: _categoryButton(
                                      context,
                                      row * 2,
                                      pending[row * 2],
                                      selection,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _categoryButton(
                                      context,
                                      row * 2 + 1,
                                      pending[row * 2 + 1],
                                      selection,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                ),
                SizedBox(height: constraints.maxHeight < 320 ? 6 : 12),
                Expanded(
                  child: panel(
                    selection,
                    showHeader: constraints.maxHeight >= 200,
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            key: const ValueKey('expanded-task-board'),
            children: [
              for (var row = 0; row < 2; row++) ...[
                if (row > 0) const SizedBox(height: 12),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: panel(row * 2)),
                      const SizedBox(width: 12),
                      Expanded(child: panel(row * 2 + 1)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
