import 'dart:async';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/input_bottom_bar.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ControlledHomeController extends HomeController {
  _ControlledHomeController(super.ref);
  Completer<bool>? pendingStart;
  int stops = 0;

  void setRecording(bool value) => state = state.copyWith(isRecording: value);

  @override
  Future<bool> startRecording() async {
    final started = await (pendingStart?.future ?? Future.value(true));
    setRecording(started);
    return started;
  }

  @override
  Future<void> stopRecordingAndProcess() async {
    stops++;
    setRecording(false);
  }
}

class _Notifications implements NotificationService {
  final scheduled = <Reminder>[];
  final canceled = <String>[];
  @override
  Future<void> scheduleReminder(Reminder task) async => scheduled.add(task);
  @override
  Future<void> cancelReminder(String id) async => canceled.add(id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _ControlledHomeController home;
  late _Notifications notifications;
  const recorderChannel = MethodChannel('com.llfbandit.record/messages');

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, (_) async => null);
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp(
      'dontforget-workspace-ux-',
    );
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = _Notifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        homeControllerProvider.overrideWith(
          (ref) => home = _ControlledHomeController(ref),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    container.read(homeControllerProvider);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null);
  });

  Future<void> show(
    WidgetTester tester,
    Widget child, {
    bool reducedMotion = false,
    double textScale = 1,
    String language = 'zh',
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: brightness,
            ),
          ),
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, content) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reducedMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: InlineFeedback(child: content!),
          ),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  Widget card(String id) => Consumer(
    builder: (context, ref, _) {
      final task = ref
          .watch(remindersProvider)
          .where((r) => r.id == id)
          .firstOrNull;
      return task == null
          ? const SizedBox()
          : TaskCard(task: task, onPlayMedia: () {});
    },
  );

  testWidgets(
    'input has no idle ticks and reduced motion stops recording animation',
    (tester) async {
      await show(tester, const InputBottomBar());
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      home.setRecording(true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await show(tester, const InputBottomBar(), reducedMotion: true);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byIcon(Icons.stop_circle_rounded), findsOneWidget);
      home.setRecording(false);
      await show(tester, const InputBottomBar());
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('send reflects draft content and recording state', (
    tester,
  ) async {
    await show(tester, const InputBottomBar());
    final send = find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded);
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    home.setRecording(true);
    await tester.pump();
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    home.setRecording(false);
    await tester.pump();
    expect(find.text('Keep this draft'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'release during native recorder startup still stops that recording',
    (tester) async {
      home.pendingStart = Completer<bool>();
      await show(tester, const InputBottomBar(), reducedMotion: true);
      final gestures = tester.widget<GestureDetector>(
        find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector && widget.onLongPressStart != null,
        ),
      );
      gestures.onLongPressStart!(const LongPressStartDetails());
      await tester.pump();
      gestures.onLongPressEnd!(const LongPressEndDetails());
      home.pendingStart!.complete(true);
      await tester.pumpAndSettle();
      expect(home.stops, 1);
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(find.byType(TextField), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'card metadata and actions fit narrow layouts with large text in all languages',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final task = Reminder(
        id: 'large-card',
        quadrantLevel: 1,
        taskTitle: 'A long task title with important details 准备完整的项目架构评审材料',
        taskSummary: 'A readable summary that can wrap across multiple lines.',
        isEmotionFiltered: true,
        isDynamicallyPromoted: true,
        isRecurring: true,
        recurrenceDescription: 'Every weekday at the agreed local time',
        triggerTime: DateTime.now().add(const Duration(days: 1)),
        spacedRepetitionLevel: 3,
        contextTrigger: '{}',
        linkedTaskIds: ['a'],
        subTasks:
            '["Prepare architecture diagrams", "Review performance evidence"]',
      );
      for (final language in ['zh', 'en', 'ja']) {
        for (final width in [375.0, 768.0, 1440.0]) {
          tester.view.physicalSize = Size(width, 1400);
          await show(
            tester,
            TaskCard(task: task, onPlayMedia: () {}),
            textScale: 2,
            language: language,
            reducedMotion: true,
          );
          expect(tester.takeException(), isNull, reason: '$language at $width');
          expect(
            tester.getSize(find.byKey(const ValueKey('complete-large-card'))),
            const Size(48, 48),
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('actions-large-card')))
                .height,
            greaterThanOrEqualTo(48),
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('subtasks and task menu can be operated with the keyboard', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await show(
      tester,
      TaskCard(
        task: Reminder(
          id: 'keyboard',
          taskTitle: 'Keyboard task',
          quadrantLevel: 1,
          subTasks: '["Subtask contents"]',
        ),
        onPlayMedia: () {},
      ),
    );
    final button = find.byKey(const ValueKey('subtasks-keyboard'));
    Focus.of(
      tester.element(
        find.descendant(of: button, matching: find.byType(Text)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('Subtask contents'), findsNothing);
    expect(find.bySemanticsLabel('标为已完成: Keyboard task'), findsOneWidget);
    final menu = find.byKey(const ValueKey('actions-keyboard'));
    Focus.of(
      tester.element(
        find.descendant(of: menu, matching: find.byType(Icon)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('删除事项'), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'completion write failure keeps the task open and does not cancel notifications',
    (tester) async {
      final task = Reminder(
        id: 'failed-update',
        taskTitle: 'Keep task open',
        quadrantLevel: 1,
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).addReminder(task),
      );
      final db = await tester.runAsync(() => database.database);
      await tester.runAsync(
        () => db!.execute(
          "CREATE TRIGGER reject_update BEFORE UPDATE ON Reminders BEGIN SELECT RAISE(ABORT, 'test failure'); END",
        ),
      );
      await show(tester, card(task.id));
      await tester.runAsync(
        () => tester.tap(find.byKey(ValueKey('complete-${task.id}'))),
      );
      for (
        var i = 0;
        i < 50 && find.text('提醒更新失败，请重试。').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(container.read(remindersProvider).single.isCompleted, isFalse);
      expect(notifications.canceled, isEmpty);
      expect(find.text('提醒更新失败，请重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed swipe deletion retains the card and reports failure', (
    tester,
  ) async {
    final task = Reminder(
      id: 'failed-delete',
      taskTitle: 'Keep task visible',
      quadrantLevel: 1,
    );
    await tester.runAsync(
      () => container.read(remindersProvider.notifier).addReminder(task),
    );
    final db = await tester.runAsync(() => database.database);
    await tester.runAsync(
      () => db!.execute(
        "CREATE TRIGGER reject_delete BEFORE DELETE ON Reminders BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      ),
    );
    await show(tester, card(task.id));
    await tester.drag(find.byType(TaskCard), const Offset(-700, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (var i = 0; i < 50 && find.text('删除失败，请重试。').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(remindersProvider).single.id, task.id);
    expect(find.text(task.taskTitle), findsOneWidget);
    expect(find.text('删除失败，请重试。'), findsOneWidget);
    expect(notifications.canceled, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'successful swipe deletion exposes Undo after its card unmounts',
    (tester) async {
      final task = Reminder(
        id: 'undo-delete',
        taskTitle: 'Bring this task back',
        quadrantLevel: 1,
      );
      await tester.runAsync(
        () => container.read(remindersProvider.notifier).addReminder(task),
      );
      await show(tester, card(task.id));
      await tester.drag(find.byType(TaskCard), const Offset(-700, 0));
      for (var i = 0; i < 50 && find.text('撤销').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(TaskCard), findsNothing);
      expect(notifications.canceled, [task.id]);
      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      for (
        var i = 0;
        i < 50 && container.read(remindersProvider).isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(TaskCard), findsOneWidget);
      expect(container.read(remindersProvider).single.id, task.id);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'dark input send action uses the foreground paired with its primary fill',
    (tester) async {
      await show(tester, const InputBottomBar(), brightness: Brightness.dark);
      await tester.enterText(find.byType(TextField), 'Ready to send');
      await tester.pump();
      final finder = find.widgetWithIcon(
        IconButton,
        Icons.arrow_upward_rounded,
      );
      final button = tester.widget<IconButton>(finder);
      final colors = Theme.of(tester.element(finder)).colorScheme;
      expect(button.onPressed, isNotNull);
      expect(button.style!.backgroundColor!.resolve({}), colors.primary);
      expect(button.style!.foregroundColor!.resolve({}), colors.onPrimary);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
