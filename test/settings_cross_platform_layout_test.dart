import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/security/credential_store.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/credential_status_panel.dart';

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.linux,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets(
      'configuration card spacing on ${platform.name} themes and viewports',
      (tester) async {
        late Directory root;
        late DatabaseHelper db;
        late ProviderContainer container;
        await tester.runAsync(() async {
          sqfliteFfiInit();
          root = await Directory.systemTemp.createTemp('settings-platform-');
          db = DatabaseHelper.forTesting(
            root.path,
            databaseFactoryFfi,
            credentialStore: MemoryCredentialStore(),
          );
          container = ProviderContainer(
            overrides: [databaseHelperProvider.overrideWithValue(db)],
          );
          await container.read(settingsProvider.notifier).ready;
        });
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        try {
          for (final brightness in Brightness.values) {
            for (final width in [375.0, 1280.0]) {
              for (final scale in [1.0, 2.0]) {
                tester.view.physicalSize = Size(width, 900);
                final base = brightness == Brightness.dark
                    ? AppTheme.dark
                    : AppTheme.light;
                await tester.pumpWidget(
                  UncontrolledProviderScope(
                    container: container,
                    child: MaterialApp(
                      locale: const Locale('zh'),
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
                      theme: base.copyWith(
                        platform: platform,
                        visualDensity: ThemeData(
                          platform: platform,
                        ).visualDensity,
                      ),
                      builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(textScaler: TextScaler.linear(scale)),
                        child: child!,
                      ),
                      home: const SettingsScreen(area: SettingsArea.ai),
                    ),
                  ),
                );
                for (var i = 0; i < 15; i++) {
                  await tester.runAsync(
                    () => Future<void>.delayed(const Duration(milliseconds: 5)),
                  );
                  await tester.pump(const Duration(milliseconds: 20));
                }
                await tester.pumpAndSettle();
                final profiles = find
                    .ancestor(
                      of: find.byKey(const ValueKey('settings-model-profiles')),
                      matching: find.byType(Card),
                    )
                    .first;
                final speech = find
                    .ancestor(
                      of: find.byKey(const ValueKey('settings-speech')),
                      matching: find.byType(Card),
                    )
                    .first;
                expect(
                  tester.getTopLeft(profiles).dy -
                      tester.getBottomLeft(speech).dy,
                  greaterThanOrEqualTo(20),
                );
                await tester.ensureVisible(find.byType(CredentialStatusPanel));
                expect(
                  tester.getTopLeft(find.byType(CredentialStatusPanel)).dy -
                      tester.getBottomLeft(profiles).dy,
                  greaterThanOrEqualTo(20),
                );
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$platform $width $scale $brightness',
                );
                await tester.pumpWidget(const SizedBox());
                await tester.pump();
              }
            }
          }
        } finally {
          container.dispose();
          await tester.runAsync(() async {
            await db.close(createBackup: false);
            await root.delete(recursive: true);
          });
        }
      },
    );
  }
}
