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
  const notificationsChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  final notificationCalls = <String>[];
  late Directory testDirectory;
  late DatabaseHelper testDatabase;
  late ProviderContainer container;
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, (call) async {
          notificationCalls.add(call.method);
          switch (call.method) {
            case 'initialize':
            case 'areNotificationsEnabled':
            case 'canScheduleExactNotifications':
              return true;
            case 'getNotificationAppLaunchDetails':
              return {'notificationLaunchedApp': false};
            case 'checkPermissions':
              return {
                'isEnabled': true,
                'isAlertEnabled': true,
                'isSoundEnabled': true,
                'isProvisionalEnabled': false,
              };
            case 'cancel':
            case 'cancelAll':
              return null;
            default:
              throw UnsupportedError(
                'Unexpected notification call: ${call.method}',
              );
          }
        });
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
    // Complete the file-backed notification epoch outside widget fake async.
    await container.read(notificationServiceProvider).init();
  });
  tearDownAll(() async {
    container.dispose();
    await testDatabase.close();
    await testDirectory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, null);
  });

  testWidgets('End-to-End Test: Settings Navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    // Use pump instead of pumpAndSettle because of infinite breathing animation
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final language = find.byType(DropdownButtonFormField<String>);
    await tester.scrollUntilVisible(
      language,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await Scrollable.ensureVisible(tester.element(language), alignment: 0.3);
    await tester.pump();
    expect(language.hitTestable(), findsOneWidget);
    final model = find.byKey(const ValueKey('settings-model-name'));
    await tester.scrollUntilVisible(
      model,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await Scrollable.ensureVisible(tester.element(model), alignment: 0.3);
    await tester.pump();
    expect(model.hitTestable(), findsOneWidget);
    expect(
      tester.widget<TextField>(model).controller!.text,
      container.read(settingsProvider).modelName,
    );
    expect(
      notificationCalls.where((call) => call.startsWith('request')),
      isEmpty,
    );
    Navigator.pop(tester.element(model));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
