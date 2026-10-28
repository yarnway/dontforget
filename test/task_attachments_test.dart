import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dont_forget/services/portable_backup_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/local_media_store.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/task_attachment_files.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/task_attachments_panel.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/interaction_preview.dart';

class _Notifications implements NotificationService {
  int calls = 0;
  @override
  Future<void> cancelReminderStrict(String id) async {
    calls++;
  }

  @override
  Future<void> scheduleReminderStrict(Reminder task) async {
    calls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DuplicateFile extends TaskAttachmentFiles {
  _DuplicateFile(LocalMediaStore store) : super(store: store);
  @override
  Future<MediaRecord> import(String source) async {
    final record = await super.import(source);
    return MediaRecord(
      id: 'original',
      type: record.type,
      contentOrPath: record.contentOrPath,
      createdAt: record.createdAt,
    );
  }
}

class _ImmediatePaths extends LocalMediaStore {
  @override
  Future<String> resolvePath(String storedPath) async => storedPath;
}

class _Picker extends TaskAttachmentPicker {
  Future<String?> Function() pick = () async => null;
  @override
  Future<String?> image() => pick();
  @override
  Future<String?> file() => pick();
}

Future<void> waitForImage(WidgetTester tester) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump();
    final images = tester.widgetList<RawImage>(find.byType(RawImage));
    if (images.isNotEmpty && images.every((image) => image.image != null)) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('The local attachment image did not decode');
}

void main() {
  setUpAll(loadInteractionPreviewFonts);
  late Directory directory;
  late DatabaseHelper database;
  late RemindersNotifier tasks;
  late _Notifications notifications;
  late LocalMediaStore store;
  late File input;
  late ProviderContainer container;
  late _Picker picker;
  var renderedRecords = <String, MediaRecord>{};

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('task-attachments-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    notifications = _Notifications();
    tasks = RemindersNotifier(
      database,
      notifications: notifications,
      runLoadEffects: false,
    );
    await tasks.ready;
    store = LocalMediaStore(
      documentsDirectory: () async =>
          Directory('${directory.path}/Documents')..createSync(),
    );
    input = await File(
      '${directory.path}/reference.txt',
    ).writeAsString('Related instructions 中文 日本語');
    picker = _Picker();
    renderedRecords = {};
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        remindersProvider.overrideWith((ref) => tasks),
        taskAttachmentFilesProvider.overrideWithValue(
          TaskAttachmentFiles(store: store),
        ),
        taskAttachmentPathProvider.overrideWithValue(_ImmediatePaths()),
        taskAttachmentPickerProvider.overrideWithValue(picker),
        taskAttachmentRecordsProvider.overrideWithValue(
          (ids) async => renderedRecords,
        ),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<Reminder> seed({TaskDetails? details, String? recordId}) async {
    final task = Reminder(
      id: 'task',
      recordId: recordId,
      taskTitle: 'Bring supporting documents',
      quadrantLevel: 2,
      triggerTime: DateTime(2028, 1, 2, 8),
      eventTime: DateTime(2028, 1, 2, 9),
      noticeRevision: 4,
      detailsJson: details?.encode(),
    );
    await database.writeTransaction(database.captureGeneration(), (db) async {
      if (recordId != null) {
        await db.insert(
          'MediaRecords',
          MediaRecord(
            id: recordId,
            type: 'text',
            contentOrPath: 'Original input',
            createdAt: DateTime(2026),
          ).toJson(),
        );
      }
      await db.insert('Reminders', task.toJson());
    });
    await tasks.refreshReminders();
    notifications.calls = 0;
    return tasks.state.single;
  }

  Future<Reminder> reload() async => database.read(
    database.captureGeneration(),
    (db) async => Reminder.fromJson((await db.query('Reminders')).single),
  );

  test(
    'attachments are bounded, version fenced, and legacy encodings stay unchanged',
    () {
      const old = TaskDetails(tags: ['reference']);
      expect(old.toJson()['version'], 1);
      expect(old.toJson().containsKey('attachment_ids'), isFalse);
      final attached = old.patch({
        'attachment_ids': ['photo'],
      });
      expect(attached.toJson()['version'], 3);
      expect(TaskDetails.decode(attached.encode()).attachmentIds, ['photo']);
      expect(attached.patch({'attachment_ids': []}).toJson(), old.toJson());
      expect(
        () => TaskDetails.decode(
          jsonEncode({...attached.toJson(), 'version': 1}),
        ),
        throwsFormatException,
      );
      expect(
        () => TaskDetails.decode(
          jsonEncode({...attached.toJson(), 'version': 2}),
        ),
        throwsFormatException,
      );
      for (final invalid in [
        [''],
        ['x', 'x'],
        List.generate(13, (i) => '$i'),
        [42],
      ]) {
        expect(
          () => old.patch({'attachment_ids': invalid}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'copy, link, reopen, remove and undo preserve source and reminder occurrence',
    () async {
      final before = await seed(
        recordId: 'original',
        details: const TaskDetails(project: 'Trip'),
      );
      final saved = await tasks.addTaskAttachment(
        before,
        input.path,
        database.captureGeneration(),
        files: TaskAttachmentFiles(store: store),
      );
      final id = saved.details.attachmentIds.single;
      final rows = await database.read(
        database.captureGeneration(),
        (db) => db.query('MediaRecords'),
      );
      final media = MediaRecord.fromJson(
        rows.singleWhere((r) => r['id'] == id),
      );
      expect(
        await File(media.contentOrPath).readAsBytes(),
        await input.readAsBytes(),
      );
      expect(media.contentOrPath, isNot(input.path));
      final expected = before.toJson()..['details_json'] = saved.detailsJson;
      expect((await reload()).toJson(), expected);
      expect(saved.details.project, 'Trip');
      expect(saved.bitmask & TaskBitmask.hasAttachment, isNonZero);
      final removed = await tasks.setTaskAttachmentLinked(
        saved,
        id,
        false,
        database.captureGeneration(),
      );
      expect(removed.details.attachmentIds, isEmpty);
      expect(await File(media.contentOrPath).exists(), isTrue);
      final restored = await tasks.setTaskAttachmentLinked(
        removed,
        id,
        true,
        database.captureGeneration(),
      );
      expect(restored.details.attachmentIds, [id]);
      expect(notifications.calls, 0);
      expect(await input.readAsString(), 'Related instructions 中文 日本語');
      await database.close();
      expect((await reload()).details.attachmentIds, [id]);
    },
  );

  test(
    'stale editor cannot overwrite links and oversized import leaves no media rows',
    () async {
      final old = await seed();
      await tasks.addTaskAttachment(
        old,
        input.path,
        database.captureGeneration(),
        files: TaskAttachmentFiles(store: store),
      );
      await expectLater(
        tasks.addTaskAttachment(
          old,
          input.path,
          database.captureGeneration(),
          files: TaskAttachmentFiles(store: store),
        ),
        throwsA(isA<StaleReminderOccurrenceException>()),
      );
      final big = File('${directory.path}/big.bin');
      final handle = await big.open(mode: FileMode.write);
      await handle.truncate(TaskAttachmentFiles.maxBytes + 1);
      await handle.close();
      await expectLater(
        tasks.addTaskAttachment(
          await reload(),
          big.path,
          database.captureGeneration(),
          files: TaskAttachmentFiles(store: store),
        ),
        throwsA(isA<AttachmentTooLarge>()),
      );
      expect(
        (await database.read(
          database.captureGeneration(),
          (db) => db.query('MediaRecords'),
        )).length,
        1,
      );
      expect((await reload()).details.attachmentIds.length, 1);
    },
  );

  test(
    'media transaction failure rolls back link and removes only fresh private copy',
    () async {
      final old = await seed(recordId: 'original');
      await expectLater(
        tasks.addTaskAttachment(
          old,
          input.path,
          database.captureGeneration(),
          files: _DuplicateFile(store),
        ),
        throwsA(anything),
      );
      expect((await reload()).toJson(), old.toJson());
      expect(
        await Directory('${directory.path}/Documents/media').list().toList(),
        isEmpty,
      );
      expect(await input.exists(), isTrue);
      expect(
        (await database.read(
          database.captureGeneration(),
          (db) => db.query('MediaRecords'),
        )).single['content_or_path'],
        'Original input',
      );
    },
  );

  test(
    'routine edit preserves attachments on the owner and existing doses',
    () async {
      final old = await seed(
        details: const TaskDetails(
          kind: 'medicationPlan',
          attachmentIds: ['owner-image'],
        ),
      );
      final child = Reminder(
        id: 'dose',
        taskTitle: 'Dose',
        quadrantLevel: 1,
        triggerTime: DateTime(2028),
        detailsJson: const TaskDetails(
          kind: 'medication',
          planId: 'task',
          attachmentIds: ['dose-image'],
        ).encode(),
      );
      await database.writeTransaction(
        database.captureGeneration(),
        (db) => db.insert('Reminders', child.toJson()),
      );
      final proposed = old.copyWith(
        taskTitle: 'Updated plan',
        detailsJson: const TaskDetails(kind: 'medicationPlan').encode(),
      );
      await tasks.saveRoutine(
        proposed,
        [
          child.copyWith(
            detailsJson: const TaskDetails(
              kind: 'medication',
              planId: 'task',
            ).encode(),
          ),
        ],
        database.captureGeneration(),
        baseline: old,
        now: DateTime(2026),
      );
      final rows = await database.read(
        database.captureGeneration(),
        (db) => db.query('Reminders'),
      );
      expect(
        Reminder.fromJson(
          rows.singleWhere((r) => r['id'] == 'task'),
        ).details.attachmentIds,
        ['owner-image'],
      );
      expect(
        Reminder.fromJson(
          rows.singleWhere((r) => r['id'] == 'dose'),
        ).details.attachmentIds,
        ['dose-image'],
      );
    },
  );

  test(
    'portable backup restores attachment references and copied files together',
    () async {
      final seeded = await seed(recordId: 'original');
      final saved = await tasks.addTaskAttachment(
        seeded,
        input.path,
        database.captureGeneration(),
        files: TaskAttachmentFiles(store: store),
      );
      const backup = PortableBackupService();
      final bundle = await backup.create(
        database,
        database.captureGeneration(),
      );
      final archive = await File(
        '${directory.path}/attachments.dfbackup.json',
      ).writeAsBytes(bundle.bytes);
      final inspected = await backup.inspect(archive);
      final snapshot = await backup.prepareRestore(
        archive,
        Directory('${directory.path}/restored-media'),
        expectedDigest: inspected.digest,
        isCurrent: () => true,
      );
      final inspector = BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: directory,
      );
      final preview = await inspector.inspect(snapshot);
      expect(preview.unresolvedReferences, 0);
      expect(preview.missingMedia, 0);
      final restored = DatabaseHelper.forTesting(
        '${directory.path}/restored',
        databaseFactoryFfi,
      );
      final backend = NotificationService.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
      try {
        await DatabaseRecovery(
          restored,
          inspector: inspector,
          notifications: backend,
        ).restore(snapshot, expectedDigest: preview.digest);
        await restored.close(createBackup: false);
        final rows = await restored.read(
          restored.captureGeneration(),
          (db) => db.query('Reminders'),
        );
        expect(
          Reminder.fromJson(rows.single).details.attachmentIds,
          saved.details.attachmentIds,
        );
        final media = await restored.read(
          restored.captureGeneration(),
          (db) => db.query('MediaRecords'),
        );
        final attached = media.singleWhere(
          (m) => m['id'] == saved.details.attachmentIds.single,
        );
        expect(
          await File(attached['content_or_path'] as String).readAsBytes(),
          await input.readAsBytes(),
        );
        final broken = jsonDecode(await snapshot.readAsString());
        (broken['media_records'] as List).removeWhere(
          (m) => m['id'] == saved.details.attachmentIds.single,
        );
        final brokenFile = await File(
          '${directory.path}/broken.json',
        ).writeAsString(jsonEncode(broken));
        expect((await inspector.inspect(brokenFile)).unresolvedReferences, 1);
      } finally {
        await restored.close(createBackup: false);
        await backend.pauseForMaintenance();
      }
    },
  );

  Future<void> host(
    WidgetTester tester,
    Reminder task, {
    String language = 'en',
    double scale = 1,
  }) async {
    renderedRecords = (await tester.runAsync(
      () => database.read(database.captureGeneration(), (db) async {
        final rows = await db.query('MediaRecords');
        return {
          for (final row in rows)
            row['id'] as String: MediaRecord.fromJson(row),
        };
      }),
    ))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light,
            locale: Locale(language),
            supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(
                key: interactionPreviewKey,
                child: InlineFeedback(child: child!),
              ),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: TaskAttachmentsPanel(task: task),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
  }

  for (final language in ['zh', 'en', 'ja']) {
    testWidgets('attachment controls and preview fit 320px at 2x ($language)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final task = await tester.runAsync(() async {
        final seeded = await seed();
        return tasks.addTaskAttachment(
          seeded,
          input.path,
          database.captureGeneration(),
          files: TaskAttachmentFiles(store: store),
        );
      });
      await host(tester, task!, language: language, scale: 2);
      expect(find.text('reference.txt'), findsOneWidget);
      await captureInteractionPreview(tester, 'attachments-$language-320-2x');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(find.byType(TaskAttachmentPreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('image thumbnail opens a zoomable preview with its saved file', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 240, 160),
        Paint()..color = Colors.teal,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(240, 160);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final photo = await File(
        '${directory.path}/trip-photo.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
      return tasks.addTaskAttachment(
        await seed(),
        photo.path,
        database.captureGeneration(),
        files: TaskAttachmentFiles(store: store),
      );
    });
    await host(tester, task!);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    final tile = tester.widget<Image>(find.byType(Image));
    await waitForImage(tester);
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await captureInteractionPreview(tester, 'attachments-image');
    expect((tile.image as ResizeImage).width, 384);
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final visible = find.descendant(
      of: find.byType(TaskAttachmentPreview),
      matching: find.byType(Image),
    );
    expect(visible, findsOneWidget);
    expect((tester.widget<Image>(visible).image as ResizeImage).width, 2048);
    await waitForImage(tester);
    await tester.pumpAndSettle();
    await captureInteractionPreview(tester, 'attachment-zoomed-preview');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'canceled picker and late selection after recovery never import',
    (tester) async {
      final task = await tester.runAsync(() => seed());
      await host(tester, task!);
      await tester.tap(find.byKey(const ValueKey('attach-photo')));
      await tester.pumpAndSettle();
      expect(tasks.state.single.details.attachmentIds, isEmpty);
      final selected = Completer<String?>();
      picker.pick = () => selected.future;
      await tester.tap(find.byKey(const ValueKey('attach-file')));
      await tester.pump();
      final gate = container.read(runtimeRecoveryGateProvider);
      final paused = await gate.pause();
      gate.resume(paused);
      selected.complete(input.path);
      await tester.pumpAndSettle();
      expect(tasks.state.single.details.attachmentIds, isEmpty);
      expect(
        await tester.runAsync(
          () => Directory('${directory.path}/Documents').exists(),
        ),
        isFalse,
      );
    },
  );
}
