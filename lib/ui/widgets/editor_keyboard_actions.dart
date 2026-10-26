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

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    skipTraversal: true,
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent || ModalRoute.of(context)?.isCurrent != true) {
        return KeyEventResult.ignored;
      }
      final focus = FocusManager.instance.primaryFocus?.context;
      final editor = focus?.widget is EditableText
          ? focus!.widget as EditableText
          : focus?.findAncestorWidgetOfExactType<EditableText>();
      final composing = editor?.controller.value.composing;
      if (composing != null && composing.isValid && !composing.isCollapsed) {
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
