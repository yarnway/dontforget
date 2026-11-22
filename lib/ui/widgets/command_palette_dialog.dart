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
  static final _whitespace = RegExp(r'\s+');
  late List<CommandPaletteAction> _filteredActions;
  late List<({String title, String shortcut, String full})> _searchIndex;
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
    _searchIndex = [
      for (final action in widget.actions)
        (
          title: action.title.toLowerCase(),
          shortcut: (action.shortcut ?? '').trim().toLowerCase(),
          full:
              '${action.id}\n${action.title}\n${action.subtitle}\n${action.shortcut ?? ''}'
                  .toLowerCase(),
        ),
    ];
    _filter();
  }

  void _filter() {
    if (_query.isEmpty) {
      _filteredActions = List<CommandPaletteAction>.of(widget.actions);
    } else {
      final tokens = _query.split(_whitespace);
      final primary = <CommandPaletteAction>[];
      final secondary = <CommandPaletteAction>[];
      for (var i = 0; i < widget.actions.length; i++) {
        final entry = _searchIndex[i];
        if (!tokens.every(entry.full.contains)) continue;
        final prefixMatch =
            entry.title.startsWith(_query) ||
            (entry.shortcut.isNotEmpty && entry.shortcut.startsWith(_query));
        (prefixMatch ? primary : secondary).add(widget.actions[i]);
      }
      _filteredActions = [...primary, ...secondary];
    }
    _selectedIndex = 0;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _selectIndex(int index) {
    if (_filteredActions.isEmpty) return;
    final clamped = index.clamp(0, _filteredActions.length - 1);
    setState(() => _selectedIndex = clamped);
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
        final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
        _selectIndex((_selectedIndex + delta) % _filteredActions.length);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home && _query.isEmpty) {
      _selectIndex(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end && _query.isEmpty) {
      _selectIndex(_filteredActions.length - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _selectIndex(_selectedIndex - 5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _selectIndex(_selectedIndex + 5);
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
        backgroundColor: colors.surfaceContainerHigh,
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
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty) ...[
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          '${_filteredActions.length}',
                          key: const ValueKey('command-palette-count'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: loc.get('clearSearch'),
                      onPressed: () {
                        _searchController.clear();
                        _inputFocusNode.requestFocus();
                      },
                      icon: const Icon(Icons.backspace_outlined, size: 18),
                    ),
                  ],
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
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerHighest,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.search_off_rounded,
                                color: colors.onSurfaceVariant,
                                size: 24,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              loc.get('noSearchResult'),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                            if (_query.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () {
                                  _searchController.clear();
                                  _inputFocusNode.requestFocus();
                                },
                                child: Text(loc.get('clearSearch')),
                              ),
                            ],
                          ],
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
                        final shortcut = action.shortcut?.trim();
                        return Semantics(
                          selected: selected,
                          button: true,
                          label: '${action.title}, ${action.subtitle}',
                          child: MouseRegion(
                            // Only pointer movement changes selection. A row
                            // entering beneath a stationary pointer during
                            // keyboard scrolling must not steal selection.
                            onHover: (_) {
                              if (_selectedIndex != index) {
                                setState(() => _selectedIndex = index);
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _execute(action),
                                child: Ink(
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? colors.secondaryContainer
                                        : null,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      AnimatedContainer(
                                        duration:
                                            MediaQuery.disableAnimationsOf(
                                                  context,
                                                )
                                                ? Duration.zero
                                                : const Duration(
                                                    milliseconds: 120,
                                                  ),
                                        width: 3,
                                        height: selected ? 24 : 0,
                                        margin: const EdgeInsets.only(
                                          right: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: selected
                                              ? colors.primary
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        action.icon,
                                        size: 22,
                                        color: selected
                                            ? colors.onSecondaryContainer
                                            : colors.primary,
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
                                              style: TextStyle(
                                                fontSize: 14,
                                                height: 1.25,
                                                fontWeight: FontWeight.w600,
                                                color: selected
                                                    ? colors
                                                          .onSecondaryContainer
                                                    : colors.onSurface,
                                              ),
                                            ),
                                            Text(
                                              action.subtitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                height: 1.3,
                                                color: selected
                                                    ? colors
                                                          .onSecondaryContainer
                                                          .withValues(
                                                            alpha: 0.85,
                                                          )
                                                    : colors.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (shortcut != null &&
                                          shortcut.isNotEmpty &&
                                          MediaQuery.sizeOf(context).width >=
                                              600)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 12,
                                          ),
                                          child: _Keycap(label: shortcut),
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
                      _FooterHint(
                        keys: '↑↓',
                        label: loc.get('commandNavigate'),
                      ),
                      _FooterHint(
                        keys: 'Enter',
                        label: loc.get('commandExecute'),
                      ),
                      _FooterHint(keys: 'Esc', label: loc.get('close')),
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

class _Keycap extends StatelessWidget {
  const _Keycap({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.9)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      ),
    );
  }
}

class _FooterHint extends StatelessWidget {
  const _FooterHint({required this.keys, required this.label});
  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Keycap(label: keys),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}
