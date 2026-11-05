import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/global_capture_provider.dart';
import 'package:dont_forget/services/global_capture_shortcut.dart';
import 'package:dont_forget/services/recovery/runtime_gate.dart';
import 'package:dont_forget/ui/widgets/global_capture_shortcut_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Conflict implements CaptureShortcutBackend {
  @override
  void listen(void Function(String) receive) {}
  @override
  Future<bool> setEnabled(bool value, String nonce) async => !value;
  @override
  void dispose() {}
}

void main() {
  testWidgets(
    'shortcut conflict and retry fit three languages on narrow and desktop windows',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final shortcut = GlobalCaptureShortcut(
        backend: _Conflict(),
        runtime: RuntimeRecoveryGate(),
        readSaved: () async => false,
        writeSaved: (_) async {},
      );
      final container = ProviderContainer(
        overrides: [
          globalCaptureShortcutProvider.overrideWith((_) => shortcut),
        ],
      );
      addTearDown(container.dispose);
      await shortcut.start(() {});
      await shortcut.setEnabled(true);
      expect(shortcut.error, 'conflict');
      for (final size in [const Size(320, 568), const Size(1440, 900)]) {
        tester.view.physicalSize = size;
        for (final language in ['zh', 'en', 'ja']) {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                locale: Locale(language),
                supportedLocales: const [
                  Locale('zh'),
                  Locale('en'),
                  Locale('ja'),
                ],
                localizationsDelegates: const [
                  AppLocalizationsDelegate(),
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                builder: (_, child) => MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: const TextScaler.linear(2),
                  ),
                  child: child!,
                ),
                home: const Scaffold(
                  body: SingleChildScrollView(
                    child: GlobalCaptureShortcutPanel(),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$size / $language');
          expect(
            find.byKey(const ValueKey('global-capture-enabled')),
            findsOneWidget,
          );
          expect(find.byType(TextButton), findsOneWidget);
        }
      }
    },
  );
}
