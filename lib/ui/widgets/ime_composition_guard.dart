import 'package:flutter/widgets.dart';

/// Returns true when an active IME preedit composition (e.g. Pinyin / Kana)
/// is uncommitted in [controller], so Enter/Submit/live-search handlers do not
/// prematurely commit or discard phonetic fragments.
bool isImeComposing(TextEditingController controller) {
  final composing = controller.value.composing;
  return composing.isValid && !composing.isCollapsed;
}
