import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/interaction_preview.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/about_strings.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/app_update_service.dart';
import 'package:dont_forget/services/security/credential_store.dart';
import 'package:dont_forget/ui/screens/about_screen.dart';
import 'package:dont_forget/ui/screens/preferences_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';

ReleaseHttpResponse latest() => ReleaseHttpResponse(
  200,
  utf8.encode(
    jsonEncode({
      'tag_name': 'v1.8.12',
      'html_url': '$appReleasesUrl/tag/v1.8.12',
      'draft': false,
      'prerelease': false,
      'body': 'Release notes',
      'assets': [
        for (final filename in [
          'DontForget_Setup_v1.8.12.exe',
          'DontForget_Windows_Portable_v1.8.12.zip',
          'DontForget_Android_v1.8.12.apk',
          'DontForget_Android_arm64_v1.8.12.apk',
          'DontForget_Linux_x64_v1.8.12.tar.gz',
          'DontForget_iOS_unsigned_v1.8.12.ipa',
        ])
          {'name': filename, 'state': 'uploaded', 'size': 123},
      ],
    }),
  ),
);

InstalledAppInfo info() =>
    InstalledAppInfo(name: 'DontForget', version: '1.8.11', buildNumber: '81');

Widget material(
  Widget home, {
  String language = 'zh',
  double scale = 1,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
  localizationsDelegates: const [
    AppLocalizationsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
  builder: (context, child) => RepaintBoundary(
    key: interactionPreviewKey,
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
  ),
  home: home,
);

void main() {
  setUpAll(loadInteractionPreviewFonts);
  Future<void> show(
    WidgetTester tester, {
    AppUpdateService? service,
    Future<InstalledAppInfo> Function()? reader,
    Future<bool> Function(Uri)? open,
    String language = 'zh',
    double width = 390,
    double height = 950,
    double scale = 1,
    Brightness brightness = Brightness.light,
    UpdatePlatform platform = UpdatePlatform.windows,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdatePlatformProvider.overrideWithValue(platform),
          installedAppInfoReaderProvider.overrideWithValue(
            reader ?? () async => info(),
          ),
          appUpdateServiceProvider.overrideWithValue(
            service ?? AppUpdateService(fetch: (uri, limit) async => latest()),
          ),
          appProjectLinkOpenerProvider.overrideWithValue(
            open ?? (uri) async => true,
          ),
        ],
        child: material(
          const AboutScreen(),
          language: language,
          scale: scale,
          brightness: brightness,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(
    WidgetTester tester,
    String key, {
    bool settle = true,
  }) async {
    final target = find.byKey(ValueKey(key));
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        180,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('about visual preview', (tester) async {
    for (final width in [390.0, 1200.0]) {
      for (final brightness in Brightness.values) {
        await show(tester, width: width, brightness: brightness);
        if (const bool.fromEnvironment('UI_PREVIEW')) {
          await tester.runAsync(
            () => precacheImage(
              const AssetImage('assets/app_icon.png'),
              tester.element(find.byType(AboutScreen)),
            ),
          );
          await tester.pumpAndSettle();
        }
        await captureInteractionPreview(
          tester,
          'about-ux-${width.toInt()}-${brightness.name}',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets(
    'update action fits a short phone viewport before resource links',
    (tester) async {
      for (final language in ['zh', 'en', 'ja']) {
        await show(tester, width: 375, height: 568, language: language);
        final action = find.byKey(const ValueKey('about-check-updates'));
        expect(action.hitTestable(), findsOneWidget);
        expect(tester.getRect(action).bottom, lessThanOrEqualTo(568));
        expect(
          find.byKey(const ValueKey('about-project')).hitTestable(),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'version copy is labeled, has a full tap target and copies actual metadata',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await show(tester);
        final copy = find.byKey(const ValueKey('about-copy-version'));
        final data = tester.getSemantics(copy).getSemanticsData();
        expect(data.tooltip, aboutText('zh', 'copyVersion'));
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        expect(tester.getSize(copy).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(copy).height, greaterThanOrEqualTo(48));
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(copied, 'DontForget 1.8.11 (81)');
        expect(find.text(aboutText('zh', 'copied')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('about-installed-version')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'opening About reads the actual version but checks only on request',
    (tester) async {
      var requests = 0;
      final pending = Completer<ReleaseHttpResponse>();
      await show(
        tester,
        service: AppUpdateService(
          fetch: (uri, limit) {
            requests++;
            return pending.future;
          },
        ),
      );
      expect(find.textContaining('1.8.11 (81)'), findsOneWidget);
      expect(requests, 0);
      await tap(tester, 'about-check-updates', settle: false);
      expect(requests, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('about-check-updates')),
            )
            .onPressed,
        isNull,
      );
      pending.complete(latest());
      await tester.pumpAndSettle();
      expect(find.text(aboutText('zh', 'newer')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('about-download-windowsSetup')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('about-download-iosUnsigned')),
        findsNothing,
      );
    },
  );

  testWidgets('iOS offers the unsigned IPA with personal signing instructions', (
    tester,
  ) async {
    final opened = <Uri>[];
    await show(
      tester,
      platform: UpdatePlatform.ios,
      open: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    await tap(tester, 'about-check-updates');
    expect(find.text(aboutText('zh', 'iosHint')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('about-download-windowsSetup')),
      findsNothing,
    );
    await tap(tester, 'about-download-iosUnsigned');
    expect(
      opened.single.toString(),
      '$appRepositoryUrl/releases/download/v1.8.12/DontForget_iOS_unsigned_v1.8.12.ipa',
    );
  });

  testWidgets(
    'failed checks are retryable and never display a false latest status',
    (tester) async {
      var requests = 0;
      await show(
        tester,
        service: AppUpdateService(
          fetch: (uri, limit) async =>
              requests++ == 0 ? const ReleaseHttpResponse(503, []) : latest(),
        ),
      );
      await tap(tester, 'about-check-updates');
      expect(find.text(aboutText('zh', 'server')), findsOneWidget);
      expect(find.text(aboutText('zh', 'current')), findsNothing);
      await tap(tester, 'about-check-updates');
      expect(find.byKey(const ValueKey('about-update-error')), findsNothing);
      expect(find.byKey(const ValueKey('about-update-result')), findsOneWidget);
    },
  );

  testWidgets(
    'unreadable installed versions can retry before update comparison',
    (tester) async {
      var reads = 0;
      await show(
        tester,
        reader: () async {
          if (reads++ == 0) throw PlatformException(code: 'fixture');
          return info();
        },
      );
      expect(find.text(aboutText('zh', 'versionError')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('about-check-updates')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text(aboutText('zh', 'retry')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1.8.11 (81)'), findsOneWidget);
    },
  );

  testWidgets('browser failures provide a copyable link', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await show(tester, open: (uri) async => false);
    await tap(tester, 'about-project');
    expect(find.text(aboutText('zh', 'openFailed')), findsOneWidget);
    await tester.tap(find.text(aboutText('zh', 'copyLink')));
    await tester.pumpAndSettle();
    expect(copied, appRepositoryUrl);
  });

  testWidgets('leaving the screen ignores a late network response', (
    tester,
  ) async {
    final pending = Completer<ReleaseHttpResponse>();
    await show(
      tester,
      service: AppUpdateService(fetch: (uri, limit) => pending.future),
    );
    await tap(tester, 'about-check-updates', settle: false);
    await tester.pumpWidget(const SizedBox());
    pending.complete(latest());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'three languages, themes, narrow large text and desktop remain scrollable',
    (tester) async {
      for (final platform in [
        UpdatePlatform.windows,
        UpdatePlatform.android,
        UpdatePlatform.ios,
        UpdatePlatform.linux,
      ]) {
        for (final language in ['zh', 'en', 'ja']) {
          for (final brightness in Brightness.values) {
            for (final width in [375.0, 1440.0]) {
              await show(
                tester,
                platform: platform,
                reader: () async => InstalledAppInfo(
                  name: '别忘了·验收 iphone15-20261115',
                  version: '1.8.11',
                  buildNumber: '81',
                ),
                language: language,
                brightness: brightness,
                width: width,
                scale: 2,
              );
              await tap(tester, 'about-check-updates');
              await tester.scrollUntilVisible(
                find.byKey(const ValueKey('about-releasePage')),
                180,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: '$language $brightness $width',
              );
              await tester.pumpWidget(const SizedBox());
            }
          }
        }
      }
    },
  );

  testWidgets(
    'settings navigation preserves unsaved preferences and business rows',
    (tester) async {
      late Directory root;
      late DatabaseHelper db;
      late ProviderContainer container;
      late List<Map<String, Object?>> before;
      await tester.runAsync(() async {
        sqfliteFfiInit();
        root = await Directory.systemTemp.createTemp('about-preferences-');
        db = DatabaseHelper.forTesting(
          root.path,
          databaseFactoryFfi,
          credentialStore: MemoryCredentialStore(),
        );
        container = ProviderContainer(
          overrides: [
            databaseHelperProvider.overrideWithValue(db),
            installedAppInfoReaderProvider.overrideWithValue(
              () async => info(),
            ),
          ],
        );
        await container.read(settingsProvider.notifier).ready;
        before = await db.read(
          db.captureGeneration(),
          (sql) => sql.query('Settings'),
        );
      });
      try {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 950);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: material(const PreferencesScreen()),
          ),
        );
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('preferences-language')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('日本語').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('preferences-save')), findsOneWidget);
        await tap(tester, 'preferences-about');
        expect(find.byType(AboutScreen), findsOneWidget);
        await tester.tap(find.byType(BackButton).last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('preferences-save')), findsOneWidget);
        await tester.runAsync(() async {
          expect(
            await db.read(
              db.captureGeneration(),
              (sql) => sql.query('Settings'),
            ),
            before,
          );
        });
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        await tester.runAsync(() async {
          await db.close(createBackup: false);
          await root.delete(recursive: true);
        });
      }
    },
  );
}
