import 'dart:async';
import 'dart:io';

import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/ui/screens/backup_preview_screen.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Inspector implements BackupInspector {
  late Future<BackupPreview> Function(BackupInspectionCancellation?) handler;
  int calls = 0;
  BackupInspectionCancellation? cancellation;

  @override
  Future<BackupPreview> inspect(
    File source, {
    BackupInspectionCancellation? cancellation,
  }) {
    calls++;
    this.cancellation = cancellation;
    return handler(cancellation);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends StateNotifier<AppSettings> implements SettingsNotifier {
  _Settings() : super(AppSettings.defaults());
  int writes = 0;

  @override
  Future<void> ready = Future.value();

  @override
  Future<void> updateSettings(AppSettings newSettings) async {
    writes++;
    state = newSettings;
  }
}

BackupPreview _preview({bool issues = true}) => BackupPreview(
  version: 8,
  digest: List.filled(64, 'a').join(),
  counts: const {'settings': 1, 'media_records': 3, 'reminders': 12},
  containsCredentials: issues,
  missingMedia: issues ? 2 : 0,
  unresolvedReferences: issues ? 4 : 0,
  timestamp: issues ? DateTime.utc(2026, 10, 21, 4, 30) : null,
);

void main() {
  const delegates = <LocalizationsDelegate<dynamic>>[
    AppLocalizationsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
  final l10n = AppLocalizations(const Locale('en'));

  Future<void> showPreview(
    WidgetTester tester,
    _Inspector inspector, {
    Future<String?> Function()? picker,
    double textScale = 1,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
        localizationsDelegates: delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: BackupPreviewScreen(
          inspector: inspector,
          pickPath: picker ?? () async => '/private/qa/backup.json',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('backup-preview-select')));
    await tester.pump();
  }

  testWidgets('settings opens a read-only preview without saving settings', (
    tester,
  ) async {
    const notificationsChannel = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    final notificationCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, (call) async {
          notificationCalls.add(call.method);
          switch (call.method) {
            case 'areNotificationsEnabled':
            case 'canScheduleExactNotifications':
              return true;
            case 'checkPermissions':
              return {
                'isEnabled': true,
                'isAlertEnabled': true,
                'isSoundEnabled': true,
                'isProvisionalEnabled': false,
              };
            default:
              throw UnsupportedError(
                'Unexpected notification call: ${call.method}',
              );
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsChannel, null),
    );
    final settings = _Settings();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationScheduleStatusReaderProvider.overrideWithValue(
            () async => const NotificationScheduleStatus(
              upcoming: 0,
              submitted: 0,
              needsAttention: 0,
              cancellations: 0,
              overdueUnconfirmed: 0,
            ),
          ),
          settingsProvider.overrideWith((_) => settings),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          supportedLocales: [Locale('en')],
          localizationsDelegates: delegates,
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('notification-permission-panel')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(notificationCalls, isNotEmpty);
    expect(
      notificationCalls.where((call) => call.startsWith('request')),
      isEmpty,
    );
    final entry = find.byKey(const ValueKey('settings-backup-preview'));
    await tester.scrollUntilVisible(
      entry,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(BackupPreviewScreen), findsOneWidget);
    expect(find.text(l10n.get('backupPreviewReadOnly')), findsOneWidget);
    expect(find.text(l10n.get('backupPreviewSupport')), findsOneWidget);
    expect(settings.writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'narrow English preview shows counts, limits and expandable SHA',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(375, 812);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final inspector = _Inspector()..handler = (_) async => _preview();
      await showPreview(tester, inspector, textScale: 1.4);
      await choose(tester);
      await tester.pumpAndSettle();
      expect(find.text(l10n.get('backupPreviewAttention')), findsOneWidget);
      for (final key in [
        'backupPreviewTasks',
        'backupPreviewMedia',
        'backupPreviewSettings',
        'backupPreviewMissingMedia',
        'backupPreviewUnresolved',
        'backupPreviewCredentials',
        'backupPreviewFilesNotice',
      ]) {
        expect(find.text(l10n.get(key)), findsOneWidget);
      }
      for (final count in ['12', '3', '1', '2', '4']) {
        expect(find.text(count), findsOneWidget);
      }
      expect(find.text('backup.json'), findsOneWidget);
      expect(find.textContaining('/private/qa'), findsNothing);
      expect(find.text(_preview().digest), findsNothing);
      final checksum = find.text(l10n.get('backupPreviewDigest'));
      await tester.ensureVisible(checksum);
      await tester.pumpAndSettle();
      expect(checksum.hitTestable(), findsOneWidget);
      await tester.tap(checksum);
      await tester.pumpAndSettle();
      expect(find.text(_preview().digest), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'checksum has its own button semantics and toggles through accessibility',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final inspector = _Inspector()..handler = (_) async => _preview();
        await showPreview(tester, inspector);
        await choose(tester);
        await tester.pumpAndSettle();
        final checksum = find.text(l10n.get('backupPreviewDigest'));
        await tester.ensureVisible(checksum);
        await tester.pumpAndSettle();
        final collapsed = tester.getSemantics(checksum);
        final collapsedData = collapsed.getSemanticsData();
        expect(collapsedData.label, l10n.get('backupPreviewDigest'));
        expect(collapsedData.flagsCollection.isButton, isTrue);
        expect(collapsedData.hasAction(SemanticsAction.tap), isTrue);
        expect(collapsedData.hint, contains('Collapsed'));

        // Exercise the screen-reader action, not a coordinate tap.
        collapsed.owner!.performAction(collapsed.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(find.text(_preview().digest), findsOneWidget);
        final expanded = tester.getSemantics(checksum);
        final expandedData = expanded.getSemanticsData();
        expect(expandedData.label, l10n.get('backupPreviewDigest'));
        expect(expandedData.flagsCollection.isButton, isTrue);
        expect(expandedData.hasAction(SemanticsAction.tap), isTrue);
        expect(expandedData.hint, contains('Expanded'));
        expanded.owner!.performAction(expanded.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(find.text(_preview().digest), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        handle.dispose();
      }
    },
    variant: const TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    'preview stays usable across widths, locales and keyboard input',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final width in [375.0, 768.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 812);
        for (final language in ['zh', 'en', 'ja']) {
          final locale = Locale(language);
          final localized = AppLocalizations(locale);
          final inspector = _Inspector()..handler = (_) async => _preview();
          var picks = 0;
          await showPreview(
            tester,
            inspector,
            locale: locale,
            picker: () async {
              picks++;
              return '/qa/keyboard-preview.json';
            },
          );
          final label = find.text(localized.get('backupPreviewSelect'));
          expect(label.hitTestable(), findsOneWidget);
          expect(
            find.text(localized.get('backupPreviewReadOnly')),
            findsOneWidget,
          );
          // Traverse with the keyboard rather than setting focus directly.
          for (var tabs = 0; tabs < 6; tabs++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
            if (Focus.of(tester.element(label)).hasPrimaryFocus) break;
          }
          expect(Focus.of(tester.element(label)).hasPrimaryFocus, isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(picks, 1, reason: '$width / $language');
          expect(inspector.calls, 1);
          expect(
            find.byKey(const ValueKey('backup-preview-result')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: '$width / $language');
          await tester.pumpWidget(const SizedBox());
        }
      }
    },
  );

  testWidgets(
    'inspection cancellation waits for cleanup and ignores late results',
    (tester) async {
      final pending = Completer<BackupPreview>();
      final inspector = _Inspector()..handler = (_) => pending.future;
      var picks = 0;
      await showPreview(
        tester,
        inspector,
        picker: () async {
          picks++;
          return '/qa/backup.json';
        },
      );
      await choose(tester);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('backup-preview-select')));
      expect(picks, 1);
      expect(inspector.calls, 1);
      await tester.tap(find.byKey(const ValueKey('backup-preview-cancel')));
      await tester.pump();
      expect(inspector.cancellation!.isCancelled, isTrue);
      expect(find.text(l10n.get('backupPreviewCancelling')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      pending.complete(_preview());
      await tester.pumpAndSettle();
      expect(find.text(l10n.get('backupPreviewCancelled')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-preview-result')), findsNothing);
      inspector.handler = (_) async => _preview(issues: false);
      await choose(tester);
      await tester.pumpAndSettle();
      expect(find.text(l10n.get('backupPreviewPassed')), findsOneWidget);
      expect(find.text(l10n.get('backupPreviewNoTime')), findsOneWidget);
      expect(find.text(l10n.get('backupPreviewNoCredentials')), findsOneWidget);
      expect(inspector.calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('canceling the file picker does not inspect a file', (
    tester,
  ) async {
    final inspector = _Inspector()
      ..handler = (_) => throw StateError('must not inspect');
    await showPreview(tester, inspector, picker: () async => null);
    await choose(tester);
    await tester.pumpAndSettle();
    expect(inspector.calls, 0);
    expect(find.text(l10n.get('backupPreviewCancelled')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'safe localized failures allow retry without exposing backup data',
    (tester) async {
      final inspector = _Inspector()
        ..handler = (_) async => throw const BackupInspectionException(
          BackupInspectionError.unsupportedVersion,
        );
      await showPreview(tester, inspector);
      await choose(tester);
      await tester.pumpAndSettle();
      expect(find.text(l10n.get('backupPreviewUnsupported')), findsOneWidget);
      inspector.handler = (_) async =>
          throw StateError('api_key=private-secret');
      await choose(tester);
      await tester.pumpAndSettle();
      expect(find.text(l10n.get('backupPreviewFailed')), findsOneWidget);
      expect(find.textContaining('private-secret'), findsNothing);
      expect(find.byKey(const ValueKey('backup-preview-result')), findsNothing);
      inspector.handler = (_) async => _preview(issues: false);
      await choose(tester);
      await tester.pumpAndSettle();
      expect(find.text(l10n.get('backupPreviewPassed')), findsOneWidget);
      expect(find.text(l10n.get('backupPreviewFailed')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving during inspection cancels and safely ignores completion',
    (tester) async {
      final pending = Completer<BackupPreview>();
      final inspector = _Inspector()..handler = (_) => pending.future;
      await showPreview(tester, inspector);
      await choose(tester);
      await tester.pumpWidget(const SizedBox());
      expect(inspector.cancellation!.isCancelled, isTrue);
      pending.completeError(
        const BackupInspectionException(BackupInspectionError.cancelled),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
