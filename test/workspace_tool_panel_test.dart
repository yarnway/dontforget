import 'dart:async';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/data_export_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/home_screen.dart';
import 'package:dont_forget/ui/widgets/command_palette_dialog.dart';
import 'package:dont_forget/ui/widgets/data_export_sheet.dart';
import 'package:dont_forget/ui/widgets/focus_mode_sheet.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/interaction_preview.dart';

class _Context extends ContextTriggerService {
  _Context() : super.forTesting();
  @override
  Future<String?> detectCurrentWifiSsid() async => null;
}

class _Export extends DataExportService {
  Completer<Uri?>? pending;
  @override
  Future<Uri?> saveWithDialog(
    List<Reminder> tasks, {
    required String locale,
    required String title,
    bool Function()? isCurrent,
  }) async => pending?.future;
}

void main() {
  setUpAll(loadInteractionPreviewFonts);
  late Directory directory;
  late DatabaseHelper db;
  late ProviderContainer container;
  late NotificationService notifications;
  late _Export exporter;
  final channels = <MethodChannel>[];
  setUp(() async {
    sqfliteFfiInit();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    channels.addAll(const [
      MethodChannel('xyz.luan/audioplayers.global'),
      MethodChannel('xyz.luan/audioplayers.global/events'),
      MethodChannel('xyz.luan/audioplayers'),
      MethodChannel('com.llfbandit.record/messages'),
      MethodChannel('tray_manager'),
    ]);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'create') {
          final events = MethodChannel(
            'xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}',
          );
          channels.add(events);
          messenger.setMockMethodCallHandler(events, (_) async => null);
        }
        return null;
      });
    }
    directory = await Directory.systemTemp.createTemp('workspace-panel-');
    db = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = NotificationService.forTesting(
      FlutterLocalNotificationsPlugin(),
      usesNativeNotifications: false,
    );
    exporter = _Export();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(notifications),
        contextTriggerServiceProvider.overrideWithValue(_Context()),
        dataExportServiceProvider.overrideWithValue(exporter),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(mediaRecordsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    await container
        .read(remindersProvider.notifier)
        .addReminder(
          Reminder(
            id: 'panel-task',
            taskTitle: '合成任务 · Synthetic task',
            taskSummary: '用于布局与输入验收',
            quadrantLevel: 2,
          ),
        );
  });
  tearDown(() async {
    container.dispose();
    await notifications.pauseForMaintenance();
    await db.close(createBackup: false);
    await directory.delete(recursive: true);
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    channels.clear();
  });
  Finder composer() => find.descendant(
    of: find.byType(InputBottomBar),
    matching: find.byType(TextField),
  );
  Future<void> mount(
    WidgetTester tester,
    double width, {
    String language = 'zh',
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(
            brightness: brightness,
            colorSchemeSeed: Colors.teal,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: InlineFeedback(
              child: RepaintBoundary(key: interactionPreviewKey, child: child!),
            ),
          ),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTool(WidgetTester tester, String key) async {
    expect(container.read(workspaceToolsCommandProvider).open!(), isTrue);
    await tester.pumpAndSettle();
    final loc = AppLocalizations.of(
      tester.element(find.byType(CommandPaletteDialog)),
    );
    await tester.enterText(
      find.descendant(
        of: find.byType(CommandPaletteDialog),
        matching: find.byType(TextField),
      ),
      loc.get(key),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == loc.get(key),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CommandPaletteDialog), findsNothing);
    expect(find.byType(ModalBarrier).hitTestable(), findsNothing);
    expect(composer().hitTestable(), findsOneWidget);
  }

  for (final width in [375.0, 1200.0]) {
    testWidgets(
      'tools preserve editable composer across open close resize and pending export $width',
      (tester) async {
        await mount(tester, width);
        final originalState = tester.state(find.byType(InputBottomBar));
        await tester.enterText(composer(), 'Draft before tools');
        await openTool(tester, 'focusTitle');
        expect(tester.state(find.byType(InputBottomBar)), same(originalState));
        final inputRect = tester.getRect(find.byType(InputBottomBar));
        final panelRect = tester.getRect(
          find.byKey(const ValueKey('workspace-tool-panel')),
        );
        expect(panelRect.bottom, lessThanOrEqualTo(inputRect.top));
        await tester.tap(composer());
        await tester.enterText(composer(), 'Draft edited with focus open');
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          'Draft edited with focus open',
        );
        await tester.tap(find.byType(SwitchListTile));
        await tester.pumpAndSettle();
        expect(container.read(immersiveModeProvider), isTrue);
        await openTool(tester, 'exportExcel');
        expect(find.byType(FocusModeSheet), findsNothing);
        expect(tester.state(find.byType(InputBottomBar)), same(originalState));
        final loc = AppLocalizations.of(
          tester.element(find.byType(DataExportSheet)),
        );
        exporter.pending = Completer<Uri?>();
        await tester.tap(find.text(loc.get('exportChooseLocation')));
        await tester.pump();
        expect(container.read(workspaceToolsCommandProvider).open!(), isFalse);
        final close = find.descendant(
          of: find.byType(DataExportSheet),
          matching: find.byType(IconButton),
        );
        expect(tester.widget<IconButton>(close).onPressed, isNull);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.byType(DataExportSheet), findsOneWidget);
        final exportState = tester.state(find.byType(DataExportSheet));
        tester.view.physicalSize = Size(width == 375 ? 1200 : 375, 800);
        await tester.pump();
        expect(tester.state(find.byType(DataExportSheet)), same(exportState));
        await tester.enterText(composer(), 'Draft during export');
        exporter.pending!.complete(null);
        await tester.pumpAndSettle();
        expect(find.text(loc.get('exportCancelled')), findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('workspace-tool-panel')),
          findsNothing,
        );
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          'Draft during export',
        );
        await openTool(tester, 'focusTitle');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('workspace-tool-panel')),
          findsNothing,
        );
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          'Draft during export',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final width in [375.0, 768.0, 1440.0]) {
    for (final language in ['zh', 'en', 'ja']) {
      for (final tool in ['focusTitle', 'exportExcel']) {
        testWidgets(
          'panel $width $language $tool large text themes short window',
          (tester) async {
            await mount(
              tester,
              width,
              language: language,
              brightness: Brightness.dark,
              scale: 1.5,
            );
            await openTool(tester, tool);
            await tester.enterText(composer(), 'Draft stays editable');
            expect(tester.takeException(), isNull);
            await captureInteractionPreview(
              tester,
              'panel-${width.toInt()}-$language-$tool',
            );
            tester.view.physicalSize = Size(width, 460);
            await tester.pump();
            expect(tester.takeException(), isNull);
            final panel = tester.getRect(
                  find.byKey(const ValueKey('workspace-tool-panel')),
                ),
                input = tester.getRect(find.byType(InputBottomBar));
            expect(panel.bottom, lessThanOrEqualTo(input.top));
            expect(composer().hitTestable(), findsOneWidget);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
