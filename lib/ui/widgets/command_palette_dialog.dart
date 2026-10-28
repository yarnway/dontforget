import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';
import 'editable_text_menu.dart';

class CommandPaletteAction {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final String? shortcut;
  final VoidCallback onExecute;

  const CommandPaletteAction({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.shortcut,
    required this.onExecute,
  });
}

class CommandPaletteDialog extends StatefulWidget {
  final List<CommandPaletteAction> actions;
  const CommandPaletteDialog({super.key, required this.actions});

  static Future<void> show(
    BuildContext context,
    List<CommandPaletteAction> actions,
  ) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => CommandPaletteDialog(actions: actions),
    );
  }

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  final _searchController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  int _selectedIndex = 0;
  bool _executing = false;
  String _query = '';
  late List<CommandPaletteAction> _filteredActions;
  late List<String> _searchTerms;
  double _itemExtent = 76;

  @override
  void initState() {
    super.initState();
    _indexActions();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void didUpdateWidget(CommandPaletteDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.actions, oldWidget.actions)) _indexActions();
  }

  void _indexActions() {
    _searchTerms = [
      for (final action in widget.actions)
        '${action.id}\n${action.title}\n${action.subtitle}'.toLowerCase(),
    ];
    _filter();
  }

  void _filter() {
    _filteredActions = [
      for (var i = 0; i < widget.actions.length; i++)
        if (_query.isEmpty || _searchTerms[i].contains(_query))
          widget.actions[i],
    ];
    _selectedIndex = 0;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    // Caret and composing-range changes do not rebuild/filter the action list.
    if (_query == query) return;
    setState(() {
      _query = query;
      _filter();
    });
  }

  void _execute(CommandPaletteAction action) {
    if (_executing) return;
    _executing = true;
    Navigator.of(context).pop();
    action.onExecute();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final composing = _searchController.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      // Enter/arrow/Escape belong to the input method until composition ends.
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      if (_filteredActions.isNotEmpty) {
        setState(() {
          final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
          _selectedIndex = (_selectedIndex + delta) % _filteredActions.length;
        });
        if (_scrollController.hasClients) {
          final position = _scrollController.position;
          final start = _selectedIndex * _itemExtent;
          final end = start + _itemExtent;
          final target = start < position.pixels
              ? start
              : end > position.pixels + position.viewportDimension
              ? end - position.viewportDimension
              : position.pixels;
          _scrollController.jumpTo(target.clamp(0.0, position.maxScrollExtent));
        }
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_filteredActions.isNotEmpty) {
        _execute(_filteredActions[_selectedIndex]);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context);
    _itemExtent = 24 + scale.scale(14) * 2.5 + scale.scale(12) * 1.3;

    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        clipBehavior: Clip.antiAlias,
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _inputFocusNode,
                      autofocus: true,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      textAlignVertical: TextAlignVertical.center,
                      contextMenuBuilder: buildEditableTextMenu,
                      decoration: InputDecoration(
                        hintText: loc.get('commandSearchHint'),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: loc.get('close'),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _filteredActions.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          loc.get('noSearchResult'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemExtent: _itemExtent,
                      itemCount: _filteredActions.length,
                      itemBuilder: (context, index) {
                        final action = _filteredActions[index];
                        final selected = index == _selectedIndex;
                        return Semantics(
                          selected: selected,
                          button: true,
                          child: Tooltip(
                            message: '${action.title}\n${action.subtitle}',
                            child: MouseRegion(
                              // Only pointer movement changes selection. A row
                              // entering beneath a stationary pointer during
                              // keyboard scrolling must not steal selection.
                              onHover: (_) {
                                if (_selectedIndex != index) {
                                  setState(() => _selectedIndex = index);
                                }
                              },
                              child: InkWell(
                                onTap: () => _execute(action),
                                child: Ink(
                                  color: selected
                                      ? colors.secondaryContainer
                                      : null,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        action.icon,
                                        size: 22,
                                        color: colors.primary,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              action.title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                height: 1.25,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Text(
                                              action.subtitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                height: 1.3,
                                                color: colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (action.shortcut != null &&
                                          MediaQuery.sizeOf(context).width >=
                                              600)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 12,
                                          ),
                                          child: Text(
                                            action.shortcut!,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            LayoutBuilder(
              builder: (context, constraints) {
                // Tiny/keyboard-constrained windows keep the search and results
                // usable; the close control and keyboard actions still work.
                final usableHeight =
                    MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).bottom;
                if (usableHeight < 400) return const SizedBox.shrink();
                return Padding(
                  padding: EdgeInsets.all(
                    math.min(12, constraints.maxWidth / 30),
                  ),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      Text(
                        '↑↓ ${loc.get('commandNavigate')}',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        'Enter ${loc.get('commandExecute')}',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        'Esc ${loc.get('close')}',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
