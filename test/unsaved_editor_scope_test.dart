import 'dart:async';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/ui/widgets/unsaved_editor_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'back keeps a dirty draft; discard is explicit; failed save can retry once',
    (tester) async {
      final controller = TextEditingController(text: 'initial');
      final saves = <Completer<bool>>[];
      Object? result;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.push<Object?>(
                    context,
                    MaterialPageRoute<Object?>(
                      builder: (_) => StatefulBuilder(
                        builder: (context, update) => UnsavedEditorScope(
                          dirty: controller.text != 'initial',
                          busy: false,
                          savedResult: true,
                          onSave: () {
                            final save = Completer<bool>();
                            saves.add(save);
                            return save.future;
                          },
                          builder: (context, save, exit) => Scaffold(
                            appBar: AppBar(
                              leading: BackButton(onPressed: exit),
                            ),
                            body: Column(
                              children: [
                                TextField(
                                  controller: controller,
                                  onChanged: (_) => update(() {}),
                                ),
                                FilledButton(
                                  onPressed: save,
                                  child: const Text('write'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'uncommitted');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('有未保存的修改'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(controller.text, 'uncommitted');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并返回'));
      await tester.pumpAndSettle();
      expect(saves.length, 1);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      saves.single.complete(false);
      await tester.pumpAndSettle();
      expect(controller.text, 'uncommitted');
      await tester.tap(find.text('write'));
      await tester.pump();
      expect(saves.length, 2);
      saves.last.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(result, true);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(result, null);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
