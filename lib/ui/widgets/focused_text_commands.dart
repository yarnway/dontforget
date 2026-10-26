import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// AppKit shortcuts must edit Flutter's value, not its accessibility proxy.
abstract final class FocusedTextCommands {
  static Future<bool> run(
    String command, {
    required bool Function() isCurrent,
  }) async {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    final editor = context?.findAncestorStateOfType<EditableTextState>();
    if (context == null || editor == null || !isCurrent()) return false;
    final original = editor.textEditingValue;
    bool valid() =>
        editor.mounted &&
        isCurrent() &&
        FocusManager.instance.primaryFocus == focus &&
        editor.widget.focusNode.hasFocus &&
        ModalRoute.of(context)?.isCurrent == true &&
        editor.widget.selectionEnabled &&
        editor.textEditingValue == original &&
        (!original.composing.isValid || original.composing.isCollapsed);
    if (!valid()) return false;
    if (command == 'selectAll') {
      if (editor.widget.readOnly && editor.widget.obscureText) return false;
      editor.selectAll(SelectionChangedCause.keyboard);
      return true;
    }
    final selection = original.selection;
    if (!selection.isValid || selection.end > original.text.length) {
      return false;
    }
    try {
      if (command == 'copy' || command == 'cut') {
        if (editor.widget.obscureText || selection.isCollapsed) return false;
        if (command == 'cut' && editor.widget.readOnly) return false;
        await Clipboard.setData(
          ClipboardData(text: selection.textInside(original.text)),
        );
        if (command == 'copy') return true;
        // A clipboard write must finish before removing the selected text.
        if (!valid()) return false;
        editor.userUpdateTextEditingValue(
          original.replaced(selection, ''),
          SelectionChangedCause.keyboard,
        );
        return true;
      }
      if (command == 'paste' && !editor.widget.readOnly) {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (data?.text == null || !valid()) return false;
        editor.userUpdateTextEditingValue(
          original
              .copyWith(
                selection: TextSelection.collapsed(offset: selection.end),
              )
              .replaced(selection, data!.text!),
          SelectionChangedCause.keyboard,
        );
        return true;
      }
    } on PlatformException {
      // Keep the draft untouched when the system clipboard is unavailable.
      return false;
    }
    return false;
  }
}
