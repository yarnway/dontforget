import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/input_send_mode_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final language in ['zh', 'en', 'ja']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'send preference $language dark=$dark scale=$scale fits 320',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(320, 700);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            var value = InputSendMode.enter;
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                supportedLocales: [Locale(language)],
                localizationsDelegates: const [
                  AppLocalizationsDelegate(),
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                theme: dark ? AppTheme.dark : AppTheme.light,
                home: StatefulBuilder(
                  builder: (context, setState) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: Scaffold(
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: InputSendModePicker(
                          value: value,
                          onChanged: (mode) => setState(() => value = mode),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('input-send-mode')));
            await tester.pumpAndSettle();
            await tester.tap(
              find
                  .text(
                    AppLocalizations(Locale(language)).get('inputSend_button'),
                  )
                  .last,
            );
            await tester.pumpAndSettle();
            expect(value, InputSendMode.button);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
