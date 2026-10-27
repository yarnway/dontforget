import 'support/workspace_drafts.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/app.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  setUp(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'tray_manager',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async => switch (call.method) {
        'initialize' => true,
        'getNotificationAppLaunchDetails' => {'notificationLaunchedApp': false},
        _ => null,
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (call) async => null,
          );
        }
        return null;
      },
    );
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('review-cache-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    container = ProviderContainer(
      overrides: [databaseHelperProvider.overrideWithValue(database)],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(workspaceDraftsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
    // Complete real filesystem identity I/O outside the widget fake-async zone.
    await container.read(notificationServiceProvider).init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async => null,
        );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });
  testWidgets(
    'compact board fits short phone with keyboard and reminder panel',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(375, 667);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      await tester.runAsync(
        () => container
            .read(remindersProvider.notifier)
            .addReminder(
              Reminder(
                id: 'compact',
                taskTitle: 'Upcoming fixture',
                quadrantLevel: 1,
                triggerTime: DateTime.now().add(const Duration(minutes: 2)),
              ),
            ),
      );
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const MyApp()),
      );
      await tester.pump();
      addTearDown(() => drainWorkspaceDrafts(tester, container));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('search opens for browsing and clear works before debounce', (
    tester,
  ) async {
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    await tester.pump();
    Future<void> focusSearch() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await focusSearch();
    final field = find.byKey(const ValueKey('task-search-field'));
    expect(field, findsOneWidget);
    expect(find.byKey(const ValueKey('search-filter-today')), findsOneWidget);
    await tester.enterText(field, 'cancel before debounce');
    await tester.pump();
    final clear = find.byTooltip('清除搜索');
    expect(clear, findsOneWidget);
    await tester.tap(clear);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.tap(find.byKey(const ValueKey('search-filter-pending')));
    await tester.pump();
    await focusSearch();
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(field, findsNothing);
    addTearDown(() => drainWorkspaceDrafts(tester, container));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
