import 'support/interaction_preview.dart';
import 'dart:io';
import 'dart:collection';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Tasks extends RemindersNotifier {
  _Tasks(super.database) : super(runLoadEffects: false);
  void replace(List<Reminder> tasks) => state = tasks;
}

class _CountedTasks extends ListBase<Reminder> {
  _CountedTasks(this.items);
  final List<Reminder> items;
  int reads = 0;
  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  Reminder operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, Reminder value) =>
      throw UnsupportedError('immutable');
}

void main() {
  setUpAll(loadInteractionPreviewFonts);
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Tasks tasks;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('detail-layout-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    tasks = _Tasks(database);
    await tasks.ready;
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        remindersProvider.overrideWith((_) => tasks),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });
  Future<void> open(
    WidgetTester tester, {
    String language = 'zh',
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    final task = Reminder(
      id: 'root',
      taskTitle: '整段标题 alpha',
      taskSummary: '第一行\n第二行 beta',
      quadrantLevel: 2,
      linkedTaskIds: ['linked'],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          theme: ThemeData(
            brightness: brightness,
            platform: TargetPlatform.macOS,
            fontFamily: const bool.fromEnvironment('UI_PREVIEW')
                ? 'Roboto'
                : null,
          ),
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: interactionPreviewKey, child: child!),
          ),
          home: TaskDetailScreen(task: task),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await captureInteractionPreview(
      tester,
      'detail-${tester.view.physicalSize.width.toInt()}-$language-${brightness.name}',
    );
  }

  testWidgets('desktop context menu selects all lines before replacement', (
    tester,
  ) async {
    await open(tester);
    for (final key in ['detail-title', 'detail-summary']) {
      final finder = find.byKey(ValueKey(key));
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      final field = tester.widget<TextField>(finder);
      field.controller!.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      final editable = tester.state<EditableTextState>(
        find.descendant(of: finder, matching: find.byType(EditableText)),
      );
      editable.showToolbar();
      await tester.pumpAndSettle();
      final selectAll = find.text('全选');
      expect(selectAll, findsOneWidget);
      await tester.tap(selectAll);
      await tester.pump();
      expect(field.controller!.selection.start, 0);
      expect(field.controller!.selection.end, field.controller!.text.length);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Replaced entirely',
          selection: TextSelection.collapsed(offset: 17),
        ),
      );
      await tester.pump();
      expect(field.controller!.text, 'Replaced entirely');
    }
  });

  testWidgets('local edits do not rescan ten thousand linked-task candidates', (
    tester,
  ) async {
    final source = _CountedTasks(
      List.generate(
        10000,
        (i) => Reminder(
          id: i == 9999 ? 'linked' : 'task-$i',
          taskTitle: 'Linked task $i',
          quadrantLevel: 2,
        ),
      ),
    );
    tasks.replace(source);
    await open(tester);
    final reads = source.reads;
    expect(reads, greaterThanOrEqualTo(10000));
    await tester.tap(find.byIcon(Icons.radio_button_unchecked_rounded));
    await tester.pump();
    expect(source.reads, reads);
    expect(find.text('Linked task 9999'), findsOneWidget);
  });

  testWidgets('linked task lookup refreshes on list replacement', (
    tester,
  ) async {
    tasks.replace([
      Reminder(id: 'linked', taskTitle: 'Before', quadrantLevel: 2),
    ]);
    await open(tester);
    expect(find.text('Before'), findsOneWidget);
    tasks.replace([
      Reminder(id: 'linked', taskTitle: 'After', quadrantLevel: 2),
    ]);
    await tester.pump();
    expect(find.text('After'), findsOneWidget);
    expect(find.text('Before'), findsNothing);
  });

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final language in ['zh', 'en', 'ja']) {
      testWidgets(
        'detail $width $language keeps save visible and scrolls at double scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 750);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await open(
            tester,
            language: language,
            scale: 2,
            brightness: width == 768 ? Brightness.dark : Brightness.light,
          );
          final save = find.widgetWithIcon(FilledButton, Icons.save_outlined);
          expect(save.hitTestable(), findsOneWidget);
          expect(
            tester.getSize(find.byKey(const ValueKey('detail-title'))).width,
            lessThanOrEqualTo(1008),
          );
          for (var i = 0; i < 8; i++) {
            await tester.drag(
              find.byType(SingleChildScrollView).first,
              const Offset(0, -500),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(save.hitTestable(), findsOneWidget);
          }
        },
      );
    }
  }
}
