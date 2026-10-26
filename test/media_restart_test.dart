import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'package:dont_forget/ui/widgets/quadrant_view.dart';
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

  testWidgets('completed voice in quadrant accepts a normal mouse click',
      (tester) async {
    var played = 0;
    await tester.runAsync(() => container.read(mediaRecordsProvider.notifier).ready);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: const [AppLocalizationsDelegate()],
        home: Scaffold(
          body: QuadrantView(
            level: 1,
            titleIcon: const Icon(Icons.local_fire_department),
            bgColor: Colors.red,
            allReminders: [Reminder(
              id: 'completed-voice-task',
              recordId: saved.id,
              taskTitle: 'Saved voice',
              quadrantLevel: 1,
              isCompleted: true,
            )],
            onPlayMedia: (_) => played++,
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.mic_none), findsNothing);
    await tester.tap(find.byKey(const ValueKey('completed-1')));
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.mic_none)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    expect(played, 1);
    expect(find.text('Play / preview attachment'), findsOneWidget);
    final button = find.ancestor(
      of: find.byIcon(Icons.mic_none),
      matching: find.byType(TextButton),
    );
    expect(tester.getSize(button).width, greaterThanOrEqualTo(40));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(40));

    // A deliberate long hold still starts dragging the card.
    final drag = await tester.startGesture(
      tester.getCenter(find.text('Saved voice')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Saved voice'), findsNWidgets(2));
    expect(played, 1);
    await drag.up();
    await tester.pumpAndSettle();
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
