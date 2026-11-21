"""Static accessibility contract checks across lib/ui/ widgets."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
UI_ROOT = ROOT / 'lib' / 'ui'


def _balanced_call(text: str, open_paren_index: int) -> str:
    depth = 0
    i = open_paren_index
    in_quote = None
    escape = False
    while i < len(text):
        ch = text[i]
        if in_quote is not None:
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == in_quote:
                in_quote = None
        else:
            if ch in ("'", '"'):
                in_quote = ch
            elif ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
                if depth == 0:
                    return text[open_paren_index:i + 1]
        i += 1
    return text[open_paren_index:]


class UiAccessibilityLintTests(unittest.TestCase):
    def test_all_icon_buttons_have_tooltip_or_explicit_semantics_label(self):
        offenders = []
        pattern = re.compile(r'(?<!\w)IconButton(?:\.(?!styleFrom\b)\w+)?\s*\(')
        for path in sorted(UI_ROOT.rglob('*.dart')):
            text = path.read_text(encoding='utf-8')
            for match in pattern.finditer(text):
                call = _balanced_call(text, match.end() - 1)
                if 'tooltip:' in call:
                    continue
                context_before = text[max(0, match.start() - 260):match.start()]
                if 'Semantics(' in context_before and 'label:' in context_before:
                    continue
                line = text[:match.start()].count('\n') + 1
                offenders.append(f'{path.relative_to(ROOT)}:{line}')
        self.assertEqual(offenders, [], f'IconButton missing tooltip/Semantics label: {offenders}')

    def test_all_raw_switches_have_semantics_label(self):
        offenders = []
        pattern = re.compile(r'(?<!\w)Switch(?:\.adaptive)?\s*\(')
        for path in sorted(UI_ROOT.rglob('*.dart')):
            text = path.read_text(encoding='utf-8')
            for match in pattern.finditer(text):
                context_before = text[max(0, match.start() - 260):match.start()]
                if 'Semantics(' in context_before and 'label:' in context_before:
                    continue
                line = text[:match.start()].count('\n') + 1
                offenders.append(f'{path.relative_to(ROOT)}:{line}')
        self.assertEqual(offenders, [], f'Raw Switch missing Semantics label: {offenders}')

    def test_all_images_declare_semantic_label_or_exclude_from_semantics(self):
        offenders = []
        pattern = re.compile(r'(?<!\w)Image\.(file|asset|memory|network)\s*\(')
        for path in sorted(UI_ROOT.rglob('*.dart')):
            text = path.read_text(encoding='utf-8')
            for match in pattern.finditer(text):
                call = _balanced_call(text, match.end() - 1)
                if 'semanticLabel:' in call or 'excludeFromSemantics:' in call:
                    continue
                line = text[:match.start()].count('\n') + 1
                offenders.append(f'{path.relative_to(ROOT)}:{line}')
        self.assertEqual(offenders, [], f'Image missing semanticLabel/excludeFromSemantics: {offenders}')


if __name__ == '__main__':
    unittest.main()
