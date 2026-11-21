import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/l10n/notification_diagnostics_strings.dart';
import 'package:dont_forget/l10n/shared_text_strings.dart';
import 'package:dont_forget/l10n/task_attachment_strings.dart';
import 'package:dont_forget/l10n/task_consistency_strings.dart';
import 'package:dont_forget/ui/formatters/byte_size.dart';
import 'package:dont_forget/ui/screens/storage_unavailable_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _placeholderPattern = RegExp(r'\{[a-zA-Z0-9_]+\}');

Set<String> _placeholders(String value) =>
    _placeholderPattern.allMatches(value).map((m) => m.group(0)!).toSet();

void _assertLocaleMapParity(
  String mapName,
  Map<String, Map<String, String>> table,
) {
  expect(table.keys, containsAll(['en', 'zh', 'ja']), reason: mapName);
  final en = table['en']!;
  final zh = table['zh']!;
  final ja = table['ja']!;

  expect(
    zh.keys.toSet(),
    equals(en.keys.toSet()),
    reason:
        '$mapName zh keys drift: missing=${en.keys.toSet().difference(zh.keys.toSet())}, '
        'extra=${zh.keys.toSet().difference(en.keys.toSet())}',
  );
  expect(
    ja.keys.toSet(),
    equals(en.keys.toSet()),
    reason:
        '$mapName ja keys drift: missing=${en.keys.toSet().difference(ja.keys.toSet())}, '
        'extra=${ja.keys.toSet().difference(en.keys.toSet())}',
  );

  for (final key in en.keys) {
    final enVal = en[key]!;
    final zhVal = zh[key]!;
    final jaVal = ja[key]!;
    expect(enVal.trim(), isNotEmpty, reason: '$mapName en.$key empty');
    expect(zhVal.trim(), isNotEmpty, reason: '$mapName zh.$key empty');
    expect(jaVal.trim(), isNotEmpty, reason: '$mapName ja.$key empty');

    final enPh = _placeholders(enVal);
    expect(
      _placeholders(zhVal),
      equals(enPh),
      reason: '$mapName placeholder mismatch in zh.$key',
    );
    expect(
      _placeholders(jaVal),
      equals(enPh),
      reason: '$mapName placeholder mismatch in ja.$key',
    );
  }
}

void main() {
  test('All core and merged localization tables have 100% en/zh/ja key and placeholder parity', () {
    _assertLocaleMapParity(
      'AppLocalizations',
      AppLocalizations.debugLocalizedValues,
    );
    _assertLocaleMapParity('taskAttachmentStrings', taskAttachmentStrings);
    _assertLocaleMapParity('taskConsistencyStrings', taskConsistencyStrings);
    _assertLocaleMapParity(
      'notificationDiagnosticsStrings',
      notificationDiagnosticsStrings,
    );
  });

  test('AppLocalizations falls back to English for unsupported locales across merged maps', () {
    final fallback = AppLocalizations(const Locale('fr'));
    expect(fallback.get('appTitle'), AppLocalizations(const Locale('en')).get('appTitle'));
    expect(
      fallback.get('taskAttachments'),
      taskAttachmentStrings['en']!['taskAttachments'],
    );
    expect(
      fallback.get('taskChecklistProgress'),
      taskConsistencyStrings['en']!['taskChecklistProgress'],
    );
    expect(
      fallback.get('notificationDiagnosticsTitle'),
      notificationDiagnosticsStrings['en']!['notificationDiagnosticsTitle'],
    );
  });

  test('formatByteSize handles B, KiB, MiB, GiB and negative inputs safely', () {
    expect(formatByteSize(-10), '0 B');
    expect(formatByteSize(0), '0 B');
    expect(formatByteSize(512), '512 B');
    expect(formatByteSize(4096), '4.00 KiB');
    expect(formatByteSize(4096, fractionDigits: 1), '4.0 KiB');
    expect(formatByteSize(2 * 1024 * 1024), '2.00 MiB');
    expect(formatByteSize(3 * 1024 * 1024 * 1024), '3.00 GiB');
  });

  testWidgets('StorageUnavailableScreen displays zh/en/ja guidance for busy and error states', (
    tester,
  ) async {
    for (final busy in [true, false]) {
      await tester.pumpWidget(
        StorageUnavailableScreen(busy: busy, onExit: () {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('退出 / Exit / 終了'), findsOneWidget);
      if (busy) {
        expect(find.textContaining('Local data is in use'), findsOneWidget);
        expect(find.textContaining('別の DontForget'), findsOneWidget);
      } else {
        expect(find.textContaining('Unable to open local data'), findsOneWidget);
        expect(find.textContaining('復旧記録は保持されています'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });

  test('sharedTextLabel hint describes text, links, images, and files in zh/en/ja', () {
    expect(sharedTextLabel('zh', 'hint'), contains('图片'));
    expect(sharedTextLabel('zh', 'hint'), contains('文件'));
    expect(sharedTextLabel('en', 'hint'), contains('images'));
    expect(sharedTextLabel('en', 'hint'), contains('files'));
    expect(sharedTextLabel('ja', 'hint'), contains('画像'));
    expect(sharedTextLabel('ja', 'hint'), contains('ファイル'));
  });
}
