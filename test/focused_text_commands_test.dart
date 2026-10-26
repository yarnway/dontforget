import 'dart:async';
import 'package:dont_forget/ui/widgets/focused_text_commands.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TextEditingController controller;
  late FocusNode focus;
  var current = true;
  var changes = <String>[];
  String? clipboard;
  Future<bool> run(String action) =>
      FocusedTextCommands.run(action, isCurrent: () => current);

  setUp(() {
    controller = TextEditingController(text: '中文 日本語 draft');
    focus = FocusNode();
    current = true;
    changes = [];
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard != null};
          }
          return null;
        });
  });
  tearDown(() {
    controller.dispose();
    focus.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  Future<void> show(
    WidgetTester tester, {
    bool secret = false,
    bool readOnly = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: controller,
            focusNode: focus,
            autofocus: true,
            obscureText: secret,
            readOnly: readOnly,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'native select-all and paste replace the real value and notify the draft',
    (tester) async {
      await show(tester);
      expect(await run('selectAll'), true);
      expect(
        controller.selection,
        TextSelection(baseOffset: 0, extentOffset: controller.text.length),
      );
      await Clipboard.setData(const ClipboardData(text: 'replacement 整段'));
      expect(await run('paste'), true);
      expect(controller.text, 'replacement 整段');
      expect(changes, ['replacement 整段']);
      expect(controller.selection.isCollapsed, true);
      expect(await run('selectAll'), true);
      expect(await run('cut'), true);
      expect(controller.text, isEmpty);
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        'replacement 整段',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final change in ['focus', 'value', 'route', 'generation', 'dispose']) {
    testWidgets('late clipboard response is rejected after $change changes', (
      tester,
    ) async {
      await show(tester);
      await run('selectAll');
      final pending = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') return pending.future;
            return null;
          });
      final paste = run('paste');
      await tester.pump();
      switch (change) {
        case 'focus':
          focus.unfocus();
          await tester.pump();
        case 'value':
          controller.text = 'new value';
        case 'route':
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(TextField)),
              builder: (_) => const AlertDialog(title: Text('modal')),
            ),
          );
          await tester.pumpAndSettle();
        case 'generation':
          current = false;
        case 'dispose':
          await tester.pumpWidget(const SizedBox());
      }
      pending.complete({'text': 'late clipboard'});
      expect(await paste, false);
      expect(controller.text, change == 'value' ? 'new value' : '中文 日本語 draft');
      expect(changes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('composition and hidden modal background cannot be edited', (
    tester,
  ) async {
    await show(tester);
    controller.value = const TextEditingValue(
      text: 'zhong',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 0, end: 5),
    );
    expect(await run('selectAll'), false);
    expect(controller.text, 'zhong');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('secrets cannot be copied or cut; readonly cannot be pasted', (
    tester,
  ) async {
    await show(tester, secret: true);
    await run('selectAll');
    expect(await run('copy'), false);
    expect(await run('cut'), false);
    await show(tester, readOnly: true);
    expect(await run('selectAll'), true);
    expect(await run('paste'), false);
    expect(await run('cut'), false);
    expect(await run('copy'), true);
    expect(controller.text, '中文 日本語 draft');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clipboard failure leaves a cut draft intact', (tester) async {
    await show(tester);
    await run('selectAll');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'unavailable');
          }
          return null;
        });
    expect(await run('cut'), false);
    expect(controller.text, '中文 日本語 draft');
    await tester.pumpWidget(const SizedBox());
  });
}
