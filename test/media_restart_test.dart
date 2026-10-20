import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  final saved = MediaRecord(
    id: 'persisted-voice',
    type: 'audio',
    contentOrPath: '/local/documents/voice.m4a',
    createdAt: DateTime(2026, 10, 20),
  );

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('media-restart-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    final db = await database.database;
    await db.insert('MediaRecords', saved.toJson());
    container = ProviderContainer(overrides: [
      databaseHelperProvider.overrideWithValue(database),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  testWidgets('persisted voice gets a playback button after a fresh startup',
      (tester) async {
    var played = 0;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: const [AppLocalizationsDelegate()],
        home: Scaffold(
          body: TaskCard(
            task: Reminder(
              id: 'voice-task',
              recordId: saved.id,
              taskTitle: 'Saved voice',
              quadrantLevel: 2,
            ),
            onPlayMedia: () => played++,
          ),
        ),
      ),
    ));
    await tester.runAsync(() => container.read(mediaRecordsProvider.notifier).ready);
    await tester.pump();
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic_none));
    expect(played, 1);
  });

  test('capture during startup keeps both persisted and new media', () async {
    final added = MediaRecord(
      id: 'new-voice',
      type: 'audio',
      contentOrPath: '/local/documents/new.m4a',
      createdAt: DateTime(2026, 10, 21),
    );
    await container.read(mediaRecordsProvider.notifier).addRecord(added);
    expect(container.read(mediaRecordsProvider).map((m) => m.id),
        unorderedEquals([saved.id, added.id]));
    final db = await database.database;
    expect(await db.query('MediaRecords'), hasLength(2));
  });

  test('disposing while media loads does not update a disposed notifier',
      () async {
    final notifier = container.read(mediaRecordsProvider.notifier);
    container.dispose();
    await notifier.ready;
    // Replace the disposed container so teardown still owns a live instance.
    container = ProviderContainer();
  });
}
