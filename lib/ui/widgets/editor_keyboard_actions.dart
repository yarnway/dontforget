import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Editor commands yield to modal routes and active input-method composition.
class EditorKeyboardActions extends StatelessWidget {
  const EditorKeyboardActions({
    super.key,
    required this.child,
    required this.onSave,
    required this.onExit,
  });
  final Widget child;
  final VoidCallback onSave, onExit;

  /// AppKit can consume a key equivalent before Flutter receives key events.
  /// Resolve the focused editor each time; never retain a stale route callback.
  static bool saveFocusedEditor() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !_canAct(context)) return false;
    final editor = context
        .findAncestorWidgetOfExactType<EditorKeyboardActions>();
    if (editor == null) return false;
    editor.onSave();
    return true;
  }

  static bool _canAct(BuildContext context) {
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final focus = FocusManager.instance.primaryFocus?.context;
    final editor = focus?.widget is EditableText
        ? focus!.widget as EditableText
        : focus?.findAncestorWidgetOfExactType<EditableText>();
    final composing = editor?.controller.value.composing;
    return composing == null || !composing.isValid || composing.isCollapsed;
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    skipTraversal: true,
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent || !_canAct(context)) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        onExit();
        return KeyEventResult.handled;
      }
      final keys = HardwareKeyboard.instance;
      if (event.logicalKey == LogicalKeyboardKey.keyS &&
          (keys.isMetaPressed || keys.isControlPressed) &&
          !keys.isAltPressed &&
          !keys.isShiftPressed) {
        onSave();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: child,
  );
}
