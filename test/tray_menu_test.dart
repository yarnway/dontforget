import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/l10n/app_localizations.dart';

void main() {
  group('Tray menu localizations', () {
    test('provides English labels for tray menu', () {
      final l10n = AppLocalizations(const Locale('en'));
      expect(l10n.get('trayShowWindow'), 'Show window');
      expect(l10n.get('trayExitApp'), 'Exit');
    });

    test('provides Chinese labels for tray menu', () {
      final l10n = AppLocalizations(const Locale('zh'));
      expect(l10n.get('trayShowWindow'), '显示窗口');
      expect(l10n.get('trayExitApp'), '退出');
    });

    test('provides Japanese labels for tray menu', () {
      final l10n = AppLocalizations(const Locale('ja'));
      expect(l10n.get('trayShowWindow'), 'ウィンドウを表示');
      expect(l10n.get('trayExitApp'), '終了');
    });
  });
}
