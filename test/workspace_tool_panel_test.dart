import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/review_report.dart';
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
import 'package:dont_forget/ui/widgets/agent_goal_panel.dart';
import 'package:dont_forget/ui/widgets/workspace_tool_panel.dart';
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

class _Reviews extends LLMService {
  Completer<ReviewReport>? pending;
  @override
  Future<ReviewReport> generateReview(
    List<Reminder> tasks,
    AppSettings settings, {
    String language = 'zh',
  }) =>
      pending?.future ??
      super.generateReview(tasks, settings, language: language);
}

void main() {
  setUpAll(loadInteractionPreviewFonts);
  late Directory directory;
  late DatabaseHelper db;
  late ProviderContainer container;
  late NotificationService notifications;
  late _Export exporter;
  late _Reviews reviews;
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
    reviews = _Reviews();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(notifications),
        contextTriggerServiceProvider.overrideWithValue(_Context()),
        dataExportServiceProvider.overrideWithValue(exporter),
        llmServiceProvider.overrideWithValue(reviews),
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
    reviews.dispose();
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
    expect(
      find.byKey(const ValueKey('composer-input-surface')).hitTestable(),
      findsOneWidget,
    );
  }

  for (final width in [375.0, 757.0, 1200.0]) {
    testWidgets(
      'native search preserves draft and excludes IME and dialogs $width',
      (tester) async {
        await mount(tester, width);
        final command = container.read(workspaceToolsCommandProvider);
        await tester.enterText(composer(), 'ni');
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ni',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        expect(command.search!(), isFalse);
        expect(command.open!(), isFalse);
        expect(find.byType(CommandPaletteDialog), findsNothing);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '你 · 日本語 draft',
            selection: TextSelection.collapsed(offset: 13),
          ),
        );
        await tester.pump();
        expect(command.search!(), isTrue);
        await tester.pumpAndSettle();
        final search = find.byKey(const ValueKey('task-search-field'));
        expect(search.hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('composer-input-surface')).hitTestable(),
          findsOneWidget,
        );
        await tester.enterText(search, 'Synthetic');
        await tester.pumpAndSettle();
        expect(command.search!(), isTrue);
        await tester.pumpAndSettle();
        expect(search, findsOneWidget);
        expect(tester.widget<TextField>(search).controller!.text, 'Synthetic');
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          '你 · 日本語 draft',
        );
        unawaited(
          showDialog<void>(
            context: tester.element(find.byType(HomeScreen)),
            builder: (_) =>
                const AlertDialog(content: Text('Editor remains in front')),
          ),
        );
        await tester.pumpAndSettle();
        expect(command.search!(), isFalse);
        expect(command.open!(), isFalse);
        expect(find.text('Editor remains in front'), findsOneWidget);
        Navigator.of(tester.element(find.byType(AlertDialog))).pop();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(search, findsNothing);
        expect(
          tester.widget<TextField>(composer()).controller!.text,
          '你 · 日本語 draft',
        );
        final oldSearch = command.search!;
        await tester.pumpWidget(const SizedBox());
        expect(command.search, isNull);
        expect(oldSearch(), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'report pending blocks tools Escape and back then failure allows retry',
    (tester) async {
      await mount(tester, 375);
      await openTool(tester, 'dashboardTitle');
      reviews.pending = Completer<ReviewReport>();
      final generate = find.byKey(const ValueKey('review-generate'));
      await tester.ensureVisible(generate);
      await tester.pumpAndSettle();
      expect(generate.hitTestable(), findsOneWidget);
      await tester.tap(generate);
      await tester.pump();
      expect(container.read(workspaceToolsCommandProvider).open!(), isFalse);
      expect(container.read(workspaceToolsCommandProvider).search!(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(WorkspaceToolFrame), findsOneWidget);
      expect(
        tester
            .widget<WorkspaceToolFrame>(find.byType(WorkspaceToolFrame))
            .canClose,
        isFalse,
      );
      reviews.pending!.completeError(StateError('synthetic failure'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<WorkspaceToolFrame>(find.byType(WorkspaceToolFrame))
            .canClose,
        isTrue,
      );
      await tester.enterText(composer(), 'Draft survives failed report');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceToolFrame), findsNothing);
      expect(
        tester.widget<TextField>(composer()).controller!.text,
        'Draft survives failed report',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  const expandedTools = [
    'spacedRepetitionTitle',
    'contextDigestTitle',
    'knowledgeGraphTitle',
    'dashboardTitle',
    'multiAgentTitle',
  ];
  for (final width in [375.0, 768.0, 1440.0]) {
    for (final language in ['zh', 'en', 'ja']) {
      for (final tool in expandedTools) {
        testWidgets(
          'workspace2 $width $language $tool keyboard insets large text',
          (tester) async {
            await mount(
              tester,
              width,
              language: language,
              brightness: Brightness.dark,
              scale: 1.5,
            );
            await tester.enterText(composer(), '输入草稿 · Draft');
            await openTool(tester, tool);
            await tester.tap(composer());
            await tester.enterText(composer(), '工具内仍可输入 · Editable');
            await tester.pump();
            await captureInteractionPreview(
              tester,
              'workspace2-${width.toInt()}-$language-$tool',
            );
            tester.view.viewInsets = const FakeViewPadding(bottom: 300);
            addTearDown(tester.view.resetViewInsets);
            await tester.pump();
            expect(tester.takeException(), isNull);
            final input = tester.getRect(find.byType(InputBottomBar));
            expect(input.bottom, lessThanOrEqualTo(500));
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('workspace-tool-panel')))
                  .bottom,
              lessThanOrEqualTo(input.top),
            );
            expect(
              find
                  .byKey(const ValueKey('composer-input-surface'))
                  .hitTestable(),
              findsOneWidget,
            );
            // A short landscape viewport with a keyboard must remain scrollable.
            tester.view.physicalSize = Size(width, 460);
            tester.view.viewInsets = const FakeViewPadding(bottom: 180);
            await tester.pump();
            expect(tester.takeException(), isNull);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.byType(WorkspaceToolFrame), findsNothing);
            expect(
              tester.widget<TextField>(composer()).controller!.text,
              '工具内仍可输入 · Editable',
            );
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'agent draft survives switching closing and IME; discard needs confirmation',
    (tester) async {
      await mount(tester, 375);
      await openTool(tester, 'multiAgentTitle');
      final goal = find.byKey(const ValueKey('agent-goal-input'));
      await tester.enterText(goal, '尚未提交的目标');
      await openTool(tester, 'knowledgeGraphTitle');
      await openTool(tester, 'multiAgentTitle');
      expect(tester.widget<TextField>(goal).controller!.text, '尚未提交的目标');
      await tester.tap(goal);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '拼音组合',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(AgentGoalPanel), findsOneWidget);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '确认后的目标',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AgentGoalPanel), findsNothing);
      await openTool(tester, 'multiAgentTitle');
      expect(tester.widget<TextField>(goal).controller!.text, '确认后的目标');
      await tester.ensureVisible(find.text('放弃修改'));
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(AgentGoalPanel), findsOneWidget);
      expect(tester.widget<TextField>(goal).controller!.text, '确认后的目标');
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('放弃修改'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(goal).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
        expect(
          container.read(workspaceToolsCommandProvider).search!(),
          isFalse,
        );
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
            expect(
              find
                  .byKey(const ValueKey('composer-input-surface'))
                  .hitTestable(),
              findsOneWidget,
            );
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
