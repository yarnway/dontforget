import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/live_reminder_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Notifications implements NotificationService {
  @override
  String get datasetEpoch => '11111111-1111-4111-8111-111111111111';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LiveBackend implements LiveReminderBackend {
  String? payload;
  int starts = 0;
  @override
  Future<LiveReminderStatus> read() async =>
      LiveReminderStatus(LiveReminderAvailability.available, payload: payload);
  @override
  Future<void> start(Map<String, Object> content) async {
    starts++;
    payload = content['payload'] as String;
  }

  @override
  Future<void> end() async => payload = null;
  @override
  Future<void> synchronize(Map<String, Object>? content) async =>
      payload = content?['payload'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _LiveBackend backend;
  late Reminder task;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('live-detail-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    task = Reminder(
      id: 'live-detail-draft',
      taskTitle: 'Synthetic reminder',
      quadrantLevel: 2,
      triggerTime: DateTime.now().add(const Duration(hours: 2)),
    );
    await database.writeTransaction(
      database.captureGeneration(),
      (db) => db.insert('Reminders', task.toJson()),
    );
    backend = _LiveBackend();
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
        liveReminderServiceProvider.overrideWith(
          (_) => LiveReminderService(backend),
        ),
      ],
    );
    await container.read(remindersProvider.notifier).ready;
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'category edit and revert update Live Activity gate immediately',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (_, child) => InlineFeedback(child: child!),
            home: TaskDetailScreen(task: task),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final start = find.widgetWithText(OutlinedButton, 'Show Live Activity');
      expect(tester.widget<OutlinedButton>(start).onPressed, isNotNull);
      final categories = find.byType(ChoiceChip);
      await tester.ensureVisible(categories.at(2));
      await tester.tap(categories.at(2));
      await tester.pump();
      expect(tester.widget<OutlinedButton>(start).onPressed, isNull);
      expect(
        find.text('Save your edits before updating the Live Activity.'),
        findsOneWidget,
      );
      expect(backend.starts, 0);

      await tester.ensureVisible(categories.at(1));
      await tester.tap(categories.at(1));
      await tester.pump();
      expect(tester.widget<OutlinedButton>(start).onPressed, isNotNull);
      expect(
        find.text('Save your edits before updating the Live Activity.'),
        findsNothing,
      );
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(backend.starts, 1);
      expect(find.text('End Live Activity'), findsOneWidget);
      expect(container.read(remindersProvider).single.toJson(), task.toJson());
      await container.read(liveReminderServiceProvider).stop();
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
