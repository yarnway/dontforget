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

  testWidgets('App starts and + button displays media options sheet', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: MyApp()));
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
}
