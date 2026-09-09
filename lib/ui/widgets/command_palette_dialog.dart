import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';

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

  const CommandPaletteDialog({
    super.key,
    required this.actions,
  });

  static Future<void> show(BuildContext context, List<CommandPaletteAction> actions) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (ctx) => CommandPaletteDialog(actions: actions),
    );
  }

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  int _selectedIndex = 0;
  List<CommandPaletteAction> _filteredActions = [];

  @override
  void initState() {
    super.initState();
    _filteredActions = widget.actions;
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredActions = widget.actions;
      } else {
        _filteredActions = widget.actions.where((action) {
          return action.id.toLowerCase().contains(query) ||
              action.title.toLowerCase().contains(query) ||
              action.subtitle.toLowerCase().contains(query);
        }).toList();
      }
      _selectedIndex = 0;
    });
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_filteredActions.isNotEmpty) {
        setState(() {
          _selectedIndex = (_selectedIndex + 1) % _filteredActions.length;
        });
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_filteredActions.isNotEmpty) {
        setState(() {
          _selectedIndex = (_selectedIndex - 1 + _filteredActions.length) % _filteredActions.length;
        });
      }
    } else if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (_filteredActions.isNotEmpty && _selectedIndex < _filteredActions.length) {
        final action = _filteredActions[_selectedIndex];
        Navigator.of(context).pop();
        action.onExecute();
      }
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: _handleKeyEvent,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E2028) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? const Color(0xFF383B4A) : const Color(0xFFE2E8F0),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 32,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Search Input Area
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.terminal,
                          size: 24,
                          color: theme.primaryColor,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            focusNode: _inputFocusNode,
                            autofocus: true,
                            style: const TextStyle(
                              fontSize: 15,
                              fontFamily: 'Consolas',
                              letterSpacing: 0.3,
                            ),
                            decoration: InputDecoration(
                              hintText: loc.translate('cmdHint'),
                              hintStyle: TextStyle(
                                fontSize: 14,
                                color: isDark ? Colors.white38 : Colors.black38,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'ESC',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: isDark ? const Color(0xFF383B4A) : const Color(0xFFE2E8F0),
                  ),

                  // Actions List
                  Flexible(
                    child: _filteredActions.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(36),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search_off,
                                  size: 40,
                                  color: isDark ? Colors.white24 : Colors.black26,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  loc.translate('noSearchResult'),
                                  style: TextStyle(
                                    color: isDark ? Colors.white38 : Colors.black45,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shrinkWrap: true,
                            itemCount: _filteredActions.length,
                            itemBuilder: (context, index) {
                              final action = _filteredActions[index];
                              final isSelected = index == _selectedIndex;

                              return InkWell(
                                onTap: () {
                                  Navigator.of(context).pop();
                                  action.onExecute();
                                },
                                onHover: (hovering) {
                                  if (hovering) {
                                    setState(() {
                                      _selectedIndex = index;
                                    });
                                  }
                                },
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 2,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? (isDark
                                            ? theme.primaryColor.withValues(alpha: 0.2)
                                            : theme.primaryColor.withValues(alpha: 0.1))
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                    border: isSelected
                                        ? Border.all(
                                            color: theme.primaryColor.withValues(alpha: 0.5),
                                            width: 1,
                                          )
                                        : null,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        action.icon,
                                        size: 20,
                                        color: isSelected
                                            ? theme.primaryColor
                                            : (isDark ? Colors.white60 : Colors.black54),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              action.title,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: isSelected
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                                color: isDark ? Colors.white : Colors.black87,
                                              ),
                                            ),
                                            if (action.subtitle.isNotEmpty)
                                              Text(
                                                action.subtitle,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: isDark ? Colors.white38 : Colors.black45,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (action.shortcut != null)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isDark ? Colors.white10 : Colors.black12,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            action.shortcut!,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontFamily: 'Consolas',
                                              color: isDark ? Colors.white70 : Colors.black54,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),

                  // Footer hints
                  Divider(
                    height: 1,
                    color: isDark ? const Color(0xFF383B4A) : const Color(0xFFE2E8F0),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF181A20) : const Color(0xFFF8FAFC),
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          loc.translate('keyboardShortcuts'),
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.black45,
                          ),
                        ),
                        Row(
                          children: [
                            _buildKeyHint('↑↓', 'Navigate', isDark),
                            const SizedBox(width: 10),
                            _buildKeyHint('↵', 'Execute', isDark),
                            const SizedBox(width: 10),
                            _buildKeyHint('Esc', 'Close', isDark),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyHint(String keyLabel, String actionLabel, bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: isDark ? Colors.white12 : Colors.black12,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            keyLabel,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          actionLabel,
          style: TextStyle(
            fontSize: 10,
            color: isDark ? Colors.white38 : Colors.black45,
          ),
        ),
      ],
    );
  }
}
