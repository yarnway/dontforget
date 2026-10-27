import 'dart:io';
import 'dart:ui' as ui;
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/task_search_provider.dart';
import 'package:dont_forget/services/task_search_index.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:dont_forget/ui/widgets/task_search_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Index extends TaskSearchNotifier {
  _Index(this.tasks);
  List<Reminder> tasks;
  @override
  TaskSearchIndex build() => TaskSearchIndex(tasks);
  void replace(List<Reminder> tasks) =>
      state = TaskSearchIndex(tasks, previous: state);
}

void main() {
  final now = DateTime.now();
  final fixtures = [
    Reminder(
      id: 'planning',
      taskTitle: 'Plan the next release',
      quadrantLevel: 2,
      taskSummary: 'Review the checklist with the team',
      subTasks: '["Update release notes"]',
      triggerTime: now.add(const Duration(days: 1)),
      createdAt: now,
    ),
    Reminder(
      id: 'overdue',
      taskTitle: 'Send the weekly update',
      quadrantLevel: 1,
      triggerTime: now.subtract(const Duration(days: 1)),
      createdAt: now.subtract(const Duration(days: 1)),
    ),
    Reminder(
      id: 'done',
      taskTitle: 'Archive the previous release',
      quadrantLevel: 3,
      isCompleted: true,
    ),
  ];
  late _Index index;
  String query = '';
  late StateSetter rebuild;

  setUpAll(() async {
    if (const bool.fromEnvironment('UI_PREVIEW')) {
      final font = File(const String.fromEnvironment('PREVIEW_FONT'));
      final icons = File(const String.fromEnvironment('PREVIEW_ICONS'));
      for (final family in ['Ahem', 'Roboto']) {
        await (FontLoader(
          family,
        )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  Future<void> show(
    WidgetTester tester, {
    double width = 768,
    double height = 800,
    double scale = 1,
    Brightness brightness = Brightness.light,
    String language = 'en',
    List<Reminder>? tasks,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    index = _Index(tasks ?? fixtures);
    query = '';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [taskSearchIndexProvider.overrideWith(() => index)],
        child: RepaintBoundary(
          key: const ValueKey('search-preview'),
          child: MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF7A8B8B),
                brightness: brightness,
              ),
            ),
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
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('DontForget')),
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return TaskSearchPanel(
                    query: query,
                    onClearQuery: () => rebuild(() => query = ''),
                    onPlayMedia: (_) {},
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> visible(WidgetTester tester) => tester
      .widgetList<TaskCard>(find.byType(TaskCard))
      .map((c) => c.task.id)
      .toList();

  testWidgets('browse, combine text and status, sort, reset and refresh data', (
    tester,
  ) async {
    await show(tester);
    expect(visible(tester), ['planning', 'overdue', 'done']);
    await tester.tap(find.byKey(const ValueKey('search-filter-pending')));
    await tester.pumpAndSettle();
    expect(visible(tester), ['planning', 'overdue']);
    rebuild(() => query = 'release checklist');
    await tester.pumpAndSettle();
    expect(visible(tester), ['planning']);
    index.replace([
      fixtures.first.copyWith(isCompleted: true),
      fixtures[1],
      fixtures[2],
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(TaskCard), findsNothing);
    expect(
      find.text('Try fewer keywords or reset the filters.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('search-reset')));
    await tester.pumpAndSettle();
    expect(query, '');
    expect(visible(tester), ['planning', 'overdue', 'done']);
    await tester.tap(find.byKey(const ValueKey('search-sort')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(
        CheckedPopupMenuItem<TaskSearchSort>,
        'Reminder time',
      ),
    );
    await tester.pumpAndSettle();
    expect(visible(tester), ['overdue', 'planning', 'done']);
    index.replace([fixtures[2]]);
    await tester.pumpAndSettle();
    expect(visible(tester), ['done']);
    index.replace([]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-reset')));
    await tester.pumpAndSettle();
    expect(find.text('Your task list is empty'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ten thousand results are rendered lazily', (tester) async {
    await show(
      tester,
      tasks: List.generate(
        10000,
        (i) => Reminder(id: '$i', taskTitle: 'Task $i', quadrantLevel: 3),
      ),
    );
    expect(find.text('Search Results · 10000'), findsOneWidget);
    expect(find.byType(TaskCard).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('search layout $width ${brightness.name}', (tester) async {
        await show(tester, width: width, brightness: brightness);
        expect(tester.takeException(), isNull);
        if (width == 1440) {
          expect(tester.getSize(find.byType(CustomScrollView)).width, 960);
        }
        if (const bool.fromEnvironment('UI_PREVIEW')) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('search-preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('dist/search-preview').create(recursive: true);
            await File(
              'dist/search-preview/search-${width.toInt()}-${brightness.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  for (final language in ['en', 'zh', 'ja']) {
    testWidgets('large text in a short keyboard viewport $language', (
      tester,
    ) async {
      await show(tester, width: 375, height: 350, scale: 2, language: language);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
