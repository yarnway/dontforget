import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'support/interaction_preview.dart';

void main() {
  setUpAll(loadInteractionPreviewFonts);
  Future<InlineFeedbackState> showFeedbackHost(
    WidgetTester tester, {
    bool accessibleNavigation = false,
  }) async {
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(accessibleNavigation: accessibleNavigation),
          child: InlineFeedback(child: child!),
        ),
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold(body: TextField());
          },
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    return InlineFeedback.of(page);
  }

  testWidgets(
    'success clears promptly without moving input or taking focus and honors longer durations',
    (tester) async {
      final feedback = await showFeedbackHost(tester);
      final input = tester.getRect(find.byType(TextField));
      final focus = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;
      feedback.showSnackBar(
        const SnackBar(content: Text('Saved')),
        tone: FeedbackTone.success,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Saved'), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      expect(tester.getRect(find.byType(TextField)), input);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
      expect(focus.hasFocus, isTrue);
      feedback.showSnackBar(
        const SnackBar(
          content: Text('Long confirmation'),
          duration: Duration(seconds: 12),
        ),
        tone: FeedbackTone.success,
      );
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('Long confirmation'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a timed action expires in accessible navigation and cannot dismiss a replacement',
    (tester) async {
      final feedback = await showFeedbackHost(
        tester,
        accessibleNavigation: true,
      );
      final completion = SnackBar(
        content: const Text('Completed'),
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      );
      const timeout = Duration(seconds: 5);
      feedback.showSnackBar(completion, dismissAfter: timeout);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Completed'), findsNothing);

      feedback.showSnackBar(completion, dismissAfter: timeout);
      await tester.pump(const Duration(seconds: 2));
      feedback.showSnackBar(const SnackBar(content: Text('Replacement')));
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Replacement'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'warnings and failures retain reading time and replacement cancels the old expiry',
    (tester) async {
      final feedback = await showFeedbackHost(tester);
      for (final tone in [
        FeedbackTone.info,
        FeedbackTone.warning,
        FeedbackTone.error,
      ]) {
        feedback.showSnackBar(
          const SnackBar(content: Text('Check before retrying')),
          tone: tone,
        );
        await tester.pump(const Duration(seconds: 7));
        expect(find.text('Check before retrying'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
      }
      feedback.showSnackBar(
        const SnackBar(content: Text('First')),
        tone: FeedbackTone.success,
      );
      await tester.pump(const Duration(seconds: 3));
      feedback.showSnackBar(
        const SnackBar(content: Text('Replacement')),
        tone: FeedbackTone.success,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Replacement'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'accessible navigation keeps success and actionable feedback until dismissed',
    (tester) async {
      final feedback = await showFeedbackHost(
        tester,
        accessibleNavigation: true,
      );
      feedback.showSnackBar(
        const SnackBar(content: Text('Saved')),
        tone: FeedbackTone.success,
      );
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Saved'), findsOneWidget);
      var undone = false;
      feedback.showSnackBar(
        SnackBar(
          content: const Text('Moved to trash'),
          action: SnackBarAction(label: 'Undo', onPressed: () => undone = true),
        ),
        tone: FeedbackTone.success,
      );
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Undo').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(undone, isTrue);
      expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final language in ['zh', 'en', 'ja']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'repair notice stays compact and actionable $language $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(375, 667);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final loc = AppLocalizations(Locale(language));
          late BuildContext page;
          var repaired = false;
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: InlineFeedback(child: child!),
              ),
              home: Builder(
                builder: (context) {
                  page = context;
                  return const Scaffold(body: TextField());
                },
              ),
            ),
          );
          final input = tester.getRect(find.byType(TextField));
          InlineFeedback.of(page).showSnackBar(
            SnackBar(
              content: Text(loc.get('reminderNativeSyncFailedCompact')),
              action: SnackBarAction(
                label: loc.get('repairNotifications'),
                onPressed: () => repaired = true,
              ),
            ),
            tone: FeedbackTone.warning,
          );
          await tester.pump();
          final card = tester.getRect(
            find.byKey(const ValueKey('inline-feedback')),
          );
          final action = find.widgetWithText(
            TextButton,
            loc.get('repairNotifications'),
          );
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
          expect(
            find.byIcon(Icons.close_rounded).hitTestable(),
            findsOneWidget,
          );
          expect(tester.getRect(find.byType(TextField)), input);
          if (language == 'zh' && scale == 1) {
            expect(card.height, lessThanOrEqualTo(64));
          }
          expect(tester.takeException(), isNull);
          await tester.tap(action);
          await tester.pump();
          expect(repaired, isTrue);
          expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'long actionable feedback keeps Undo and close visible at large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final height in [480.0, 900.0]) {
        tester.view.physicalSize = Size(320, height);
        late BuildContext page;
        var undone = false;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: InlineFeedback(child: child!),
            ),
            home: Builder(
              builder: (context) {
                page = context;
                return const Scaffold(body: TextField());
              },
            ),
          ),
        );
        await tester.tap(find.byType(TextField));
        InlineFeedback.of(page).showSnackBar(
          SnackBar(
            content: Text('长标题与完整结果说明。' * 40),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => undone = true,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Undo').hitTestable(), findsOneWidget);
        expect(find.byIcon(Icons.close_rounded).hitTestable(), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.f6);
        await tester.pump();
        expect(find.text('Undo').hitTestable(), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(undone, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('Undo remains accessible above the Navigator route', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => InlineFeedback(child: child!),
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const Scaffold(body: Text('Task board'));
          },
        ),
      ),
    );
    InlineFeedback.of(pageContext).showSnackBar(
      SnackBar(
        content: const Text('Deleted test item'),
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Undo'), findsOneWidget);
    expect(find.bySemanticsLabel('Deleted test item'), findsOneWidget);
    expect(find.bySemanticsLabel('Task board'), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'feedback replaces in place, keeps input focus and retains Undo',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      late BuildContext pageContext;
      var undone = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => InlineFeedback(child: child!),
          home: Builder(
            builder: (context) {
              pageContext = context;
              return Scaffold(body: TextField(focusNode: focus));
            },
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      final inputRect = tester.getRect(find.byType(TextField));
      final barriersBefore = find.byType(ModalBarrier).evaluate().length;
      final feedback = InlineFeedback.of(pageContext);
      feedback.showSnackBar(const SnackBar(content: Text('First result')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(ModalBarrier).evaluate().length, barriersBefore);
      expect(tester.getRect(find.byType(TextField)), inputRect);
      expect(
        tester.getSize(find.byKey(const ValueKey('inline-feedback'))).width,
        lessThanOrEqualTo(440),
      );
      feedback.showSnackBar(
        SnackBar(
          content: const Text('Deleted test item'),
          action: SnackBarAction(label: 'Undo', onPressed: () => undone++),
        ),
      );
      await tester.pump(const Duration(seconds: 20));
      expect(find.text('First result'), findsNothing);
      expect(find.text('Undo'), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(undone, 1);
      expect(focus.hasFocus, isTrue);
      expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('top feedback wraps long text at 375/768/1440 with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [375.0, 768.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 800);
      late BuildContext pageContext;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: InlineFeedback(child: child!),
          ),
          home: Builder(
            builder: (context) {
              pageContext = context;
              return const Scaffold(body: TextField());
            },
          ),
        ),
      );
      InlineFeedback.of(pageContext).showSnackBar(
        const SnackBar(content: Text('无法保存这次操作，请检查本地存储后重试。原有数据仍然保留，可继续编辑。')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(find.byKey(const ValueKey('inline-feedback')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets(
    'feedback fits themes, keyboard and safe area without moving input',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final width in [375.0, 1440.0]) {
        for (final dark in [false, true]) {
          tester.view.physicalSize = Size(width, 700);
          late BuildContext pageContext;
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? AppTheme.dark : AppTheme.light,
              builder: (context, child) => RepaintBoundary(
                key: interactionPreviewKey,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    padding: const EdgeInsets.only(top: 24),
                    viewInsets: const EdgeInsets.only(bottom: 260),
                  ),
                  child: InlineFeedback(child: child!),
                ),
              ),
              home: Builder(
                builder: (context) {
                  pageContext = context;
                  return Scaffold(
                    appBar: AppBar(title: const Text('别忘了')),
                    body: const Center(child: Text('工作台')),
                    bottomNavigationBar: const Padding(
                      padding: EdgeInsets.all(12),
                      child: TextField(
                        decoration: InputDecoration(hintText: '记录下一件事…'),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          final before = tester.getRect(find.byType(TextField));
          InlineFeedback.of(pageContext).showSnackBar(
            const SnackBar(content: Text('修改已保存')),
            tone: FeedbackTone.success,
          );
          await tester.pumpAndSettle();
          final toast = tester.getRect(
            find.byKey(const ValueKey('inline-feedback')),
          );
          expect(toast.width, lessThanOrEqualTo(440));
          expect(toast.top, greaterThanOrEqualTo(24 + kToolbarHeight));
          expect(toast.overlaps(before), isFalse);
          expect(tester.getRect(find.byType(TextField)), before);
          await tester.tap(find.byType(TextField));
          await tester.enterText(find.byType(TextField), '继续输入');
          expect(find.text('继续输入'), findsOneWidget);
          await tester.pump();
          await captureInteractionPreview(
            tester,
            'feedback-${dark ? 'dark' : 'light'}-${width.toInt()}',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      }
    },
  );
}
