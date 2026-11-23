import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/global_capture_provider.dart';
import 'package:dont_forget/services/global_capture_shortcut.dart';
import 'package:dont_forget/services/recovery/runtime_gate.dart';
import 'package:dont_forget/ui/widgets/global_capture_shortcut_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements CaptureShortcutBackend {
  _Backend({this.conflict = false});

  final bool conflict;

  @override
  void listen(void Function(String) receive) {}
  @override
  Future<bool> setEnabled(bool value, String nonce) async =>
      !value || !conflict;
  @override
  void dispose() {}
}

Widget _panelApp(
  ProviderContainer container, {
  Locale locale = const Locale('en'),
  TransitionBuilder? builder,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    locale: locale,
    supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
    localizationsDelegates: const [
      AppLocalizationsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: builder,
    home: const Scaffold(
      body: SingleChildScrollView(child: GlobalCaptureShortcutPanel()),
    ),
  ),
);

void main() {
  testWidgets('retry repeats disabling after the preference write fails', (
    tester,
  ) async {
    var saved = true;
    final writes = <bool>[];
    final shortcut = GlobalCaptureShortcut(
      backend: _Backend(),
      runtime: RuntimeRecoveryGate(),
      readSaved: () async => saved,
      writeSaved: (value) async {
        writes.add(value);
        if (writes.length == 1) throw StateError('Preference file is locked');
        saved = value;
      },
    );
    final container = ProviderContainer(
      overrides: [globalCaptureShortcutProvider.overrideWith((_) => shortcut)],
    );
    addTearDown(container.dispose);
    await shortcut.start(() {});
    await tester.pumpWidget(_panelApp(container));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('global-capture-enabled')));
    await tester.pumpAndSettle();
    expect(shortcut.error, 'saveFailed');
    expect(shortcut.registered, isTrue);
    expect(saved, isTrue);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(writes, [false, false]);
    expect(saved, isFalse);
    expect(shortcut.registered, isFalse);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets(
    'shortcut conflict and retry fit three languages on narrow and desktop windows',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final shortcut = GlobalCaptureShortcut(
        backend: _Backend(conflict: true),
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
            _panelApp(
              container,
              locale: Locale(language),
              builder: (_, child) => MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: const TextScaler.linear(2),
                ),
                child: child!,
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
