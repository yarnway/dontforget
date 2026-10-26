import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('media-action-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    final db = await database.database;
    await db.insert(
      'MediaRecords',
      MediaRecord(
        id: 'record',
        type: 'audio',
        contentOrPath: '/isolated/voice.m4a',
        createdAt: DateTime(2026, 10, 27),
      ).toJson(),
    );
    container = ProviderContainer(
      overrides: [databaseHelperProvider.overrideWithValue(database)],
    );
    await container.read(mediaRecordsProvider.notifier).ready;
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });
  for (final language in ['en', 'zh', 'ja']) {
    testWidgets(
      'attachment label activates media without navigation ($language)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var played = 0;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: Locale(language),
              supportedLocales: const [
                Locale('en'),
                Locale('zh'),
                Locale('ja'),
              ],
              localizationsDelegates: const [
                AppLocalizationsDelegate(),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: TaskCard(
                    task: Reminder(
                      id: 'media',
                      taskTitle: 'Audio attachment',
                      quadrantLevel: 2,
                      recordId: 'record',
                    ),
                    onPlayMedia: () => played++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final label = AppLocalizations.of(
          tester.element(find.byType(TaskCard)),
        ).get('playOrPreview');
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(played, 1);
        expect(find.byType(TaskDetailScreen), findsNothing);
        final button = find.ancestor(
          of: find.text(label),
          matching: find.byType(TextButton),
        );
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        Focus.of(tester.element(find.text(label))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(played, 2);
        expect(find.byType(TaskDetailScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
