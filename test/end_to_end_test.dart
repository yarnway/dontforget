import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/app.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('End-to-End Test: Settings Navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    // Use pump instead of pumpAndSettle because of infinite breathing animation
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    Navigator.pop(tester.element(find.byType(DropdownButtonFormField<String>)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TextField), findsOneWidget);
  });
}
