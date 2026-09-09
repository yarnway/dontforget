import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/l10n/app_localizations.dart';

void main() {
  testWidgets('TaskDetailScreen renders task title, summary, reminder time, and professional categories',
      (WidgetTester tester) async {
    final task = Reminder(
      id: 'test-123',
      taskTitle: '参加周三技术评审会',
      taskSummary: '需要准备PPT架构图与云原生评估报告',
      quadrantLevel: 1,
      triggerTime: DateTime.now().add(const Duration(hours: 2)),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: const [
            Locale('zh'),
            Locale('en'),
            Locale('ja'),
          ],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: TaskDetailScreen(task: task),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Title and Summary fields
    expect(find.text('事项详情'), findsOneWidget);
    expect(find.text('参加周三技术评审会'), findsOneWidget);
    expect(find.text('需要准备PPT架构图与云原生评估报告'), findsOneWidget);

    // Verify Professional Categories exist
    expect(find.text('紧急提醒'), findsWidgets);
    expect(find.text('重点跟进'), findsWidgets);
    expect(find.text('常规待办'), findsWidgets);
    expect(find.text('备忘便签'), findsWidgets);

    // Verify Quick Presets exist
    expect(find.text('+15分钟'), findsOneWidget);
    expect(find.text('+1小时'), findsOneWidget);
    expect(find.text('今晚 20:00'), findsOneWidget);
    expect(find.text('明天 09:00'), findsOneWidget);

    // Verify Save button
    expect(find.text('保存修改'), findsOneWidget);
  });
}
