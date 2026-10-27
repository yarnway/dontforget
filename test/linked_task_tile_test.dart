import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/widgets/linked_task_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final language in ['en', 'zh', 'ja']) {
    for (final available in [true, false]) {
      testWidgets('$language narrow linked task, available=$available', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final l10n = AppLocalizations(Locale(language));
        const title = 'Synthetic linked task 合成关联事项 日本語の関連タスク';
        var opened = 0;
        var removed = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(14),
                child: LinkedTaskTile(
                  task: available
                      ? Reminder(
                          id: 'private-storage-id',
                          taskTitle: title,
                          quadrantLevel: 2,
                        )
                      : null,
                  categoryColor: Colors.amber,
                  onOpen: () => opened++,
                  onUnlink: () => removed++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('private-storage-id'), findsNothing);
        final button = find.byType(TextButton);
        final unlink = find.byType(IconButton);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(unlink).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(unlink).height, greaterThanOrEqualTo(48));
        expect(
          tester.widget<TextButton>(button).onPressed,
          available ? isNotNull : isNull,
        );
        expect(find.text('Q2'), available ? findsOneWidget : findsNothing);
        if (!available) {
          expect(find.text(l10n.get('linkedTaskUnavailable')), findsOneWidget);
          expect(find.text('Q4'), findsNothing);
        }
        await tester.tap(button);
        expect(opened, available ? 1 : 0);
        await tester.tap(unlink);
        expect(removed, 1);
        expect(opened, available ? 1 : 0);

        // Both controls participate in native keyboard traversal; a deleted
        // target is skipped and cannot route to a stale detail page.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(opened, available ? 2 : 0);
        expect(removed, available ? 1 : 2);
      });
    }
  }
}
