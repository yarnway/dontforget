import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/global_capture_provider.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/interaction_preview.dart';
import 'support/offline_management_harness.dart';
import 'support/real_io.dart';
import 'support/workspace_drafts.dart';

class _Home extends HomeController {
  _Home(super.ref);
  final sent = <String>[];
  bool success = true;
  int starts = 0;
  @override
  Future<bool> processText(
    String text, {
    DateTime? reminderTime,
    bool memoOnly = false,
    String? captureId,
  }) async {
    sent.add(text);
    return success;
  }

  @override
  Future<bool> startRecording() async {
    starts++;
    state = state.copyWith(isRecording: true);
    return true;
  }

  void recording(bool value) => state = state.copyWith(isRecording: value);
}

void main() {
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Home home;
  final fieldFinder = find.byType(TextField);
  final frameFinder = find.byKey(const ValueKey('composer-frame'));
  setUpAll(loadInteractionPreviewFonts);
  setUp(() async {
    sqfliteFfiInit();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
    directory = await Directory.systemTemp.createTemp(
      'dontforget-windows-composer-',
    );
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(
          OfflineTestNotifications(),
        ),
        remindersProvider.overrideWith(
          (_) => RemindersNotifier(
            database,
            notifications: OfflineTestNotifications(),
            runLoadEffects: false,
          ),
        ),
        homeControllerProvider.overrideWith((ref) => home = _Home(ref)),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    container.read(homeControllerProvider);
  });
  tearDown(() async {
    container.dispose();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          null,
        );
  });
  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    String language = 'zh',
    double scale = 1,
    bool dark = false,
    bool preview = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: interactionPreviewKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: (dark ? AppTheme.dark : AppTheme.light).copyWith(
              platform: TargetPlatform.windows,
            ),
            locale: Locale(language),
            supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: InlineFeedback(child: child!),
            ),
            home: Scaffold(
              appBar: preview ? AppBar(title: const Text('别忘了')) : null,
              body: Column(
                children: [
                  Expanded(
                    child: preview
                        ? Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 90,
                              vertical: 18,
                            ),
                            child: ListView(
                              children: [
                                const Text(
                                  '今天',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 18),
                                for (final title in ['准备项目评审', '整理本周的学习笔记'])
                                  Card.outlined(
                                    child: ListTile(
                                      leading: const Icon(
                                        Icons.circle,
                                        size: 7,
                                      ),
                                      title: Text(title),
                                      subtitle: const Text('本地合成预览事项'),
                                      trailing: const Icon(
                                        Icons.check_box_outline_blank,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          )
                        : const SizedBox(),
                  ),
                  const InputBottomBar(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextField field(WidgetTester tester) => tester.widget<TextField>(fieldFinder);
  Future<void> replace(
    WidgetTester tester,
    String text, {
    bool composing = false,
  }) async {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: composing
            ? TextRange(start: text.length - 4, end: text.length)
            : TextRange.empty,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await drainWorkspaceDrafts(tester, container);
  }

  testWidgets(
    'Windows starts compact and click or global focus keeps an empty or short input compact',
    (tester) async {
      await show(tester);
      expect(field(tester).focusNode!.hasFocus, isFalse);
      expect(field(tester).minLines, 1);
      final idle = tester.getRect(frameFinder);
      expect(idle.height, lessThanOrEqualTo(80));
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final mouse = await tester.startGesture(
        tester.getCenter(fieldFinder),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(field(tester).focusNode!.hasFocus, isTrue);
      expect(tester.getRect(frameFinder), idle);
      await replace(tester, 'Keep this short draft');
      final before = field(tester).controller!.value;
      expect(container.read(captureInputCommandProvider).focus!(), isTrue);
      await tester.pumpAndSettle();
      expect(field(tester).controller!.value, before);
      expect(tester.getRect(frameFinder).height, idle.height);
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editable),
      );
      expect(home.sent, isEmpty);
      expect(home.starts, 0);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets(
    'wrapped lines and long pastes grow the same focused IME editor and clearing shrinks it',
    (tester) async {
      await show(tester);
      await tester.tap(fieldFinder);
      await replace(tester, 'ming', composing: true);
      final small = tester.getRect(frameFinder);
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      for (final text in [
        'first\nsecond\nming',
        '${'长段文字 editable draft ' * 25}ming',
      ]) {
        await replace(tester, text, composing: true);
        final value = field(tester).controller!.value;
        expect(field(tester).minLines, greaterThanOrEqualTo(3));
        expect(tester.getRect(frameFinder).height, greaterThan(small.height));
        expect(tester.getRect(frameFinder).height, lessThan(300));
        expect(field(tester).focusNode!.hasFocus, isTrue);
        expect(
          tester.state<EditableTextState>(find.byType(EditableText)),
          same(editable),
        );
        expect(value.text, text);
        expect(
          value.composing,
          TextRange(start: text.length - 4, end: text.length),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(
          home.sent,
          isEmpty,
          reason: 'An active IME composition cannot be sent',
        );
        expect(field(tester).controller!.value, value);
      }
      await replace(tester, 'small');
      expect(tester.getRect(frameFinder).height, small.height);
      await replace(tester, '');
      expect(tester.getRect(frameFinder).height, small.height);
      expect(field(tester).focusNode!.hasFocus, isTrue);
      expect(home.starts, 0);
      await unmount(tester);
    },
  );

  testWidgets(
    'large text without explicit newlines expands, scrolls, and keeps actions accessible',
    (tester) async {
      await show(tester, size: const Size(900, 700));
      await tester.tap(fieldFinder);
      final text = 'large unbroken paste sample ' * 4000;
      await replace(tester, text);
      expect(field(tester).controller!.text, text);
      expect(field(tester).minLines, greaterThan(1));
      final frame = tester.getRect(frameFinder);
      expect(frame.height, lessThan(300));
      for (final key in [
        'composer-desktop-voice',
        'composer-attachment',
        'composer-send',
      ]) {
        final action = find.byKey(ValueKey(key));
        final rect = tester.getRect(action);
        expect(frame.contains(rect.center), isTrue);
        expect(rect.height, greaterThanOrEqualTo(44));
      }
      // Scroll the real editor rather than growing the entire work area.
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      expect(
        editable.offset.pixels,
        greaterThan(0),
        reason: 'The caret at the end of a large paste scrolls the editor',
      );
      expect(home.sent, isEmpty);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets(
    'resize and font changes preserve a live composition without replacing EditableText',
    (tester) async {
      await show(tester);
      await tester.tap(fieldFinder);
      final text = '${'中文 and editable text ' * 20}ming';
      await replace(tester, text, composing: true);
      final before = field(tester).controller!.value;
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      for (final size in [
        const Size(375, 500),
        const Size(1440, 900),
        const Size(768, 500),
      ]) {
        await show(tester, size: size, scale: size.width < 800 ? 2 : 1);
        expect(field(tester).controller!.value, before);
        expect(field(tester).focusNode!.hasFocus, isTrue);
        expect(
          tester.state<EditableTextState>(find.byType(EditableText)),
          same(editable),
        );
        expect(tester.getRect(frameFinder).height, lessThan(size.height * .55));
        expect(tester.takeException(), isNull);
      }
      expect(home.sent, isEmpty);
      await unmount(tester);
    },
  );

  testWidgets('persisted large drafts reopen expanded without stealing focus', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(fieldFinder);
    final text = 'Durable existing draft\n' * 25;
    await replace(tester, text);
    await unmount(tester);
    await show(tester);
    await pumpUntilRealIo(
      tester,
      () => field(tester).controller!.text == text,
      reason: 'The existing draft must finish restoring',
    );
    expect(field(tester).focusNode!.hasFocus, isFalse);
    expect(field(tester).minLines, greaterThan(1));
    expect(home.sent, isEmpty);
    await unmount(tester);
  });

  testWidgets(
    'three languages, themes, large fonts and short windows retain usable actions',
    (tester) async {
      for (final size in [
        const Size(320, 400),
        const Size(768, 600),
        const Size(1440, 900),
      ]) {
        for (final language in ['zh', 'en', 'ja']) {
          for (final scale in [1.0, 2.0]) {
            await show(
              tester,
              size: size,
              language: language,
              scale: scale,
              dark: scale > 1,
            );
            await tester.enterText(fieldFinder, '');
            await tester.pumpAndSettle();
            expect(field(tester).minLines, 1);
            expect(
              tester.getRect(frameFinder).height,
              lessThan(size.height * .5),
            );
            await tester.enterText(
              fieldFinder,
              '日常の入力\nSecond line\n第三行 long draft',
            );
            await tester.pumpAndSettle();
            for (final key in [
              'composer-desktop-voice',
              'composer-attachment',
              'composer-send',
              'capture-time-options',
            ]) {
              final action = find.byKey(ValueKey(key));
              final rect = tester.getRect(action);
              expect(
                tester.getRect(frameFinder).contains(rect.center),
                isTrue,
                reason: '$size/$scale/$language/$key',
              );
              expect(rect.height, greaterThanOrEqualTo(44));
            }
            expect(
              tester.takeException(),
              isNull,
              reason: '$size/$language/$scale',
            );
          }
        }
      }
      await unmount(tester);
    },
  );

  testWidgets(
    'failed Send preserves the expanded draft, successful Send returns to compact input',
    (tester) async {
      await show(tester);
      await tester.runAsync(
        () => container
            .read(settingsProvider.notifier)
            .updateSettings(
              container
                  .read(settingsProvider)
                  .copyWith(inputSendMode: InputSendMode.button),
            ),
      );
      await tester.tap(fieldFinder);
      const text = 'first line\nsecond line\nthird line';
      await replace(tester, text);
      home.success = false;
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await pumpUntilRealIo(
        tester,
        () => home.sent.length == 1,
        reason: 'Send waits for the durable draft',
      );
      await drainWorkspaceDrafts(tester, container);
      expect(field(tester).controller!.text, text);
      expect(field(tester).minLines, greaterThan(1));
      home.success = true;
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await pumpUntilRealIo(
        tester,
        () => field(tester).controller!.text.isEmpty,
        reason: 'Only successful Send clears this draft',
      );
      expect(home.sent, [text, text]);
      expect(field(tester).minLines, 1);
      expect(tester.getRect(frameFinder).height, lessThanOrEqualTo(80));
      await unmount(tester);
    },
  );

  testWidgets(
    'Windows composer rendering preview uses the actual compact and expanded widget',
    (tester) async {
      await show(
        tester,
        size: const Size(1280, 720),
        dark: true,
        preview: true,
      );
      await captureInteractionPreview(tester, 'windows-composer-61-empty');
      await tester.tap(fieldFinder);
      await replace(tester, '整理本周的工作笔记');
      await captureInteractionPreview(tester, 'windows-composer-61-short');
      await replace(
        tester,
        '整理本周的工作笔记\n汇总评审意见，补充下次讨论需要的资料\n检查后保存为一条可继续编辑的记录\n保留文字，按内容自动增高输入区',
      );
      await captureInteractionPreview(tester, 'windows-composer-61-expanded');
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );
}
