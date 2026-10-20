import 'package:flutter/services.dart';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recorderChannel = MethodChannel('com.llfbandit.record/messages');
  late Directory testDirectory;
  late DatabaseHelper testDatabase;
  late ProviderContainer container;
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, (call) async {
      if (call.method == 'create' || call.method == 'dispose') return null;
      throw UnsupportedError('Unexpected recorder operation: ${call.method}');
    });
    sqfliteFfiInit();
    testDirectory = await Directory.systemTemp.createTemp('dontforget-widget-');
    testDatabase = DatabaseHelper.forTesting(
      testDirectory.path,
      databaseFactoryFfi,
    );
    container = ProviderContainer(
        overrides: [databaseHelperProvider.overrideWithValue(testDatabase)]);
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

  testWidgets('End-to-End Test: Settings Navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MyApp(),
      ),
    );
    // Use pump instead of pumpAndSettle because of infinite breathing animation
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TextField), findsWidgets);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    Navigator.pop(tester.element(find.byType(DropdownButtonFormField<String>)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TextField), findsOneWidget);
  });
}
