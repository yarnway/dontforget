import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';

void main() {
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
      final barriersBefore = find.byType(ModalBarrier).evaluate().length;
      final feedback = InlineFeedback.of(pageContext);
      feedback.showSnackBar(const SnackBar(content: Text('First result')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(ModalBarrier).evaluate().length, barriersBefore);
      expect(
        tester.getTopLeft(find.text('First result')).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
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
}
