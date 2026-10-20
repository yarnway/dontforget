import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/app.dart';
import 'package:dont_forget/models/reminder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recorderChannel = MethodChannel('com.llfbandit.record/messages');
  late Directory testDirectory;
  late DatabaseHelper testDatabase;
  late ProviderContainer container;
  setUpAll(() async {
    if (const bool.fromEnvironment('UI_PREVIEW')) {
      const fontPath = String.fromEnvironment('PREVIEW_FONT');
      const iconPath = String.fromEnvironment('PREVIEW_ICONS');
      if (fontPath.isNotEmpty && iconPath.isNotEmpty) {
        for (final family in ['Ahem', 'Roboto']) {
          final loader = FontLoader(family)
            ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
          await loader.load();
        }
        await (FontLoader(
              'MaterialIcons',
            )..addFont(File(iconPath).readAsBytes().then(ByteData.sublistView)))
            .load();
      }
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, (call) async {
          if (call.method == 'create' || call.method == 'dispose') return null;
          throw UnsupportedError(
            'Unexpected recorder operation: ${call.method}',
          );
        });
    sqfliteFfiInit();
    testDirectory = await Directory.systemTemp.createTemp('dontforget-widget-');
    testDatabase = DatabaseHelper.forTesting(
      testDirectory.path,
      databaseFactoryFfi,
    );
    container = ProviderContainer(
      overrides: [databaseHelperProvider.overrideWithValue(testDatabase)],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
  });
  tearDownAll(() async {
    container.dispose();
    await testDatabase.close();
    await testDirectory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null);
  });

  testWidgets('App starts and + button displays media options sheet', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    // Use pump with fixed duration due to infinite breathing mic animation
    await tester.pump(const Duration(seconds: 1));

    // Verify '+' button is present
    final addBtn = find.byIcon(Icons.add_circle_outline_rounded);
    expect(addBtn, findsOneWidget);

    // Tap '+' button
    await tester.tap(addBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Verify modal options exist
    expect(find.text('上传素材给大模型'), findsOneWidget);
    expect(find.text('拍摄照片'), findsOneWidget);
    expect(find.text('相册图片'), findsOneWidget);
    expect(find.text('导入文件'), findsOneWidget);
    expect(find.text('上传视频'), findsOneWidget);

    // Close sheet
    Navigator.pop(tester.element(find.text('上传素材给大模型')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Verify input box exists
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('workspace stays usable at phone, tablet and desktop widths', (
    tester,
  ) async {
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());
    tester.view.devicePixelRatio = 1;
    await tester.runAsync(() async {
      final notifier = container.read(remindersProvider.notifier);
      for (final task in [
        Reminder(id: 'ui-review-1', taskTitle: '准备周会材料', taskSummary: '整理进度、风险与本周计划', quadrantLevel: 1),
        Reminder(id: 'ui-review-2', taskTitle: '完善产品使用指南', taskSummary: '补充首次使用与常见问题', quadrantLevel: 2),
        Reminder(id: 'ui-review-3', taskTitle: '记录阅读笔记', quadrantLevel: 4),
        Reminder(id: 'ui-review-done', taskTitle: '完成昨日复盘', quadrantLevel: 1, isCompleted: true),
      ]) { await notifier.addReminder(task); }
    });
    for (final width in [375.0, 768.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const RepaintBoundary(
            key: ValueKey('workspace-preview'),
            child: MyApp(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('更多功能'), findsOneWidget);
      expect(find.byTooltip('设置'), findsOneWidget);
      // Typing a shortcut letter must not switch focus mode.
      await tester.tap(find.byType(TextField));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(container.read(immersiveModeProvider), isFalse);
      if (const bool.fromEnvironment('UI_PREVIEW')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('workspace-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('dist/ui-preview');
          await directory.create(recursive: true);
          await File(
            '${directory.path}/workspace-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    }
  });
}
