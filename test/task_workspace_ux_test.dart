import 'support/workspace_drafts.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'dart:async';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:dont_forget/ui/widgets/voice_capture_feedback.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ControlledHomeController extends HomeController {
  _ControlledHomeController(super.ref);
  Completer<bool>? pendingStart;
  int stops = 0;
  int starts = 0;
  int cancels = 0;
  int drafts = 0;
  Completer<String?>? pendingText;
  final sent = <String>[];
  final captureIds = <String?>[];
  Completer<bool>? pendingSend;
  @override
  Future<bool> processText(
    String text, {
    DateTime? reminderTime,
    bool memoOnly = false,
    String? captureId,
  }) async {
    sent.add(text);
    captureIds.add(captureId);
    return pendingSend == null ? true : await pendingSend!.future;
  }

  @override
  Future<bool> cancelRecording() async {
    cancels++;
    setRecording(false);
    return true;
  }

  @override
  Future<String?> stopRecordingToText({bool Function()? canAcceptDraft}) async {
    drafts++;
    setRecording(false);
    return pendingText == null ? '明日の予定を確認' : await pendingText!.future;
  }

  void setRecording(bool value) => state = state.copyWith(isRecording: value);

  @override
  Future<bool> startRecording() async {
    starts++;
    final started = await (pendingStart?.future ?? Future.value(true));
    setRecording(started);
    return started;
  }

  @override
  Future<void> stopRecordingAndProcess() async {
    stops++;
    setRecording(false);
  }
}

class _Notifications implements NotificationService {
  final scheduled = <Reminder>[];
  final canceled = <String>[];
  bool failNative = false;
  @override
  Future<void> scheduleReminder(Reminder task) async => scheduled.add(task);
  @override
  Future<void> cancelReminder(String id) async => canceled.add(id);
  @override
  Future<void> scheduleReminderStrict(Reminder task) async {
    await scheduleReminder(task);
    if (failNative) throw StateError('isolated native scheduling failure');
  }

  @override
  Future<void> cancelReminderStrict(String id) async {
    await cancelReminder(id);
    if (failNative) throw StateError('isolated native cancellation failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _ControlledHomeController home;
  late _Notifications notifications;
  String? clipboard;
  const recorderChannel = MethodChannel('com.llfbandit.record/messages');

  setUp(() async {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard?.isNotEmpty ?? false};
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, (_) async => null);
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'dontforget-workspace-ux-',
    );
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = _Notifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        homeControllerProvider.overrideWith(
          (ref) => home = _ControlledHomeController(ref),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    container.read(homeControllerProvider);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> show(
    WidgetTester tester,
    Widget child, {
    bool reducedMotion = false,
    double textScale = 1,
    String language = 'zh',
    Brightness brightness = Brightness.light,
  }) async {
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: brightness,
            ),
          ),
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, content) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reducedMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: InlineFeedback(child: content!),
          ),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  Widget card(String id) => Consumer(
    builder: (context, ref, _) {
      final task = ref
          .watch(remindersProvider)
          .where((r) => r.id == id)
          .firstOrNull;
      return task == null
          ? const SizedBox()
          : TaskCard(task: task, onPlayMedia: () {});
    },
  );

  Future<void> waitForSent(WidgetTester tester, int count) async {
    for (var i = 0; i < 100 && home.sent.length < count; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
    }
    expect(home.sent.length, count);
    await drainWorkspaceDrafts(tester, container);
  }

  testWidgets(
    'input has no idle ticks and reduced motion stops recording animation',
    (tester) async {
      await show(tester, const InputBottomBar());
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      home.setRecording(true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await show(tester, const InputBottomBar(), reducedMotion: true);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byIcon(Icons.stop_circle_rounded), findsOneWidget);
      home.setRecording(false);
      await show(tester, const InputBottomBar());
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('send reflects draft content and recording state', (
    tester,
  ) async {
    final settings = container.read(settingsProvider.notifier);
    await tester.runAsync(
      () => settings.updateSettings(
        settings.state.copyWith(inputSendMode: InputSendMode.button),
      ),
    );
    await show(tester, const InputBottomBar());
    final send = find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded);
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    home.setRecording(true);
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    home.setRecording(false);
    await tester.pump();
    expect(find.text('Keep this draft'), findsOneWidget);
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(const SizedBox());
  });

  for (final succeeds in [false, true]) {
    testWidgets(
      'typing during a ${succeeds ? 'successful' : 'failed'} save preserves both inputs',
      (tester) async {
        home.pendingSend = Completer<bool>();
        await tester.runAsync(
          () => container
              .read(settingsProvider.notifier)
              .updateSettings(
                container
                    .read(settingsProvider)
                    .copyWith(inputSendMode: InputSendMode.button),
              ),
        );
        await show(tester, const InputBottomBar());
        await tester.enterText(find.byType(TextField), 'first input');
        await drainWorkspaceDrafts(tester, container);
        await tester.tap(find.byTooltip('发送'));
        for (var i = 0; i < 100 && home.sent.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await tester.pump();
        }
        expect(home.sent, ['first input']);
        final submittedId = home.captureIds.single;
        await tester.enterText(find.byType(TextField), 'newer input');
        await drainWorkspaceDrafts(tester, container);
        expect(
          container.read(workspaceDraftsProvider)['capture']['id'],
          isNot(submittedId),
        );
        expect(
          container.read(
            workspaceDraftsProvider,
          )['pendingCaptures'][submittedId]['text'],
          'first input',
        );
        home.pendingSend!.complete(succeeds);
        home.pendingSend = null;
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await tester.pump();
          if (succeeds
              ? container.read(workspaceDraftsProvider)['pendingCaptures'] ==
                    null
              : find
                    .byKey(const ValueKey('pending-captures'))
                    .evaluate()
                    .isNotEmpty) {
            break;
          }
        }
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'newer input',
        );
        if (succeeds) {
          expect(
            container.read(workspaceDraftsProvider)['pendingCaptures'],
            isNull,
          );
          await tester.tap(find.byTooltip('发送'));
          for (var i = 0; i < 100 && home.sent.length < 2; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 2)),
            );
            await tester.pump();
          }
          expect(home.sent, ['first input', 'newer input']);
          expect(home.captureIds.last, isNot(submittedId));
        } else {
          await tester.tap(find.byKey(const ValueKey('pending-captures')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('恢复到输入框'));
          await drainWorkspaceDrafts(tester, container);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'newer input\nfirst input',
          );
          expect(
            container.read(workspaceDraftsProvider)['pendingCaptures'],
            isNull,
          );
        }
      },
    );
  }

  testWidgets(
    'mobile composer switches modes, preserves draft and places attachments on right',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await show(
        tester,
        const InputBottomBar(),
        reducedMotion: true,
        textScale: 2,
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('composer-mode-toggle'));
      final attachment = find.byKey(const ValueKey('composer-attachment'));
      final surface = find.byKey(const ValueKey('composer-input-surface'));
      expect(find.byKey(const ValueKey('composer-send')), findsNothing);
      expect(
        tester.getCenter(toggle).dx,
        lessThan(tester.getRect(surface).left),
      );
      expect(
        tester.getCenter(attachment).dx,
        greaterThan(tester.getRect(surface).right),
      );
      await tester.enterText(find.byType(TextField), '日本語の下書き');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-voice-pad')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(home.starts, 0);
      final origin = tester.getCenter(surface);
      final press = await tester.startGesture(origin);
      await tester.pump(const Duration(milliseconds: 700));
      expect(home.starts, 1);
      expect(tester.widget<IconButton>(attachment).onPressed, isNull);
      expect(tester.widget<IconButton>(toggle).onPressed, isNull);
      await press.moveTo(origin + const Offset(-70, -80));
      await press.up();
      await tester.pumpAndSettle();
      expect(home.cancels, 1);
      expect(home.sent, isEmpty);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '日本語の下書き');
      expect(field.focusNode!.hasFocus, isTrue);
      final settings = container.read(settingsProvider.notifier);
      await tester.runAsync(
        () => settings.updateSettings(
          settings.state.copyWith(inputSendMode: InputSendMode.button),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-send')), findsOneWidget);
      expect(
        tester.getCenter(find.byKey(const ValueKey('composer-send'))).dx,
        greaterThan(tester.getCenter(attachment).dx),
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'mobile voice pad converts to editable text and appends to preserved draft',
    (tester) async {
      await show(tester, const InputBottomBar(), reducedMotion: true);
      await tester.enterText(find.byType(TextField), 'Existing draft');
      await tester.tap(find.byKey(const ValueKey('composer-mode-toggle')));
      await tester.pumpAndSettle();
      final origin = tester.getCenter(
        find.byKey(const ValueKey('composer-input-surface')),
      );
      final press = await tester.startGesture(origin);
      await tester.pump(const Duration(milliseconds: 700));
      await press.moveTo(origin + const Offset(0, -100));
      await tester.pump();
      await press.moveTo(origin + const Offset(80, -100));
      await press.up();
      await tester.pumpAndSettle();
      expect(home.drafts, 1);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Existing draft\n明日の予定を確認');
      expect(field.focusNode!.hasFocus, isTrue);
      expect(home.sent, isEmpty);
      expect(home.stops, 0);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'Enter send mode preserves IME composition and supports Shift Enter',
    (tester) async {
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final input = find.byType(TextField);
      await tester.enterText(input, '確認');
      await tester.pump();
      final field = tester.widget<TextField>(input);
      field.controller!.value = const TextEditingValue(
        text: '確認',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(home.sent, isEmpty);
      expect(field.controller!.text, '確認');
      field.controller!.value = const TextEditingValue(
        text: '確認',
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(field.controller!.text, '確認\n');
      expect(home.sent, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await waitForSent(tester, 1);
      expect(home.sent, ['確認\n']);
      expect(field.controller!.text, isEmpty);
    },
  );

  testWidgets(
    'button-only mode keeps Enter as a newline until Send is tapped',
    (tester) async {
      final settings = container.read(settingsProvider.notifier);
      await tester.runAsync(
        () => settings.updateSettings(
          settings.state.copyWith(inputSendMode: InputSendMode.button),
        ),
      );
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final input = find.byType(TextField);
      await tester.enterText(input, '今晚读书');
      await tester.pump();
      final field = tester.widget<TextField>(input);
      expect(field.textInputAction, TextInputAction.newline);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(field.controller!.text, '今晚读书\n');
      expect(home.sent, isEmpty);
      await tester.enterText(input, '今晚读书\n明早复习');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(home.sent, isEmpty);
      await tester.tap(find.byTooltip('发送'));
      await waitForSent(tester, 1);
      expect(home.sent, ['今晚读书\n明早复习']);
    },
  );

  testWidgets('mobile keyboard Send follows the configured send mode', (
    tester,
  ) async {
    await show(tester, const InputBottomBar(), reducedMotion: true);
    await tester.enterText(find.byType(TextField), '明日9時に復習');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).textInputAction,
      TextInputAction.send,
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await waitForSent(tester, 1);
    expect(home.sent, ['明日9時に復習']);
  });

  testWidgets(
    'iOS pointer hold on an idle input records once and release stops it',
    (tester) async {
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final press = await tester.startGesture(
        tester.getCenter(find.byType(TextField)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(home.starts, 1);
      expect(home.state.isRecording, isTrue);
      await press.up();
      await tester.pumpAndSettle();
      expect(home.stops, 1);
      expect(home.state.isRecording, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS focused text keeps selection and draft without starting audio',
    (tester) async {
      await show(tester, const InputBottomBar(), reducedMotion: true);
      await tester.tapAt(tester.getCenter(find.byType(TextField)));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), '日本語の予定を確認');
      await tester.longPress(
        find.byKey(const ValueKey('composer-input-surface')),
      );
      await tester.pumpAndSettle();
      expect(home.starts, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '日本語の予定を確認',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS real pointer release during permission delay stops the late start',
    (tester) async {
      home.pendingStart = Completer<bool>();
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final press = await tester.startGesture(
        tester.getCenter(find.byType(TextField)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(home.starts, 1);
      await press.up();
      await tester.pump();
      home.pendingStart!.complete(true);
      await tester.pumpAndSettle();
      expect(home.stops, 1);
      expect(home.state.isRecording, isFalse);
      expect(find.byType(TextField), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'denied iOS hold can be retried with a new pointer gesture',
    (tester) async {
      home.pendingStart = Completer<bool>()..complete(false);
      await show(tester, const InputBottomBar(), reducedMotion: true);
      await tester.longPress(
        find.byKey(const ValueKey('composer-input-surface')),
      );
      await tester.pumpAndSettle();
      expect(home.stops, 0);
      home.pendingStart = null;
      await tester.longPress(
        find.byKey(const ValueKey('composer-input-surface')),
      );
      await tester.pumpAndSettle();
      expect(home.starts, 2);
      expect(home.stops, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS slide up then left cancels without processing or drafting',
    (tester) async {
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final origin = tester.getCenter(
        find.byKey(const ValueKey('composer-input-surface')),
      );
      final press = await tester.startGesture(origin);
      await tester.pump(const Duration(milliseconds: 700));
      await press.moveTo(origin + const Offset(0, -100));
      await tester.pump();
      await press.moveTo(origin + const Offset(-80, -100));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<VoiceCaptureFeedback>(find.byType(VoiceCaptureFeedback))
            .action,
        VoiceReleaseAction.cancel,
      );
      expect(find.text('松手取消录音'), findsOneWidget);
      await press.up();
      await tester.pumpAndSettle();
      expect(home.cancels, 1);
      expect(home.stops, 0);
      expect(home.drafts, 0);
      expect(find.byType(VoiceCaptureFeedback), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS slide up then right fills an editable draft without sending',
    (tester) async {
      home.pendingText = Completer<String?>();
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final origin = tester.getCenter(
        find.byKey(const ValueKey('composer-input-surface')),
      );
      final press = await tester.startGesture(origin);
      await tester.pump(const Duration(milliseconds: 700));
      await press.moveTo(origin + const Offset(0, -100));
      await tester.pump();
      await press.moveTo(origin + const Offset(80, -100));
      await tester.pumpAndSettle();
      expect(find.text('松手转文字并编辑'), findsOneWidget);
      await press.up();
      await tester.pump();
      expect(find.text('正在转为可编辑文字…'), findsOneWidget);
      home.pendingText!.complete('明日の予定を確認');
      await tester.pumpAndSettle();
      expect(home.drafts, 1);
      expect(home.stops, 0);
      expect(home.cancels, 0);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '明日の予定を確認');
      expect(field.focusNode!.hasFocus, isTrue);
      await tester.enterText(find.byType(TextField), '明日9時に予定を確認');
      expect(container.read(remindersProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS dragging back from cancel returns to voice save',
    (tester) async {
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final origin = tester.getCenter(
        find.byKey(const ValueKey('composer-input-surface')),
      );
      final press = await tester.startGesture(origin);
      await tester.pump(const Duration(milliseconds: 700));
      await press.moveTo(origin + const Offset(0, -100));
      await tester.pump();
      await press.moveTo(origin + const Offset(-80, -100));
      await tester.pump();
      await press.moveTo(origin);
      await tester.pump();
      expect(find.text('松手保存语音'), findsOneWidget);
      await press.up();
      await tester.pumpAndSettle();
      expect(home.stops, 1);
      expect(home.cancels, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS unfocused empty input can record while its prior keyboard closes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await show(
        tester,
        const InputBottomBar(),
        reducedMotion: true,
        textScale: 2,
      );
      final surface = find.byKey(const ValueKey('composer-input-surface'));
      await tester.tap(surface);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
      await tester.pump();
      final origin = tester.getCenter(surface);
      final press = await tester.startGesture(origin);
      await tester.pump(const Duration(milliseconds: 700));
      expect(home.starts, 1);
      expect(find.byType(VoiceCaptureFeedback), findsNothing);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding();
      await show(
        tester,
        const InputBottomBar(),
        reducedMotion: true,
        textScale: 2,
      );
      expect(find.byType(VoiceCaptureFeedback), findsOneWidget);
      await press.moveTo(origin + const Offset(70, -80));
      await press.up();
      await tester.pumpAndSettle();
      expect(home.drafts, 1);
      expect(find.text('明日の予定を確認'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS focused empty composer offers Paste instead of starting recording',
    (tester) async {
      clipboard = '明日 study\n日本語の復習';
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final input = find.byType(TextField);
      await tester.tap(find.byKey(const ValueKey('composer-input-surface')));
      await tester.pump();
      await tester.longPress(input);
      await tester.pumpAndSettle();
      expect(home.starts, 0);
      expect(find.text('粘贴'), findsOneWidget);
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, clipboard);
      expect(home.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'secondary click on idle empty composer can paste without recording',
    (tester) async {
      clipboard = 'Paste this draft';
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final input = find.byType(TextField);
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isFalse);
      await tester.tap(
        find.byKey(const ValueKey('composer-input-surface')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('粘贴'), findsOneWidget);
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, clipboard);
      expect(home.starts, 0);
      expect(home.sent, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'composer menu selects all, copies, cuts and pastes a multiline draft',
    (tester) async {
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final input = find.byType(TextField);
      const text = '明日 study\n日本語の復習';
      await tester.enterText(input, text);
      await tester.pump();
      final field = tester.widget<TextField>(input);
      final editor = tester.state<EditableTextState>(find.byType(EditableText));
      editor.showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(
        field.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      editor.showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(clipboard, text);
      expect(field.controller!.text, text);
      editor.showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('剪切'));
      await tester.pumpAndSettle();
      expect(field.controller!.text, isEmpty);
      expect(field.focusNode!.hasFocus, isTrue);
      editor.showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      expect(field.controller!.text, text);
      expect(home.starts, 0);
      expect(home.sent, isEmpty);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'voice targets fit narrow screens and large text in all languages',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final language in ['zh', 'en', 'ja']) {
        for (final brightness in Brightness.values) {
          await show(
            tester,
            const InputBottomBar(),
            reducedMotion: true,
            textScale: 2,
            language: language,
            brightness: brightness,
          );
          final surface = find.byKey(const ValueKey('composer-input-surface'));
          final origin = tester.getCenter(surface);
          final press = await tester.startGesture(origin);
          await tester.pump(const Duration(milliseconds: 700));
          await press.moveTo(origin + const Offset(-70, -80));
          await tester.pumpAndSettle();
          expect(find.byType(VoiceCaptureFeedback), findsOneWidget);
          expect(tester.takeException(), isNull);
          final targets = tester.getRect(find.byType(VoiceCaptureFeedback));
          expect(targets.width, lessThanOrEqualTo(320));
          await press.up();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
      expect(home.cancels, 6);
      expect(home.stops, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'unmount during permission discards the late recording start',
    (tester) async {
      home.pendingStart = Completer<bool>();
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final press = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('composer-input-surface'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
      home.pendingStart!.complete(true);
      await tester.pumpAndSettle();
      await press.up();
      expect(home.cancels, 1);
      expect(home.stops, 0);
      expect(home.state.isRecording, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS pointer cancellation discards a delayed native start',
    (tester) async {
      home.pendingStart = Completer<bool>();
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final press = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('composer-input-surface'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await press.cancel();
      await tester.pump();
      home.pendingStart!.complete(true);
      await tester.pumpAndSettle();
      expect(home.cancels, 1);
      expect(home.stops, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'release during native recorder startup still stops that recording',
    (tester) async {
      home.pendingStart = Completer<bool>();
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final gestures = tester.widget<GestureDetector>(
        find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector && widget.onLongPressStart != null,
        ),
      );
      gestures.onLongPressStart!(const LongPressStartDetails());
      await tester.pump();
      gestures.onLongPressEnd!(const LongPressEndDetails());
      home.pendingStart!.complete(true);
      await tester.pumpAndSettle();
      expect(home.stops, 1);
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(find.byType(TextField), findsOneWidget);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'card metadata and actions fit narrow layouts with large text in all languages',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final task = Reminder(
        id: 'large-card',
        quadrantLevel: 1,
        taskTitle: 'A long task title with important details 准备完整的项目架构评审材料',
        taskSummary: 'A readable summary that can wrap across multiple lines.',
        isEmotionFiltered: true,
        isDynamicallyPromoted: true,
        isRecurring: true,
        recurrenceDescription: 'Every weekday at the agreed local time',
        triggerTime: DateTime.now().add(const Duration(days: 1)),
        spacedRepetitionLevel: 3,
        contextTrigger: '{}',
        linkedTaskIds: ['a'],
        subTasks:
            '["Prepare architecture diagrams", "Review performance evidence"]',
      );
      for (final language in ['zh', 'en', 'ja']) {
        for (final width in [375.0, 768.0, 1440.0]) {
          tester.view.physicalSize = Size(width, 1400);
          await show(
            tester,
            TaskCard(task: task, onPlayMedia: () {}),
            textScale: 2,
            language: language,
            reducedMotion: true,
          );
          expect(tester.takeException(), isNull, reason: '$language at $width');
          expect(
            tester.getSize(find.byKey(const ValueKey('complete-large-card'))),
            const Size(48, 48),
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('actions-large-card')))
                .height,
            greaterThanOrEqualTo(48),
          );
        }
      }
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('subtasks and task menu can be operated with the keyboard', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(
      tester,
      TaskCard(
        task: Reminder(
          id: 'keyboard',
          taskTitle: 'Keyboard task',
          quadrantLevel: 1,
          subTasks: '["Subtask contents"]',
        ),
        onPlayMedia: () {},
      ),
    );
    final button = find.byKey(const ValueKey('subtasks-keyboard'));
    Focus.of(
      tester.element(
        find.descendant(of: button, matching: find.byType(Text)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('Subtask contents'), findsNothing);
    expect(find.bySemanticsLabel('标为已完成: Keyboard task'), findsOneWidget);
    final menu = find.byKey(const ValueKey('actions-keyboard'));
    Focus.of(
      tester.element(
        find.descendant(of: menu, matching: find.byType(Icon)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('删除事项'), findsOneWidget);
    semantics.dispose();
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'completion write failure keeps the task open and does not cancel notifications',
    (tester) async {
      final task = Reminder(
        id: 'failed-update',
        taskTitle: 'Keep task open',
        quadrantLevel: 1,
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).addReminder(task),
      );
      notifications.canceled.clear();
      notifications.scheduled.clear();
      final db = await tester.runAsync(() => database.database);
      await tester.runAsync(
        () => db!.execute(
          "CREATE TRIGGER reject_update BEFORE UPDATE ON Reminders BEGIN SELECT RAISE(ABORT, 'test failure'); END",
        ),
      );
      await show(tester, card(task.id));
      await tester.runAsync(
        () => tester.tap(find.byKey(ValueKey('complete-${task.id}'))),
      );
      for (
        var i = 0;
        i < 50 && find.text('提醒更新失败，请重试。').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(container.read(remindersProvider).single.isCompleted, isFalse);
      expect(notifications.canceled, isEmpty);
      expect(find.text('提醒更新失败，请重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final reopen in [false, true]) {
    testWidgets(
      '${reopen ? 'reopening' : 'completion'} native failure reports the task is saved',
      (tester) async {
        final task = Reminder(
          id: 'native-failure',
          taskTitle: 'Persist before native reconciliation',
          quadrantLevel: 3,
          triggerTime: DateTime.now().add(const Duration(hours: 1)),
          isCompleted: reopen,
        );
        await tester.runAsync(
          () => container.read(remindersProvider.notifier).addReminder(task),
        );
        notifications.failNative = true;
        await show(tester, card(task.id));
        await tester.runAsync(
          () => tester.tap(find.byKey(ValueKey('complete-${task.id}'))),
        );
        const message = '已保存，但系统提醒未能更新。请检查通知权限并重新保存任务。';
        for (var i = 0; i < 50 && find.text(message).evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(container.read(remindersProvider).single.isCompleted, !reopen);
        final stored = await tester.runAsync(
          () => database.read(
            database.captureGeneration(),
            (db) =>
                db.query('Reminders', where: 'id = ?', whereArgs: [task.id]),
          ),
        );
        expect(stored!.single['is_completed'], reopen ? 0 : 1);
        expect(find.text(message), findsOneWidget);
        expect(find.text('提醒更新失败，请重试。'), findsNothing);
        expect(tester.takeException(), isNull);
        addTearDown(() => drainWorkspaceDrafts(tester, container));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('failed swipe deletion retains the card and reports failure', (
    tester,
  ) async {
    final task = Reminder(
      id: 'failed-delete',
      taskTitle: 'Keep task visible',
      quadrantLevel: 1,
    );
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).addReminder(task),
    );
    notifications.canceled.clear();
    notifications.scheduled.clear();
    final db = await tester.runAsync(() => database.database);
    await tester.runAsync(
      () => db!.execute(
        "CREATE TRIGGER reject_delete BEFORE DELETE ON Reminders BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      ),
    );
    await show(tester, card(task.id));
    await tester.drag(find.byType(TaskCard), const Offset(-700, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (var i = 0; i < 50 && find.text('删除失败，请重试。').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(remindersProvider).single.id, task.id);
    expect(find.text(task.taskTitle), findsOneWidget);
    expect(find.text('删除失败，请重试。'), findsOneWidget);
    expect(notifications.canceled, isEmpty);
    expect(tester.takeException(), isNull);
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'successful swipe deletion exposes Undo after its card unmounts',
    (tester) async {
      final task = Reminder(
        id: 'undo-delete',
        taskTitle: 'Bring this task back',
        quadrantLevel: 1,
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).addReminder(task),
      );
      notifications.canceled.clear();
      notifications.scheduled.clear();
      await show(tester, card(task.id));
      await tester.drag(find.byType(TaskCard), const Offset(-700, 0));
      for (var i = 0; i < 50 && find.text('撤销').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(TaskCard), findsNothing);
      expect(notifications.canceled, [task.id]);
      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      for (
        var i = 0;
        i < 50 && container.read(remindersProvider).isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(TaskCard), findsOneWidget);
      expect(container.read(remindersProvider).single.id, task.id);
      expect(tester.takeException(), isNull);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'dark input send action uses the foreground paired with its primary fill',
    (tester) async {
      final settings = container.read(settingsProvider.notifier);
      await tester.runAsync(
        () => settings.updateSettings(
          settings.state.copyWith(inputSendMode: InputSendMode.button),
        ),
      );
      await show(tester, const InputBottomBar(), brightness: Brightness.dark);
      await tester.enterText(find.byType(TextField), 'Ready to send');
      await tester.pump();
      final finder = find.widgetWithIcon(
        IconButton,
        Icons.arrow_upward_rounded,
      );
      final button = tester.widget<IconButton>(finder);
      final colors = Theme.of(tester.element(finder)).colorScheme;
      expect(button.onPressed, isNotNull);
      expect(button.style!.backgroundColor!.resolve({}), colors.primary);
      expect(button.style!.foregroundColor!.resolve({}), colors.onPrimary);
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
