import 'package:flutter/material.dart';

/// Keep a full-field selection action available on desktop, where the default
/// toolbar can omit it even when the caret is inside an editable paragraph.
Widget buildEditableTextMenu(BuildContext context, EditableTextState state) {
  final items = [...state.contextMenuButtonItems];
  final value = state.textEditingValue;
  final selection = value.selection;
  final fullySelected =
      selection.isValid &&
      selection.start == 0 &&
      selection.end == value.text.length;
  if (value.text.isNotEmpty &&
      !state.widget.obscureText &&
      !fullySelected &&
      !items.any((item) => item.type == ContextMenuButtonType.selectAll)) {
    items.add(
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: () => state.selectAll(SelectionChangedCause.toolbar),
      ),
    );
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: items,
  );
}
