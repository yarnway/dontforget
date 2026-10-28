import 'support/interaction_preview.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/ui/widgets/command_palette_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(loadInteractionPreviewFonts);
  late List<int> executed;
  late List<CommandPaletteAction> actions;
  setUp(() {
    executed = [];
    actions = List.generate(
      30,
      (i) => CommandPaletteAction(
        id: '/tool$i',
        title: 'Tool $i',
        subtitle: '工具说明 $i',
        icon: Icons.build_outlined,
        onExecute: () => executed.add(i),
      ),
    );
  });
  Future<void> open(
    WidgetTester tester, {
    String language = 'zh',
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: interactionPreviewKey, child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => CommandPaletteDialog.show(context, actions),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await captureInteractionPreview(
      tester,
      'tools-${tester.view.physicalSize.width.toInt()}-${tester.view.physicalSize.height.toInt()}-$language-${brightness.name}',
    );
  }

  testWidgets('arrow selection scrolls into view and executes exactly once', (
    tester,
  ) async {
    await open(tester);
    for (var i = 0; i < 29; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(find.text('Tool 29').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(executed, [29]);
    expect(find.byType(CommandPaletteDialog), findsNothing);
  });

  testWidgets(
    'stationary pointer does not steal keyboard selection on scroll',
    (tester) async {
      await open(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Tool 0')));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        // Scrolling moves new rows beneath the unmoved pointer.
        await tester.pumpAndSettle();
      }
      expect(find.text('Tool 20').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(executed, [20]);
    },
  );

  testWidgets('moving the pointer still selects a command for Enter', (
    tester,
  ) async {
    await open(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Tool 2')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(executed, [2]);
  });

  testWidgets(
    'filter resets selection and scroll while retaining input focus',
    (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(find.text('Tool 29').hitTestable(), findsOneWidget);
      await tester.enterText(find.byType(TextField), ' TOOL1 ');
      await tester.pump();
      expect(find.text('Tool 1').hitTestable(), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(executed, [1]);
    },
  );

  testWidgets('IME confirmation does not execute a tool or close the dialog', (
    tester,
  ) async {
    await open(tester);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '工具',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(executed, isEmpty);
    expect(find.byType(CommandPaletteDialog), findsOneWidget);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '工具',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(executed, [0]);
  });

  testWidgets('empty results remain editable and Escape dismisses', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'no-such-tool');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(executed, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(CommandPaletteDialog), findsNothing);
  });

  for (final size in [
    const Size(375, 667),
    const Size(768, 700),
    const Size(1440, 900),
    const Size(375, 280),
  ]) {
    for (final language in ['zh', 'en', 'ja']) {
      testWidgets('tools fit $size $language at double text scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await open(
          tester,
          language: language,
          scale: 2,
          brightness: size.width == 768 ? Brightness.dark : Brightness.light,
        );
        final loc = AppLocalizations.of(
          tester.element(find.byType(CommandPaletteDialog)),
        );
        expect(find.text(loc.get('commandSearchLabel')), findsNothing);
        final input = tester.getRect(find.byType(TextField));
        final hint = tester.getRect(find.text(loc.get('commandSearchHint')));
        expect((hint.center - input.center).distance, lessThan(.5));
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(find.text('Tool 29').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
