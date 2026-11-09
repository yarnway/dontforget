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
