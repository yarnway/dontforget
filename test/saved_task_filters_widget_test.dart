import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/models/saved_task_filter.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/saved_task_filters_provider.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/planning_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/workspace_drafts.dart';

class _Notifications implements NotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late SavedTaskFilterStore store;
  final saveButton = find.byKey(const ValueKey('save-task-filter'));
  final chooseButton = find.byKey(const ValueKey('choose-task-filter'));
  final nameInput = find.byKey(const ValueKey('task-filter-name'));
  final confirmButton = find.byKey(const ValueKey('confirm-task-filter'));
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('dontforget-filter-ui-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    final db = await database.database;
    for (final title in ['Alpha task', 'Beta task']) {
      await db.insert(
        'Reminders',
        Reminder(
          id: title,
          taskTitle: title,
          quadrantLevel: 2,
          detailsJson: const TaskDetails()
              .record('completed', DateTime(2026, 1))
              .encode(),
        ).toJson(),
      );
    }
    final notifications = _Notifications();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        remindersProvider.overrideWith(
          (_) => RemindersNotifier(
            database,
            notifications: notifications,
            runLoadEffects: false,
          ),
        ),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    store = container.read(savedTaskFilterStoreProvider);
    await store.load();
  });
  tearDown(() async {
    container.dispose();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
  });
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    double width = 375,
    String locale = 'zh',
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(locale),
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
            child: InlineFeedback(child: child!),
          ),
          home: const Scaffold(body: TaskManagementPanel()),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, container);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Future<void> enterName(WidgetTester tester, String name) async {
    await tester.enterText(nameInput, name);
    await tester.tap(confirmButton);
    await settle(tester);
  }

  Future<void> menuAction(WidgetTester tester, String action) async {
    await tester.tap(chooseButton);
    await settle(tester);
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await settle(tester);
    await tester.tap(find.text(action));
    await settle(tester);
  }

  testWidgets(
    'save and apply restore both view and keyword; history obeys keyword',
    (tester) async {
      await pump(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, '执行记录'));
      await tester.enterText(find.byType(TextField).first, 'Alpha');
      await tester.pump();
      expect(find.text('Alpha task'), findsOneWidget);
      expect(find.text('Beta task'), findsNothing);
      await tester.tap(saveButton);
      await settle(tester);
      await enterName(tester, 'Alpha history');
      await tester.tap(find.widgetWithText(ChoiceChip, '管理'));
      await tester.enterText(find.byType(TextField).first, 'Beta');
      await tester.pump();
      await tester.tap(chooseButton);
      await settle(tester);
      await tester.tap(find.text('Alpha history'));
      await settle(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Alpha',
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '执行记录'))
            .selected,
        isTrue,
      );
      expect(find.text('Beta task'), findsNothing);
      expect((await tester.runAsync(store.load))!.single.name, 'Alpha history');
      await finish(tester);
    },
  );
  testWidgets('rename, delete and undo persist through the real controls', (
    tester,
  ) async {
    await tester.runAsync(() => store.save('Work', 'manage', ''));
    await pump(tester);
    await menuAction(tester, '重命名');
    await enterName(tester, 'Renamed');
    expect((await tester.runAsync(store.load))!.single.name, 'Renamed');
    await menuAction(tester, '删除筛选');
    expect(await tester.runAsync(store.load), isEmpty);
    await tester.tap(find.text('撤销'));
    await settle(tester);
    expect((await tester.runAsync(store.load))!.single.name, 'Renamed');
    await finish(tester);
  });
  testWidgets(
    'empty and duplicate names keep the dialog and saved filters intact',
    (tester) async {
      await tester.runAsync(() => store.save('Work', 'manage', ''));
      await pump(tester);
      await tester.tap(saveButton);
      await settle(tester);
      await enterName(tester, ' ');
      expect(find.text('请输入 1–64 个字符的名称'), findsOneWidget);
      await enterName(tester, 'work');
      expect(find.text('已有同名筛选，请换一个名称'), findsOneWidget);
      expect((await tester.runAsync(store.load))!, hasLength(1));
      await tester.tap(find.text('取消'));
      await settle(tester);
      await finish(tester);
    },
  );
  testWidgets('corrupt saved filters leave manual filtering available', (
    tester,
  ) async {
    await tester.runAsync(
      () => container.read(workspaceDraftsProvider.notifier).put(
        SavedTaskFilter.storageKey,
        {'version': 99},
      ),
    );
    await pump(tester);
    expect(find.text('常用筛选暂时无法读取，仍可手动筛选'), findsOneWidget);
    expect(tester.widget<TextButton>(saveButton).onPressed, isNull);
    await tester.enterText(find.byType(TextField).first, 'Alpha');
    await tester.pump();
    expect(find.text('Alpha task'), findsOneWidget);
    expect(find.text('Beta task'), findsNothing);
    await finish(tester);
  });
  testWidgets(
    'a name dialog opened before recovery cannot save into the new generation',
    (tester) async {
      await pump(tester);
      await tester.tap(saveButton);
      await settle(tester);
      await tester.runAsync(() async {
        final lease = await database.beginMaintenance();
        await lease.resume();
      });
      await enterName(tester, 'Stale');
      final rows = await tester.runAsync(
        () async => (await database.database).query('Settings'),
      );
      expect(rows!.single['workspace_drafts_json'], isNull);
      await tester.tap(find.text('取消'));
      await settle(tester);
      await finish(tester);
    },
  );
  for (final width in [375.0, 768.0, 1440.0]) {
    for (final locale in ['zh', 'en', 'ja']) {
      testWidgets(
        'saved-filter list and name editor fit $locale $width at 2x text',
        (tester) async {
          await tester.runAsync(() async {
            for (var i = 0; i < 12; i++) {
              await store.save(
                '${'常用筛选 Long name ' * 3}$i',
                'history',
                'query ' * 30,
              );
            }
          });
          await pump(tester, width: width, locale: locale, scale: 2);
          expect(tester.takeException(), isNull);
          await tester.tap(chooseButton);
          await settle(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byType(PopupMenuButton<String>).first);
          await settle(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(
            find.text(
              locale == 'zh'
                  ? '重命名'
                  : locale == 'ja'
                  ? '名前を変更'
                  : 'Rename',
            ),
          );
          await settle(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(
            find.text(
              locale == 'zh'
                  ? '取消'
                  : locale == 'ja'
                  ? 'キャンセル'
                  : 'Cancel',
            ),
          );
          await settle(tester);
          await finish(tester);
        },
      );
    }
  }
  testWidgets(
    'name editor remains usable above a small-screen keyboard at 2x text',
    (tester) async {
      await pump(tester, width: 375, locale: 'en', scale: 2);
      tester.view.physicalSize = const Size(375, 667);
      await tester.pump();
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await settle(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(nameInput);
      await tester.enterText(nameInput, 'Keyboard filter');
      await tester.tap(confirmButton);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        (await tester.runAsync(store.load))!.single.name,
        'Keyboard filter',
      );
      await finish(tester);
    },
  );
}
