import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/shared_text_provider.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/shared_text_inbox.dart';
import 'package:dont_forget/ui/screens/shared_text_inbox_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/task_attachments_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'support/offline_management_harness.dart';
import 'support/real_io.dart';
import 'support/workspace_drafts.dart';

class _Recorder implements AudioRecorder {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Home extends HomeController {
  _Home(super.ref) : super(audioRecorder: _Recorder());
  int saves = 0;
  @override
  Future<bool> processText(
    String text, {
    DateTime? reminderTime,
    bool memoOnly = false,
    String? captureId,
  }) {
    saves++;
    return super.processText(
      text,
      reminderTime: reminderTime,
      memoOnly: memoOnly,
      captureId: captureId,
    );
  }
}

void main() {
  late OfflineManagementHarness h;
  late SharedTextInbox inbox;
  late _Home home;
  late ProviderContainer uiContainer;
  const id = '00000000-0000-4000-8000-000000000001';
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    inbox = h.container.read(sharedTextInboxProvider);
    await h.container.read(workspaceDraftsProvider.notifier).put('capture', {
      'text': '保留首页草稿',
    });
    await inbox.accept(
      const SharedText(id: id, text: '分享原文', createdAt: 1762300800000),
    );
  });
  tearDown(() => h.dispose());

  Future<void> show(
    WidgetTester tester, {
    bool openEditor = true,
    TargetPlatform? platform,
  }) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await drainWorkspaceDrafts(tester, h.container);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: ProviderScope(
          overrides: [
            homeControllerProvider.overrideWith((ref) => home = _Home(ref)),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (_, child) => InlineFeedback(child: child!),
            home: const SharedTextInboxScreen(),
          ),
        ),
      ),
    );
    await pumpUntilRealIo(
      tester,
      () => find.byKey(const ValueKey('shared-item-$id')).evaluate().isNotEmpty,
      reason: 'Persisted inbox must load',
    );
    await tester.pumpAndSettle();
    if (!openEditor) return;
    await tester.tap(find.byKey(const ValueKey('shared-item-$id')));
    await tester.pumpAndSettle();
    uiContainer = ProviderScope.containerOf(
      tester.element(find.byKey(const ValueKey('shared-text-editor'))),
      listen: false,
    );
    home = uiContainer.read(homeControllerProvider.notifier) as _Home;
    await tester.showKeyboard(find.byKey(const ValueKey('shared-text-editor')));
    await tester.pump();
  }

  const composing = TextEditingValue(
    text: '分享中文',
    selection: TextSelection.collapsed(offset: 4),
    composing: TextRange(start: 2, end: 4),
  );

  testWidgets('a persisted web link opens externally and remains editable', (
    tester,
  ) async {
    const link = 'https://example.com/read?chapter=1#start';
    const original = '网页标题\n$link';
    await tester.runAsync(() => inbox.edit(id, '分享原文', original));
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var launchSucceeds = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return launchSucceeds;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await show(tester, openEditor: false);
    await tester.tap(find.byTooltip('在浏览器中打开'));
    await tester.pumpAndSettle();
    expect(calls.single.method, 'launch');
    expect(calls.single.arguments, containsPair('url', link));
    expect(calls.single.arguments, containsPair('useWebView', false));

    await tester.tap(find.text(original));
    await tester.pumpAndSettle();
    final editor = find.byKey(const ValueKey('shared-text-editor'));
    expect(tester.widget<TextField>(editor).controller!.text, original);
    launchSucceeds = false;
    await tester.tap(find.text('在浏览器中打开'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(find.text('无法打开网页链接。'), findsOneWidget);
    await tester.enterText(editor, '普通草稿');
    await tester.pump();
    expect(find.text('在浏览器中打开'), findsNothing);
  });

  testWidgets(
    'shared PDF opens directly and keeps file details as a fallback',
    (tester) async {
      const pdfId = '00000000-0000-4000-8000-000000000002';
      const name = '项目计划.PDF';
      await tester.runAsync(() async {
        final dir = Directory('${h.directory.path}/shared_handoff/$pdfId');
        await dir.create(recursive: true);
        final file = File('${dir.path}/$name');
        await file.writeAsString('%PDF-1.4');
        await inbox.accept(
          SharedText(
            id: pdfId,
            text: '',
            createdAt: 1762300801000,
            attachmentPath: file.path,
            attachmentName: name,
          ),
        );
      });
      const channel = MethodChannel('com.yarnway.dontforget/share');
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      var canPreview = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return canPreview;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await show(tester, openEditor: false, platform: TargetPlatform.iOS);
      await tester.tap(find.byTooltip('预览附件'));
      await pumpUntilRealIo(
        tester,
        () => calls.isNotEmpty,
        reason: 'One tap should request the system PDF viewer',
      );
      expect(calls.single.method, 'previewPDF');
      expect(calls.single.arguments, {'id': pdfId, 'name': name});
      expect(find.byType(TaskAttachmentPreview), findsNothing);

      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
      canPreview = false;
      await tester.tap(find.byKey(const ValueKey('shared-attachment-card')));
      final size = find.byKey(const ValueKey('attachment-preview-size'));
      await pumpUntilRealIo(
        tester,
        () => size.evaluate().isNotEmpty,
        reason: 'The attachment details must display the size',
      );
      await tester.pumpAndSettle();
      expect(find.text(name), findsOneWidget);
      expect(tester.widget<Text>(size).data, '8 B');
      expect(calls, hasLength(2));
      expect(calls.last.method, 'previewPDF');
      expect(await tester.runAsync(h.rows), isEmpty);
    },
  );

  testWidgets(
    'unconfirmed IME blocks memo save; range-only commit enables saving',
    (tester) async {
      await show(tester);
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      final save = find.byKey(const ValueKey('shared-save-memo'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(await tester.runAsync(h.rows), isEmpty);
      tester.testTextInput.updateEditingValue(
        composing.copyWith(composing: TextRange.empty),
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await pumpUntilRealIo(
        tester,
        () =>
            find.byKey(const ValueKey('shared-text-editor')).evaluate().isEmpty,
        reason: 'A confirmed share must save and return',
      );
      await drainWorkspaceDrafts(tester, h.container);
      expect(home.saves, 1);
      final rows = await tester.runAsync(h.rows);
      expect(rows, hasLength(1));
      expect(rows!.single.sourceText, composing.text);
      expect(rows.single.id, id);
      expect(rows.single.triggerTime, isNull);
      final stored = await tester.runAsync(
        () => h.container
            .read(workspaceDraftsProvider.notifier)
            .readPersistedKey(SharedTextInbox.key),
      );
      expect(SharedTextInboxData.parse(stored).items, isEmpty);
      final drafts = await tester.runAsync(h.drafts);
      expect(jsonDecode(drafts!)['capture']['text'], '保留首页草稿');
      expect(h.notifications.scheduled, isEmpty);
    },
  );

  testWidgets(
    'a previously queued save activation cannot submit a new composition',
    (tester) async {
      await show(tester);
      final activate = tester
          .widget<FilledButton>(find.byKey(const ValueKey('shared-save-memo')))
          .onPressed!;
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      activate();
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      await drainWorkspaceDrafts(tester, uiContainer);
      expect(home.saves, 0);
      expect(await tester.runAsync(h.rows), isEmpty);
      expect(find.byKey(const ValueKey('shared-text-editor')), findsOneWidget);
    },
  );

  testWidgets(
    'a relocated shared image previews and saves from its current container',
    (tester) async {
      const attachmentShareId = '00000000-0000-4000-8000-000000000002';
      final currentSupport = Directory(
        '${h.directory.path}/current/Library/Application Support',
      );
      final previousSupport =
          '${h.directory.path}/previous/Library/Application Support';
      final relocatedInbox = SharedTextInbox(
        h.container.read(workspaceDraftsProvider.notifier),
        supportDirectory: () async => currentSupport,
      );
      final handoffDir = await tester.runAsync(
        () => Directory(
          '${currentSupport.path}/shared_handoff/$attachmentShareId',
        ).create(recursive: true),
      );
      final imageBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aNo0AAAAASUVORK5CYII=',
      );
      final sourceImage = await tester.runAsync(
        () => File('${handoffDir!.path}/diagram.png').writeAsBytes(imageBytes),
      );
      await tester.runAsync(
        () => inbox.accept(
          SharedText(
            id: attachmentShareId,
            text: '',
            createdAt: 1762300801000,
            attachmentPath:
                '$previousSupport/shared_handoff/$attachmentShareId/diagram.png',
            attachmentName: 'diagram.png',
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await drainWorkspaceDrafts(tester, h.container);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: ProviderScope(
            overrides: [
              sharedTextInboxProvider.overrideWithValue(relocatedInbox),
            ],
            child: const MaterialApp(
              locale: Locale('zh'),
              supportedLocales: [Locale('zh'), Locale('en'), Locale('ja')],
              localizationsDelegates: [
                AppLocalizationsDelegate(),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: SharedTextInboxScreen(),
            ),
          ),
        ),
      );
      await pumpUntilRealIo(
        tester,
        () => find
            .byKey(const ValueKey('shared-item-$attachmentShareId'))
            .evaluate()
            .isNotEmpty,
        reason: 'Shared attachment item must load',
      );
      await tester.pumpAndSettle();
      expect(find.text('diagram.png'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('shared-item-$attachmentShareId')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('shared-attachment-card')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('shared-attachment-name')))
            .data,
        'diagram.png',
      );
      final thumbnail = find.byKey(const ValueKey('shared-attachment-image'));
      await pumpUntilRealIo(
        tester,
        () => thumbnail.evaluate().isNotEmpty,
        reason: 'The stale draft path should resolve to the current container',
      );
      await tester.tap(thumbnail);
      await pumpUntilRealIo(
        tester,
        () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
        reason: 'The relocated image should open directly',
      );
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final preview = tester.widget<TaskAttachmentPreview>(
        find.byType(TaskAttachmentPreview),
      );
      expect(p.equals(preview.resolvedPath!, sourceImage!.path), isTrue);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('shared-save-memo'));
      // Even with empty text, an attachment share can be saved once confirmed.
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await pumpUntilRealIo(
        tester,
        () =>
            find.byKey(const ValueKey('shared-text-editor')).evaluate().isEmpty,
        reason: 'Confirmed shared attachment must save and return',
      );
      await drainWorkspaceDrafts(tester, h.container);
      final rows = await tester.runAsync(h.rows);
      expect(rows, hasLength(1));
      final saved = rows!.single;
      expect(saved.id, attachmentShareId);
      expect(saved.taskTitle, 'diagram.png');
      expect(saved.triggerTime, isNull);
      expect(saved.eventTime, isNull);
      expect(saved.capturePending, isFalse);
      expect(saved.recordId, isNotNull);
      expect(saved.details.attachmentIds, [saved.recordId]);
      final mediaRows = h.container.read(mediaRecordsProvider);
      expect(mediaRows, hasLength(1));
      expect(mediaRows.single.id, saved.recordId);
      expect(mediaRows.single.type, 'image');
      expect(
        await tester.runAsync(
          () => File(mediaRows.single.contentOrPath).readAsBytes(),
        ),
        imageBytes,
      );
      expect(await tester.runAsync(() => handoffDir!.exists()), isFalse);
      final drafts = await tester.runAsync(h.drafts);
      expect(jsonDecode(drafts!)['capture']['text'], '保留首页草稿');
      expect(h.notifications.scheduled, isEmpty);
    },
  );
}
