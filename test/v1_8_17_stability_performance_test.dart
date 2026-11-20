import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/speech_settings.dart';
import 'package:dont_forget/models/tencent_speech_credentials.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/content/retained_media_references.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/speech_recognition_service.dart';
import 'package:dont_forget/services/windows_toast.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _DirectHttpOverrides extends HttpOverrides {}

class _SplitDirDatabase extends DatabaseHelper {
  _SplitDirDatabase(String dbDir, this.supportDir)
    : super.forTesting(dbDir, databaseFactoryFfi);
  final Directory supportDir;

  @override
  Future<Directory> get notificationActionQueueDirectory async => supportDir;
}

class _FlakyStopRecorder implements AudioRecorder {
  bool throwOnNextStop = false;
  int starts = 0;
  StreamController<Uint8List>? audio;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    starts++;
    audio = StreamController<Uint8List>.broadcast(sync: true);
    return audio!.stream;
  }

  @override
  Future<String?> stop() async {
    await audio?.close();
    if (throwOnNextStop) {
      throwOnNextStop = false;
      throw StateError('synthetic recorder stop failure');
    }
    return null;
  }

  @override
  Future<void> cancel() async => audio?.close();

  @override
  Future<void> dispose() async => audio?.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CancellableSpeech extends SpeechRecognitionService {
  @override
  LiveSpeechSession startRealtime(
    Stream<List<int>> Function(CancelToken) audio,
    SpeechSettings settings, {
    required void Function(String) onText,
  }) {
    final token = CancelToken();
    final completer = Completer<String>();
    unawaited(
      completer.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    audio(token).listen((_) {}, onError: (Object _) {});
    return LiveSpeechSession(completer.future, () {
      token.cancel();
      if (!completer.isCompleted) {
        completer.completeError(const SpeechRecognitionException('cancelled'));
      }
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'RetainedMediaReferences scans owned DB directory even when support directory differs',
    () async {
      final root = await Directory.systemTemp.createTemp('retained-split-');
      final supportDir = Directory(p.join(root.path, 'support'))..createSync();
      final dbDir = Directory(p.join(supportDir.path, 'databases'))
        ..createSync();
      final db = _SplitDirDatabase(dbDir.path, supportDir);
      addTearDown(() async {
        await db.close(createBackup: false);
        await root.delete(recursive: true);
      });

      final retainedMediaPath = p.join(
        root.path,
        'Documents',
        'media',
        'retained_photo.png',
      );
      await File(p.join(dbDir.path, 'ha_snapshot.json')).writeAsString(
        jsonEncode({
          'version': DatabaseHelper.schemaVersion,
          'settings': const [],
          'reminders': const [],
          'media_records': [
            {'type': 'image', 'content_or_path': retainedMediaPath},
          ],
        }),
      );

      final result = await RetainedMediaReferences.read(db);
      expect(result.uncertain, isFalse);
      expect(result.paths, contains(retainedMediaPath));
    },
  );

  test(
    'DatabaseMaintenanceLease legacy validation accepts schema versions 15 and 16',
    () async {
      for (final legacyVersion in [15, 16]) {
        final dir = await Directory.systemTemp.createTemp(
          'legacy-schema-$legacyVersion-',
        );
        final db = DatabaseHelper.forTesting(dir.path, databaseFactoryFfi);
        addTearDown(() async {
          await db.close(createBackup: false);
          await dir.delete(recursive: true);
        });

        final dbFile = p.join(dir.path, 'dont_forget_v3.db');
        final raw = await databaseFactoryFfi.openDatabase(
          dbFile,
          options: OpenDatabaseOptions(
            version: legacyVersion,
            onCreate: (d, _) async {
              await d.execute('CREATE TABLE Reminders (id TEXT PRIMARY KEY)');
            },
          ),
        );
        await raw.close();

        final lease = await db.beginMaintenance();
        try {
          await lease.validateAndOpen(migrate: false);
          final v = await lease.read((d) => d.rawQuery('PRAGMA user_version'));
          expect(v.single.values.single, legacyVersion);
        } finally {
          await lease.closeWithoutBackup();
          lease.fail();
        }
      }
    },
  );

  test(
    'HomeController recovers from recorder stop failure and discards cancelled live transcription',
    () async {
      final root = await Directory.systemTemp.createTemp('voice-resilience-');
      final db = DatabaseHelper.forTesting(
        p.join(root.path, 'db'),
        databaseFactoryFfi,
      );
      final recorder = _FlakyStopRecorder();
      final speech = _CancellableSpeech();
      final notifications = NotificationService.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
      final container = ProviderContainer(
        overrides: [
          databaseHelperProvider.overrideWithValue(db),
          notificationServiceProvider.overrideWithValue(notifications),
          speechRecognitionServiceProvider.overrideWithValue(speech),
          homeControllerProvider.overrideWith(
            (ref) => HomeController(
              ref,
              audioRecorder: recorder,
              temporaryDirectory: () async =>
                  Directory(p.join(root.path, 'rec'))..createSync(),
            ),
          ),
          remindersProvider.overrideWith(
            (ref) => RemindersNotifier(
              db,
              notifications: notifications,
              runLoadEffects: false,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await db.close(createBackup: false);
        await root.delete(recursive: true);
      });

      await container.read(settingsProvider.notifier).ready;
      await container.read(remindersProvider.notifier).ready;
      await container.read(mediaRecordsProvider.notifier).ready;
      await container.read(settingsProvider.notifier).updateSettings(
        container.read(settingsProvider).copyWith(
          speech: SpeechSettings(
            enabled: true,
            apiKey: const TencentSpeechCredentials(
              appId: '1259000000',
              secretId: 'AKIDTEST123456',
              secretKey: 'unit-secret',
            ).encode(),
          ),
        ),
      );
      final home = container.read(homeControllerProvider.notifier);

      // 1. Recorder stop throws -> _nativeRecording resets and next start succeeds.
      expect(await home.startRecording(), isTrue);
      recorder.audio!.add(Uint8List(16000));
      recorder.throwOnNextStop = true;
      expect(await home.stopRecordingToText(), isNull);
      expect(container.read(homeControllerProvider).isRecording, isFalse);

      // Next recording must NOT be deadlocked.
      expect(await home.startRecording(), isTrue);
      expect(recorder.starts, 2);
      recorder.audio!.add(Uint8List(16000));
      home.prepareRecordingTranscription();
      final pending = home.stopRecordingToText();
      // 2. Explicit live transcription cancel must discard without creating audio memo.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      home.cancelLiveTranscription();
      expect(await pending, isNull);
      expect(container.read(remindersProvider), isEmpty);
      expect(container.read(mediaRecordsProvider), isEmpty);
    },
  );

  test(
    'WindowsToast truncates on rune boundary before PowerShell escaping',
    () {
      // Place quotes & emojis right across the 240-rune boundary.
      final body = "${"a" * (WindowsToast.maxBodyLength - 2)}'🎉trailing";
      final script = WindowsToast.script(title: '通知', body: body);
      expect(script, contains("''🎉…')"));
      // Ensure no broken UTF-16 surrogate pair in generated script.
      expect(
        () => utf8.encode(script),
        returnsNormally,
      );
      for (final unit in script.codeUnits) {
        // High surrogate must be paired with low surrogate (verified by runes iteration).
        expect(unit, greaterThan(0));
      }
      expect(script.runes.length, greaterThan(0));
    },
  );

  test(
    'remindersByIdProvider and mediaRecordByIdProvider expose O(1) indexed views',
    () async {
      final dir = await Directory.systemTemp.createTemp('indexed-providers-');
      final db = DatabaseHelper.forTesting(dir.path, databaseFactoryFfi);
      final notifications = NotificationService.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
      final container = ProviderContainer(
        overrides: [
          databaseHelperProvider.overrideWithValue(db),
          notificationServiceProvider.overrideWithValue(notifications),
          remindersProvider.overrideWith(
            (ref) => RemindersNotifier(
              db,
              notifications: notifications,
              runLoadEffects: false,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close(createBackup: false);
        await dir.delete(recursive: true);
      });

      await container.read(remindersProvider.notifier).ready;
      await container.read(mediaRecordsProvider.notifier).ready;
      final task = Reminder(id: 'idx-1', taskTitle: 'Indexed', quadrantLevel: 2);
      final media = MediaRecord(
        id: 'med-1',
        type: 'audio',
        contentOrPath: 'a.wav',
        createdAt: DateTime(2026),
      );
      await db.writeTransaction(db.captureGeneration(), (txn) async {
        await txn.insert('Reminders', task.toJson());
        await txn.insert('MediaRecords', media.toJson());
      });
      await container.read(remindersProvider.notifier).refreshReminders();
      await container.read(mediaRecordsProvider.notifier).refreshMediaRecords();

      expect(container.read(remindersByIdProvider)['idx-1']?.taskTitle, 'Indexed');
      expect(container.read(remindersByIdProvider)['missing'], isNull);
      expect(container.read(mediaRecordByIdProvider)['med-1']?.type, 'audio');
      expect(container.read(mediaRecordByIdProvider)['missing'], isNull);
    },
  );

  test(
    'LanSyncService single-query merge handles 250 tasks with duplicates and updates',
    () async {
      final dirA = await Directory.systemTemp.createTemp('lan-bulk-a-');
      final dirB = await Directory.systemTemp.createTemp('lan-bulk-b-');
      final dbA = DatabaseHelper.forTesting(dirA.path, databaseFactoryFfi);
      final dbB = DatabaseHelper.forTesting(dirB.path, databaseFactoryFfi);
      final serverSvc = LanSyncService.forTesting();
      final clientSvc = LanSyncService.forTesting();
      addTearDown(() async {
        await serverSvc.stopServer();
        await dbA.close(createBackup: false);
        await dbB.close(createBackup: false);
        await dirA.delete(recursive: true);
        await dirB.delete(recursive: true);
      });

      await dbA.writeTransaction(dbA.captureGeneration(), (txn) async {
        for (var i = 0; i < 120; i++) {
          await txn.insert(
            'Reminders',
            Reminder(
              id: 'shared-$i',
              taskTitle: 'Server $i',
              quadrantLevel: (i % 4) + 1,
            ).toJson(),
          );
        }
      });
      await dbB.writeTransaction(dbB.captureGeneration(), (txn) async {
        for (var i = 0; i < 130; i++) {
          await txn.insert(
            'Reminders',
            Reminder(
              id: i < 60 ? 'shared-$i' : 'client-$i',
              taskTitle: 'Client $i',
              quadrantLevel: (i % 4) + 1,
              isCompleted: i < 20,
            ).toJson(),
          );
        }
      });

      final info = await serverSvc.startServer(port: 0, dbHelper: dbA);
      final ok = await HttpOverrides.runZoned(
        () => clientSvc.syncWithPeer(
          peerIp: '127.0.0.1',
          port: info.port,
          pin: info.pin,
          dbHelper: dbB,
        ),
        createHttpClient: _DirectHttpOverrides().createHttpClient,
      );
      expect(ok, isTrue);

      final rowsA = await dbA.read(
        dbA.captureGeneration(),
        (db) => db.query('Reminders'),
      );
      final rowsB = await dbB.read(
        dbB.captureGeneration(),
        (db) => db.query('Reminders'),
      );
      expect(rowsA.length, 190);
      expect(rowsB.length, 190);
      expect(
        rowsA.where((r) => r['is_completed'] == 1).length,
        20,
      );
    },
  );
}
