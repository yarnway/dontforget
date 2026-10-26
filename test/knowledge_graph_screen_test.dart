import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/bidirectional_link_service.dart';
import 'package:dont_forget/ui/screens/knowledge_graph_screen.dart';
import 'package:dont_forget/ui/widgets/knowledge_graph_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/interaction_preview.dart';

class _Tasks extends RemindersNotifier {
  _Tasks(super.database) : super(runLoadEffects: false);
  void replace(List<Reminder> tasks) => state = tasks;
}

void main() {
  setUpAll(loadInteractionPreviewFonts);
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Tasks tasks;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('graph-layout-');
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
  List<Reminder> fixture(int count) => List.generate(
    count,
    (i) => Reminder(
      id: 'task-$i',
      taskTitle: 'Task $i 项目验收',
      taskSummary: 'Summary $i\n第二行',
      quadrantLevel: i % 4 + 1,
      linkedTaskIds: i > 0 ? ['task-${i - 1}'] : [],
    ),
  );
  Future<void> open(
    WidgetTester tester, {
    String? focus,
    String language = 'zh',
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
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
          home: KnowledgeGraphScreen(initialFocusTaskId: focus),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  KnowledgeGraphView graph(WidgetTester tester) =>
      tester.widget<KnowledgeGraphView>(find.byType(KnowledgeGraphView));

  testWidgets('ten thousand tasks are bounded in graph and lazy in full list', (
    tester,
  ) async {
    tasks.replace(fixture(10000));
    await open(tester);
    expect(graph(tester).graphData.nodes, hasLength(120));
    expect(find.text('1 / 84'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    final initial = graph(tester).graphData;
    initial.nodes.first.x += 11;
    graph(tester).onNodeSelected(initial.nodes.first);
    await tester.pumpAndSettle();
    expect(graph(tester).graphData, same(initial));
    expect(initial.nodes.first.x, -539);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(graph(tester).graphData.nodes.first.id, 'task-120');
    await tester.tap(find.text('任务列表'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile).evaluate().length, lessThan(20));
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      (list.childrenDelegate as SliverChildBuilderDelegate).childCount,
      10000,
    );
    await tester.enterText(find.byType(TextField), '9999 summary');
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pumpAndSettle();
    expect(find.text('Task 9999 项目验收'), findsOneWidget);
    expect(find.text('Task 0 项目验收'), findsNothing);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.text('Task 0 项目验收'), findsOneWidget);
  });

  testWidgets('focus finds final page and source replacement refreshes nodes', (
    tester,
  ) async {
    tasks.replace(fixture(10000));
    await open(tester, focus: 'task-9999');
    expect(find.text('84 / 84'), findsOneWidget);
    expect(graph(tester).selectedNodeId, 'task-9999');
    expect(graph(tester).graphData.nodes, hasLength(40));
    tasks.replace(fixture(1));
    await tester.pumpAndSettle();
    expect(graph(tester).graphData.nodes.single.id, 'task-0');
    expect(graph(tester).selectedNodeId, isNull);
    await tester.enterText(find.byType(TextField), 'no-match');
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pumpAndSettle();
    expect(find.text('重置筛选'), findsOneWidget);
    await tester.tap(find.text('重置筛选'));
    await tester.pumpAndSettle();
    expect(graph(tester).graphData.nodes, hasLength(1));
    tasks.replace([]);
    await tester.pumpAndSettle();
    expect(find.byType(KnowledgeGraphView), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('centered node hit, node drag, background pan and idle settle', (
    tester,
  ) async {
    final node = GraphNode(id: 'one', title: '🧑🏽‍💻完整标题', quadrantLevel: 1);
    GraphNode? selected;
    final transform = TransformationController();
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: InteractiveViewer(
              transformationController: transform,
              boundaryMargin: const EdgeInsets.all(400),
              child: KnowledgeGraphView(
                graphData: KnowledgeGraphData(nodes: [node], edges: []),
                onNodeSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(KnowledgeGraphView));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(selected, same(node));
    await tester.dragFrom(center, const Offset(55, 35));
    await tester.pumpAndSettle();
    expect(node.x, greaterThan(0));
    expect(transform.value.getTranslation().x, 0);
    await tester.dragFrom(
      center - const Offset(150, 150),
      const Offset(40, 30),
    );
    await tester.pumpAndSettle();
    expect(transform.value.getTranslation().x, greaterThan(0));
    final pointer = TestPointer(42, PointerDeviceKind.trackpad);
    final before = transform.value.getTranslation().x;
    final nodeBefore = node.x;
    await tester.sendEventToBinding(pointer.panZoomStart(center));
    await tester.pump();
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(center, pan: const Offset(80, 0)),
    );
    await tester.pump();
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
    expect(transform.value.getTranslation().x, greaterThan(before));
    expect(node.x, nodeBefore);
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final language in ['zh', 'en', 'ja']) {
      testWidgets(
        'graph $width $language large text and keyboard do not overflow',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 750);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          tasks.replace(fixture(10000));
          await open(tester, language: language, scale: 2, focus: 'task-0');
          expect(tester.takeException(), isNull);
          await captureInteractionPreview(
            tester,
            'graph-${width.toInt()}-$language',
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 320);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byType(InteractiveViewer)).height,
            greaterThan(0),
          );
        },
      );
    }
  }
}
