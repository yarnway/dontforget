import 'package:dont_forget/services/voice_text_draft.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:dont_forget/ui/widgets/live_voice_text_dialog.dart';
import 'support/real_io.dart';
import 'support/workspace_drafts.dart';

class _Recorder implements AudioRecorder {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Home extends HomeController {
  _Home(super.ref) : super(audioRecorder: _Recorder());
  int starts = 0, prepares = 0, cancels = 0, saves = 0;
  final sent = <String>[];
  Completer<String?>? finalResult;
  bool failed = false;
  void preview(String value) {
    state = state.copyWith(voicePreview: value);
  }

  @override
  Future<bool> startRecording() async {
    starts++;
    state = HomeState(isRecording: true);
    return true;
  }

  @override
  void prepareRecordingTranscription() {
    prepares++;
    state = state.copyWith(voicePreview: '明天买牛奶');
  }

  @override
  VoiceTextDraft createVoiceTextDraft() => VoiceTextDraft(
    result: stopRecordingToText(),
    saveOriginal: () async {
      await stopRecordingAndProcess();
      return true;
    },
    releaseCapture: (_) async {},
  );

  @override
  Future<String?> stopRecordingToText({bool Function()? canAcceptDraft}) async {
    state = state.copyWith(isRecording: false);
    final result = finalResult == null
        ? '明天上午九点买牛奶'
        : await finalResult!.future;
    if (failed) state = state.copyWith(error: '原声已保存，请核对文字');
    return result;
  }

  @override
  Future<void> stopRecordingAndProcess() async {
    saves++;
    state = state.copyWith(isRecording: false);
  }

  @override
  Future<bool> cancelRecording() async {
    cancels++;
    state = HomeState();
    return true;
  }

  @override
  Future<bool> processText(
    String text, {
    DateTime? reminderTime,
    bool memoOnly = false,
    String? captureId,
  }) async {
    sent.add(text);
    return true;
  }
}

void main() {
  late Directory root;
  late DatabaseHelper db;
  late ProviderContainer container;
  late _Home home;
  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('live-voice-ui-');
    db = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(db),
        homeControllerProvider.overrideWith((ref) => _Home(ref)),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
    home = container.read(homeControllerProvider.notifier) as _Home;
  });
  tearDown(() async {
    container.dispose();
    await db.close(createBackup: false);
    await root.delete(recursive: true);
  });
  Future<void> show(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const Scaffold(
            body: Column(
              children: [
                Expanded(child: SizedBox()),
                InputBottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<({TestGesture gesture, Offset origin})> hold(
    WidgetTester tester,
  ) async {
    final origin = tester.getCenter(
      find.byKey(const ValueKey('composer-input-surface')),
    );
    final gesture = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    return (gesture: gesture, origin: origin);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, container);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('explicit voice mode starts after 200ms, not on a short tap', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('composer-mode-toggle')));
    await tester.pumpAndSettle();
    final origin = tester.getCenter(
      find.byKey(const ValueKey('composer-input-surface')),
    );
    final tap = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 100));
    await tap.up();
    await tester.pumpAndSettle();
    expect(home.starts, 0);
    expect(home.prepares, 0);
    final held = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pump();
    expect(home.starts, 1);
    expect(home.prepares, greaterThan(0));
    await held.up();
    await tester.pumpAndSettle();
    expect(home.saves, 1);
    expect(home.sent, isEmpty);
    await finish(tester);
  });

  testWidgets(
    'recognition prepares before upward/right preview, ordinary release edits',
    (tester) async {
      await show(tester);
      final held = await hold(tester);
      expect(home.prepares, greaterThan(0));
      await held.gesture.moveTo(held.origin + const Offset(0, -70));
      await tester.pumpAndSettle();
      expect(home.prepares, greaterThan(0));
      expect(home.sent, isEmpty);
      // The vertical gesture alone reveals already prepared text, even when
      // it did not change the release action or trigger another partial.
      expect(
        find.byKey(const ValueKey('voice-transcript-preview')),
        findsOneWidget,
      );
      await held.gesture.moveTo(held.origin + const Offset(70, -70));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voice-transcript-preview')),
        findsOneWidget,
      );
      expect(find.text('明天买牛奶'), findsOneWidget);
      await held.gesture.up();
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('voice-text-editor'));
      expect(tester.widget<TextField>(editor).controller!.text, '明天上午九点买牛奶');
      expect(home.sent, isEmpty);
      await tester.enterText(editor, '改为十点买牛奶');
      await tester.pumpAndSettle();
      expect(home.sent, isEmpty);
      if (find
          .byKey(const ValueKey('voice-editor-keep'))
          .evaluate()
          .isNotEmpty) {
        await tester.tap(find.byKey(const ValueKey('voice-editor-keep')));
        await tester.pumpAndSettle();
      }
      await finish(tester);
    },
  );
  testWidgets(
    'further right sends the final text once, after final recognition',
    (tester) async {
      await show(tester);
      home.finalResult = Completer<String?>();
      final held = await hold(tester);
      await held.gesture.moveTo(held.origin + const Offset(110, -70));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voice-release-caption')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('voice-release-caption')))
            .data,
        '松手发送文字',
      );
      await held.gesture.up();
      await tester.pump();
      expect(home.sent, isEmpty);
      home.finalResult!.complete('Buy milk tomorrow');
      await pumpUntilRealIo(
        tester,
        () => home.sent.isNotEmpty,
        reason:
            'Explicit send awaits final transcript and durable pending draft',
      );
      expect(home.sent, ['Buy milk tomorrow']);
      await finish(tester);
    },
  );
  testWidgets(
    'editing is available before recognition ends and late text cannot replace edits',
    (tester) async {
      await show(tester);
      home.finalResult = Completer<String?>();
      final held = await hold(tester);
      await held.gesture.moveTo(held.origin + const Offset(70, -70));
      await tester.pumpAndSettle();
      await held.gesture.up();
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('voice-text-editor'));
      expect(tester.widget<TextField>(editor).controller!.text, '明天买牛奶');
      await tester.enterText(editor, '自己修改的文字');
      home.preview('后来的识别');
      home.finalResult!.complete('最后的识别');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, '自己修改的文字');
      await tester.tap(find.byKey(const ValueKey('voice-editor-keep')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '自己修改的文字',
      );
      expect(home.sent, isEmpty);
      await finish(tester);
    },
  );

  testWidgets(
    'active IME composition is not replaced by late recognition or submitted by Enter',
    (tester) async {
      await show(tester);
      home.finalResult = Completer<String?>();
      final held = await hold(tester);
      await held.gesture.moveTo(held.origin + const Offset(70, -70));
      await tester.pumpAndSettle();
      await held.gesture.up();
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('voice-text-editor'));
      final initial = tester.widget<TextField>(editor).controller!.text;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: initial,
          selection: TextSelection.collapsed(offset: initial.length),
          composing: TextRange(start: 0, end: initial.length),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('voice-editor-send')),
            )
            .onPressed,
        isNull,
      );
      home.preview('不能覆盖中文候选');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      home.finalResult!.complete('最终识别也不能覆盖');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, initial);
      expect(home.sent, isEmpty);
      await tester.tap(find.byKey(const ValueKey('voice-editor-keep')));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets(
    'voice editor fits small keyboards, large fonts and all languages',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [const Size(320, 568), const Size(375, 812)]) {
        tester.view.physicalSize = size;
        for (final language in ['zh', 'en', 'ja']) {
          for (final scale in [1.0, 2.0]) {
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
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      viewInsets: const EdgeInsets.only(bottom: 250),
                      disableAnimations: true,
                    ),
                    child: child!,
                  ),
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () => showDialog<bool>(
                          context: context,
                          builder: (_) => LiveVoiceTextDialog(
                            result: Future.value('中文 English \n' * 30),
                            prefix: '',
                            initial: '',
                            onChanged: (_) {},
                          ),
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('open'));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$size / $language / $scale',
            );
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('voice-editor-send')))
                  .bottom,
              lessThanOrEqualTo(size.height - 250),
            );
            await tester.tap(find.byKey(const ValueKey('voice-editor-keep')));
            await tester.pumpAndSettle();
          }
        }
      }
      await finish(tester);
    },
  );

  testWidgets(
    'landscape keyboard keeps editor and both actions visible in every language',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(568, 320);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
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
              theme: ThemeData(platform: TargetPlatform.android),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  viewInsets: const EdgeInsets.only(bottom: 220),
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showDialog<bool>(
                      context: context,
                      builder: (_) => LiveVoiceTextDialog(
                        result: Future.value('长文字 English ' * 30),
                        prefix: '',
                        initial: '已有文字',
                        onChanged: (_) {},
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final key in [
          'voice-text-editor',
          'voice-editor-keep',
          'voice-editor-original',
          'voice-editor-send',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.bottom, lessThanOrEqualTo(100));
          expect(rect.height, greaterThanOrEqualTo(40));
        }
        final field = find.byKey(const ValueKey('voice-text-editor'));
        await tester.enterText(field, '调整后的文字');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, '调整后的文字');
        await tester.tap(find.byKey(const ValueKey('voice-editor-keep')));
        await tester.pumpAndSettle();
      }
      await finish(tester);
    },
  );
  testWidgets(
    'keyboard resize keeps manual text and IME composition while final recognition arrives',
    (tester) async {
      await show(tester);
      home.finalResult = Completer<String?>();
      final held = await hold(tester);
      await held.gesture.moveTo(held.origin + const Offset(70, -70));
      await tester.pumpAndSettle();
      await held.gesture.up();
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('voice-text-editor'));
      final editState = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      try {
        final draft = '保留中文候选' * 20;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: draft,
            selection: TextSelection.collapsed(offset: draft.length),
            composing: TextRange(start: draft.length - 6, end: draft.length),
          ),
        );
        await tester.pump();
        expect(
          tester.widget<TextField>(field).controller!.value.composing,
          TextRange(start: draft.length - 6, end: draft.length),
        );
        tester.view.physicalSize = const Size(568, 320);
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(
          tester.state<EditableTextState>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          ),
          same(editState),
        );
        expect(editState.widget.focusNode.hasFocus, isTrue);
        home.preview('较晚的中间结果');
        home.finalResult!.complete('最终识别结果');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, draft);
        expect(
          tester.widget<TextField>(field).controller!.value.composing,
          TextRange(start: draft.length - 6, end: draft.length),
        );
        expect(home.sent, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        final keep = find.byKey(const ValueKey('voice-editor-keep'));
        if (keep.evaluate().isNotEmpty) {
          await tester.tap(keep);
          await tester.pumpAndSettle();
        }
        await finish(tester);
      }
    },
  );

  testWidgets(
    'editor grows with text, shrinks after deletion and caps above the keyboard',
    (tester) async {
      await show(tester);
      final held = await hold(tester);
      await held.gesture.moveTo(held.origin + const Offset(70, -70));
      await tester.pumpAndSettle();
      await held.gesture.up();
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('voice-text-editor'));
      final short = tester.getSize(field).height;
      expect(short, lessThan(140));
      expect(find.text('发送原语音'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('voice-editor-original'))).top,
        greaterThanOrEqualTo(tester.getRect(field).bottom),
      );
      final editorState = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      await tester.enterText(field, '中文 English\n' * 5);
      await tester.pumpAndSettle();
      final medium = tester.getSize(field).height;
      expect(medium, greaterThan(short));
      await tester.enterText(field, '中文 English\n' * 100);
      await tester.pumpAndSettle();
      expect(tester.getSize(field).height, greaterThan(medium));
      expect(tester.getSize(field).height, lessThan(520));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('voice-editor-send'))).bottom,
        lessThanOrEqualTo(512),
      );
      expect(
        tester.state<EditableTextState>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        ),
        same(editorState),
      );
      await tester.enterText(field, '短文字');
      await tester.pumpAndSettle();
      expect(tester.getSize(field).height, short);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('voice-editor-keep')));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets(
    'send original uses this capture once and restores the prior typed draft',
    (tester) async {
      await show(tester);
      await tester.enterText(find.byType(TextField), '已有草稿');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-mode-toggle')));
      await tester.pumpAndSettle();
      home.finalResult = Completer<String?>();
      final held = await hold(tester);
      await held.gesture.moveTo(held.origin + const Offset(70, -70));
      await tester.pumpAndSettle();
      await held.gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-editor-original')));
      await tester.pumpAndSettle();
      expect(home.starts, 1);
      expect(home.saves, 1);
      expect(home.sent, isEmpty);
      expect(find.byKey(const ValueKey('voice-text-editor')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '已有草稿',
      );
      home.finalResult!.complete('不应再添加的识别文字');
      home.preview('迟到的预览');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '已有草稿',
      );
      expect(home.sent, isEmpty);
      await finish(tester);
    },
  );

  testWidgets(
    'original save is exclusive, preserves edits on failure and can retry',
    (tester) async {
      await show(tester);
      final result = Completer<String?>();
      var attempts = 0;
      var saving = Completer<bool>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (_) => LiveVoiceTextDialog(
                      result: result.future,
                      prefix: '',
                      initial: '已有文字',
                      onChanged: (_) {},
                      onSendOriginal: () {
                        attempts++;
                        return saving.future;
                      },
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('voice-text-editor'));
      await tester.enterText(field, '保留修改后的文字');
      final original = find.byKey(const ValueKey('voice-editor-original'));
      await tester.tap(original);
      await tester.tap(original);
      await tester.pump();
      expect(attempts, 1);
      expect(tester.widget<TextField>(field).readOnly, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('voice-editor-send')),
            )
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(field, findsOneWidget);
      result.complete('迟到的转写');
      saving.complete(false);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '保留修改后的文字');
      expect(tester.widget<TextField>(field).readOnly, isFalse);
      saving = Completer<bool>();
      await tester.tap(original);
      await tester.pump();
      expect(attempts, 2);
      saving.complete(true);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'Send submits visible partial text without waiting for final recognition',
    (tester) async {
      await show(tester);
      home.finalResult = Completer<String?>();
      final held = await hold(tester);
      await held.gesture.moveTo(held.origin + const Offset(70, -70));
      await tester.pumpAndSettle();
      await held.gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-editor-send')));
      await pumpUntilRealIo(
        tester,
        () => home.sent.isNotEmpty,
        reason: 'Explicit Send commits the visible transcript',
      );
      expect(home.sent, ['明天买牛奶']);
      expect(home.finalResult!.isCompleted, isFalse);
      home.finalResult!.complete('late final');
      await tester.pumpAndSettle();
      expect(home.sent, ['明天买牛奶']);
      expect(home.saves, 0);
      await finish(tester);
    },
  );

  testWidgets('left release cancels without sending a visible partial', (
    tester,
  ) async {
    await show(tester);
    final held = await hold(tester);
    await held.gesture.moveTo(held.origin + const Offset(70, -70));
    await tester.pumpAndSettle();
    await held.gesture.moveTo(held.origin + const Offset(-70, -70));
    await tester.pumpAndSettle();
    await held.gesture.up();
    await tester.pumpAndSettle();
    expect(home.cancels, 1);
    expect(home.sent, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await finish(tester);
  });
  testWidgets('failed final recognition never automatically sends a partial', (
    tester,
  ) async {
    await show(tester);
    home.failed = true;
    final held = await hold(tester);
    await held.gesture.moveTo(held.origin + const Offset(110, -70));
    await tester.pumpAndSettle();
    await held.gesture.up();
    await tester.pumpAndSettle();
    expect(home.sent, isEmpty);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('voice-text-editor')))
          .controller!
          .text,
      isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('voice-editor-keep')));
    await tester.pumpAndSettle();
    await finish(tester);
  });
}
