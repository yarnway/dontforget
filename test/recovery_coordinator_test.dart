import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/credential_reference.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/recovery_coordinator.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/recovery/runtime_gate.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Database extends DatabaseHelper {
  _Database(String directory) : super.forTesting(directory, databaseFactoryFfi);
  bool failApplicationReads = false;

  @override
  Future<T> read<T>(
    DataGeneration generation,
    Future<T> Function(DatabaseExecutor) operation,
  ) {
    if (failApplicationReads) {
      return Future.error(StateError('Synthetic provider read failure'));
    }
    return super.read(generation, operation);
  }
}

class _Notifications extends NotificationService {
  _Notifications()
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
  final rebuilds = <List<String>>[];
  final directSchedules = <String>[];
  int rebuildFailures = 0;

  @override
  Future<void> scheduleReminder(Reminder reminder) async {
    directSchedules.add(reminder.id);
    await super.scheduleReminder(reminder);
  }

  @override
  Future<void> resumeFromReminders(Iterable<Reminder> reminders) async {
    final tasks = reminders.toList();
    rebuilds.add(tasks.map((task) => task.id).toList());
    if (rebuildFailures > 0) {
      rebuildFailures--;
      throw StateError('Synthetic notification rebuild failure');
    }
    await super.resumeFromReminders(tasks);
  }
}

class _Lan extends LanSyncService {
  _Lan(this.events) : super.forTesting();
  final List<String> events;
  int resumes = 0;

  @override
  Future<void> pauseForRecovery() async {
    await super.pauseForRecovery();
    events.add('lan stopped');
  }

  @override
  void resumeAfterRecovery() {
    super.resumeAfterRecovery();
    resumes++;
  }
}

class _Engine extends DatabaseRecovery {
  _Engine(
    super.database, {
    required super.inspector,
    required super.notifications,
    super.checkpoint,
  });
  int restoreCalls = 0;

  @override
  Future<DatabaseRecoveryResult> restorePlan(RecoveryPlan plan) {
    restoreCalls++;
    return super.restorePlan(plan);
  }
}

class _Llm extends LLMService {
  final started = Completer<void>();
  final result = Completer<List<Reminder>>();
  bool disposed = false;

  @override
  Future<List<Reminder>> extractTasks(String text, AppSettings settings) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _Recorder implements AudioRecorder {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Database live;
  late File source;
  late BackupInspector inspector;
  late _Notifications notifications;
  late _Lan lan;
  late RuntimeRecoveryGate gate;
  late _Engine engine;
  late List<String> events;
  late List<_Llm> models;
  ProviderContainer? container;
  Future<void> Function(RecoveryCheckpoint)? atCheckpoint;
  late String mirrorHash;
  late String jsonHash;
  late String sourceHash;

  Future<String> hash(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();
  File liveFile(String name) => File(p.join(root.path, 'live', name));
  Reminder reminder(String prefix) => Reminder(
    id: '$prefix-task',
    taskTitle: '$prefix task',
    quadrantLevel: 2,
    triggerTime: DateTime.now().add(const Duration(days: 365)),
  );

  Future<void> seed(DatabaseHelper database, String prefix) async {
    await database.writeTransaction(database.captureGeneration(), (db) async {
      await db.update(
        'Settings',
        AppSettings.defaults()
            .copyWith(
              apiKey: '$prefix-test-key',
              baseUrl: 'https://$prefix.invalid/v1',
              modelName: '$prefix-model',
              language: prefix == 'old' ? 'zh' : 'en',
            )
            .toJson(),
      );
      await db.insert('Reminders', reminder(prefix).toJson());
      await db.insert(
        'MediaRecords',
        MediaRecord(
          id: '$prefix-media',
          type: 'text',
          contentOrPath: '$prefix text',
          createdAt: DateTime(2026, 1, 1),
        ).toJson(),
      );
    });
  }

  Future<RecoveryCoordinator> start({
    Future<XFile?> Function(ImageSource)? picker,
  }) async {
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(live),
        notificationServiceProvider.overrideWithValue(notifications),
        lanSyncServiceProvider.overrideWithValue(lan),
        runtimeRecoveryGateProvider.overrideWithValue(gate),
        databaseRecoveryProvider.overrideWithValue(engine),
        contextTriggerServiceProvider.overrideWithValue(
          ContextTriggerService.forTesting(),
        ),
        llmServiceProvider.overrideWith((ref) {
          final model = _Llm();
          models.add(model);
          ref.onDispose(model.dispose);
          return model;
        }),
        homeControllerProvider.overrideWith(
          (ref) => HomeController(
            ref,
            pickImage: picker,
            audioRecorder: _Recorder(),
          ),
        ),
      ],
    );
    await container!.read(settingsProvider.notifier).ready;
    await container!.read(mediaRecordsProvider.notifier).ready;
    await container!.read(remindersProvider.notifier).ready;
    container!.read(homeControllerProvider.notifier);
    container!.read(llmServiceProvider);
    await lan.startServer(port: 0, dbHelper: live);
    notifications.directSchedules.clear();
    return container!.read(recoveryCoordinatorProvider);
  }

  Future<RecoveryPlan> prepare(RecoveryCoordinator coordinator) async =>
      coordinator.prepare(source, await inspector.inspect(source));

  Future<void> expectState(String prefix) async {
    final settings = container!.read(settingsProvider);
    expect(settings.apiKey, '$prefix-test-key');
    expect(settings.modelName, '$prefix-model');
    expect(settings.language, prefix == 'old' ? 'zh' : 'en');
    expect(container!.read(mediaRecordsProvider).map((r) => r.id), [
      '$prefix-media',
    ]);
    expect(container!.read(remindersProvider).map((r) => r.id), [
      '$prefix-task',
    ]);
    final rows = await live.read(
      live.captureGeneration(),
      (db) => db.query('Reminders'),
    );
    expect(rows.map((row) => row['id']), ['$prefix-task']);
  }

  Future<void> backupsUnchanged() async {
    expect(await hash(liveFile('dont_forget_v3.mirror.db')), mirrorHash);
    expect(await hash(liveFile('ha_snapshot.json')), jsonHash);
    expect(await hash(source), sourceHash);
  }

  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('coordinator-recovery-test-');
    live = _Database(p.join(root.path, 'live'));
    await seed(live, 'old');
    await live.createMirrorBackup();
    mirrorHash = await hash(liveFile('dont_forget_v3.mirror.db'));
    jsonHash = await hash(liveFile('ha_snapshot.json'));
    final backup = DatabaseHelper.forTesting(
      p.join(root.path, 'source'),
      databaseFactoryFfi,
    );
    await seed(backup, 'new');
    await backup.close();
    source = File(p.join(root.path, 'source', 'ha_snapshot.json'));
    sourceHash = await hash(source);
    inspector = BackupInspector(databaseFactoryFfi, temporaryDirectory: root);
    notifications = _Notifications();
    events = [];
    models = [];
    lan = _Lan(events);
    gate = RuntimeRecoveryGate();
    atCheckpoint = null;
    engine = _Engine(
      live,
      inspector: inspector,
      notifications: notifications,
      checkpoint: (point) async {
        events.add(point.name);
        await atCheckpoint?.call(point);
      },
    );
  });

  tearDown(() async {
    container?.dispose();
    container = null;
    await lan.pauseForRecovery();
    await notifications.pauseForMaintenance();
    live.failApplicationReads = false;
    await live.close(createBackup: false);
    await root.delete(recursive: true);
  });

  test(
    'confirmed recovery drains producers and rebuilds fresh state exactly once',
    () async {
      final coordinator = await start();
      final oldSettings = container!.read(settingsProvider.notifier);
      final oldMedia = container!.read(mediaRecordsProvider.notifier);
      final oldReminders = container!.read(remindersProvider.notifier);
      final oldHome = container!.read(homeControllerProvider.notifier);
      final oldModel = models.single;
      final oldToken = gate.capture();
      final oldPin = lan.pin;
      final participant = Object();
      gate.register(participant, () async => events.add('producer stopped'));
      final plan = await prepare(coordinator);
      expect(gate.paused, isFalse);
      expect(lan.isRunning, isTrue);
      expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
      final phases = <RecoveryPhase>[];
      coordinator.addListener(() => phases.add(coordinator.state.phase));
      atCheckpoint = (point) async {
        if (point == RecoveryCheckpoint.candidateReady) {
          expect(events, containsAll(['producer stopped', 'lan stopped']));
          expect(gate.paused, isTrue);
          expect(lan.isRunning, isFalse);
          expect(oldModel.disposed, isTrue);
        }
      };
      await coordinator.restore(plan);
      expect(phases, [
        RecoveryPhase.quiescing,
        RecoveryPhase.restoring,
        RecoveryPhase.reloading,
        RecoveryPhase.succeeded,
      ]);
      expect(engine.restoreCalls, 1);
      expect(coordinator.state.rollbackDirectory, plan.rollbackDirectory);
      expect(coordinator.navigationEpoch, 1);
      expect(
        container!.read(settingsProvider.notifier),
        isNot(same(oldSettings)),
      );
      expect(
        container!.read(mediaRecordsProvider.notifier),
        isNot(same(oldMedia)),
      );
      expect(
        container!.read(remindersProvider.notifier),
        isNot(same(oldReminders)),
      );
      expect(
        container!.read(homeControllerProvider.notifier),
        isNot(same(oldHome)),
      );
      expect(notifications.rebuilds, [
        ['new-task'],
      ]);
      expect(notifications.directSchedules, isEmpty);
      expect(gate.paused, isFalse);
      expect(gate.isCurrent(oldToken), isFalse);
      expect(lan.isRunning, isFalse);
      expect(lan.resumes, 1);
      await expectState('new');
      await backupsUnchanged();
      final rollback = await inspector.inspect(
        File(p.join(plan.rollbackDirectory, 'rollback.db')),
      );
      expect(rollback.counts, {
        'settings': 1,
        'media_records': 1,
        'reminders': 1,
      });
      final rollbackDb = await databaseFactoryFfi.openDatabase(
        p.join(plan.rollbackDirectory, 'rollback.db'),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        expect(
          isCredentialReference(
            (await rollbackDb.query('Settings')).single['api_key'],
          ),
          isTrue,
        );
        final rollbackSettings = AppSettings.fromJson(
          (await rollbackDb.query('Settings')).single,
        );
        final secret = await live.credentialStore.read(rollbackSettings.apiKey);
        expect(jsonDecode(secret!)['api_key'], 'old-test-key');
        expect(
          rollbackSettings.aiProfiles.every((p) => p.settings.apiKey.isEmpty),
          isTrue,
        );
        expect(
          jsonEncode(await rollbackDb.query('Settings')),
          isNot(contains('old-test-key')),
        );
        expect((await rollbackDb.query('Reminders')).single['id'], 'old-task');
        expect(
          (await rollbackDb.query('MediaRecords')).single['id'],
          'old-media',
        );
      } finally {
        await rollbackDb.close();
      }
      expect(
        await File(p.join(plan.rollbackDirectory, 'completed.json')).exists(),
        isTrue,
      );
      expect(await liveFile(DatabaseRecovery.journalName).exists(), isFalse);
      coordinator.acknowledge();
      expect(coordinator.state.phase, RecoveryPhase.idle);
      expect(coordinator.navigationEpoch, 2);
      final restarted = await lan.startServer(port: 0, dbHelper: live);
      expect(restarted.pin, isNot(oldPin));
    },
  );

  test(
    'changed saved data rejects the confirmation and reloads its latest state',
    () async {
      final coordinator = await start();
      final oldNotifier = container!.read(remindersProvider.notifier);
      final plan = await prepare(coordinator);
      await live.writeTransaction(live.captureGeneration(), (db) async {
        await db.update('Reminders', {'task_title': 'Latest saved edit'});
      });
      await coordinator.restore(plan);
      expect(coordinator.state.phase, RecoveryPhase.notApplied);
      expect(
        container!.read(remindersProvider.notifier),
        isNot(same(oldNotifier)),
      );
      expect(
        container!.read(remindersProvider).single.taskTitle,
        'Latest saved edit',
      );
      await expectState('old');
      expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
      expect(notifications.rebuilds, [
        ['old-task'],
      ]);
      expect(gate.paused, isFalse);
      expect(lan.isRunning, isFalse);
      await backupsUnchanged();
      coordinator.acknowledge();
      await coordinator.restore(await prepare(coordinator));
      expect(coordinator.state.phase, RecoveryPhase.succeeded);
      await expectState('new');
    },
  );

  test(
    'failure before the durable decision rolls back and reloads old providers',
    () async {
      final coordinator = await start();
      final oldNotifier = container!.read(settingsProvider.notifier);
      final plan = await prepare(coordinator);
      atCheckpoint = (point) async {
        if (point == RecoveryCheckpoint.candidateOpened) {
          throw StateError('Synthetic failure before commit');
        }
      };
      await coordinator.restore(plan);
      expect(coordinator.state.phase, RecoveryPhase.rolledBack);
      expect(
        container!.read(settingsProvider.notifier),
        isNot(same(oldNotifier)),
      );
      await expectState('old');
      expect(notifications.rebuilds, [
        ['old-task'],
      ]);
      expect(notifications.directSchedules, isEmpty);
      expect(gate.paused, isFalse);
      expect(lan.isRunning, isFalse);
      expect(
        await File(p.join(plan.rollbackDirectory, 'rolled-back.json')).exists(),
        isTrue,
      );
      expect(await liveFile(DatabaseRecovery.journalName).exists(), isFalse);
      await backupsUnchanged();
    },
  );

  test(
    'committed notification failure blocks producers and retains its durable decision',
    () async {
      final coordinator = await start();
      final oldNotifier = container!.read(settingsProvider.notifier);
      final plan = await prepare(coordinator);
      notifications.rebuildFailures = 1;
      await coordinator.restore(plan);
      expect(coordinator.state.phase, RecoveryPhase.blocked);
      expect(container!.read(settingsProvider.notifier), same(oldNotifier));
      expect(gate.paused, isTrue);
      expect(lan.pausedForRecovery, isTrue);
      expect(lan.resumes, 0);
      expect(notifications.isPausedForMaintenance, isTrue);
      expect(notifications.rebuilds, [
        ['new-task'],
      ]);
      expect(
        () => live.captureGeneration(),
        throwsA(isA<DatabaseAccessException>()),
      );
      final journal =
          jsonDecode(
                await liveFile(DatabaseRecovery.journalName).readAsString(),
              )
              as Map;
      expect(journal['state'], 'committed');
      expect(journal['operationId'], plan.operationId);
      coordinator.acknowledge();
      expect(coordinator.state.phase, RecoveryPhase.blocked);
      await backupsUnchanged();
    },
  );

  test(
    'provider reload failure keeps runtime blocked even when the data commit succeeded',
    () async {
      final coordinator = await start();
      final plan = await prepare(coordinator);
      atCheckpoint = (point) async {
        if (point == RecoveryCheckpoint.committed) {
          live.failApplicationReads = true;
        }
      };
      await coordinator.restore(plan);
      expect(coordinator.state.phase, RecoveryPhase.blocked);
      expect(gate.paused, isTrue);
      expect(lan.pausedForRecovery, isTrue);
      expect(lan.resumes, 0);
      expect(notifications.isPausedForMaintenance, isTrue);
      expect(notifications.rebuilds, [
        ['new-task'],
      ]);
      expect(await liveFile(DatabaseRecovery.journalName).exists(), isFalse);
      expect(
        await File(p.join(plan.rollbackDirectory, 'completed.json')).exists(),
        isTrue,
      );
      live.failApplicationReads = false;
      final rows = await live.read(
        live.captureGeneration(),
        (db) => db.query('Reminders'),
      );
      expect(rows.single['id'], 'new-task');
      coordinator.acknowledge();
      expect(coordinator.state.phase, RecoveryPhase.blocked);
      await backupsUnchanged();
    },
  );

  test(
    'producer cleanup failure never invokes the replacement engine',
    () async {
      final coordinator = await start();
      final plan = await prepare(coordinator);
      final generation = live.captureGeneration();
      final oldNotifier = container!.read(settingsProvider.notifier);
      gate.register(
        Object(),
        () async => throw StateError('Synthetic producer cleanup failure'),
      );
      await coordinator.restore(plan);
      expect(coordinator.state.phase, RecoveryPhase.blocked);
      expect(engine.restoreCalls, 0);
      expect(live.isCurrent(generation), isTrue);
      expect(container!.read(settingsProvider.notifier), same(oldNotifier));
      expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
      expect(notifications.rebuilds, isEmpty);
      expect(gate.paused, isTrue);
      expect(lan.isRunning, isFalse);
      expect(events, contains('lan stopped'));
      await expectState('old');
      await backupsUnchanged();
    },
  );

  test(
    'a second restore cannot duplicate an operation while cleanup is pending',
    () async {
      final coordinator = await start();
      final plan = await prepare(coordinator);
      final entered = Completer<void>();
      final release = Completer<void>();
      gate.register(Object(), () async {
        entered.complete();
        await release.future;
      });
      final first = coordinator.restore(plan);
      await entered.future;
      try {
        await expectLater(coordinator.restore(plan), throwsStateError);
        expect(engine.restoreCalls, 0);
      } finally {
        release.complete();
      }
      await first;
      expect(engine.restoreCalls, 1);
      expect(coordinator.state.phase, RecoveryPhase.succeeded);
      expect(notifications.rebuilds, [
        ['new-task'],
      ]);
      await expectState('new');
    },
  );

  test(
    'late AI and picker results cannot populate the rebuilt workspace',
    () async {
      final selected = Completer<XFile?>();
      final coordinator = await start(picker: (_) => selected.future);
      final oldHome = container!.read(homeControllerProvider.notifier);
      final oldModel = models.single;
      await oldHome.processText('Old pending extraction');
      await oldModel.started.future;
      final picking = oldHome.processImage();
      final plan = await prepare(coordinator);
      await coordinator.restore(plan).timeout(const Duration(seconds: 5));
      expect(coordinator.state.phase, RecoveryPhase.succeeded);
      expect(oldModel.disposed, isTrue);
      oldModel.result.complete([reminder('late-old')]);
      selected.complete(XFile(p.join(root.path, 'old-missing-selection.jpg')));
      await picking;
      await Future<void>.delayed(Duration.zero);
      await expectState('new');
      final freshHome = container!.read(homeControllerProvider.notifier);
      expect(freshHome, isNot(same(oldHome)));
      expect(container!.read(homeControllerProvider).pendingTasksCount, 0);
      expect(container!.read(homeControllerProvider).error, isNull);
      expect(notifications.rebuilds, [
        ['new-task'],
      ]);
      expect(notifications.directSchedules, isEmpty);
      await backupsUnchanged();
    },
  );

  test(
    'SQLite confirmation also completes replacement and provider rebuilding',
    () async {
      source = File(p.join(root.path, 'source', 'dont_forget_v3.mirror.db'));
      sourceHash = await hash(source);
      final coordinator = await start();
      final plan = await prepare(coordinator);
      await coordinator.restore(plan);
      expect(coordinator.state.phase, RecoveryPhase.succeeded);
      expect(coordinator.state.rollbackDirectory, plan.rollbackDirectory);
      expect(notifications.rebuilds, [
        ['new-task'],
      ]);
      expect(notifications.directSchedules, isEmpty);
      await expectState('new');
      await backupsUnchanged();
    },
  );

  test(
    'notification delivery freezes before asynchronous producer cleanup finishes',
    () async {
      final coordinator = await start();
      final plan = await prepare(coordinator);
      final entered = Completer<void>();
      final release = Completer<void>();
      final delivered = <String>[];
      final subscription = notifications.onReminderDue.listen(
        (task) => delivered.add(task.id),
      );
      gate.register(Object(), () async {
        entered.complete();
        await release.future;
      });
      final restoring = coordinator.restore(plan);
      await entered.future;
      try {
        expect(coordinator.state.phase, RecoveryPhase.quiescing);
        expect(engine.restoreCalls, 0);
        expect(notifications.isPausedForMaintenance, isTrue);
        await notifications.fireReminderNow(reminder('old'));
        await Future<void>.delayed(Duration.zero);
        expect(delivered, isEmpty);
      } finally {
        release.complete();
        await restoring;
        await subscription.cancel();
      }
      expect(coordinator.state.phase, RecoveryPhase.succeeded);
      expect(notifications.rebuilds, [
        ['new-task'],
      ]);
      expect(notifications.directSchedules, isEmpty);
    },
  );

  test(
    'early stale-plan rejection rebuilds paused notifications from current data once',
    () async {
      final coordinator = await start();
      final plan = await prepare(coordinator);
      // Simulate another completed maintenance epoch before the user confirms.
      final otherLease = await live.beginMaintenance();
      await otherLease.resume();
      final beforeRecovery = live.captureGeneration();
      await coordinator.restore(plan);
      expect(coordinator.state.phase, RecoveryPhase.notApplied);
      expect(engine.restoreCalls, 1);
      expect(events, isNot(contains(RecoveryCheckpoint.candidateReady.name)));
      expect(await Directory(plan.rollbackDirectory).exists(), isFalse);
      expect(notifications.rebuilds, [
        ['old-task'],
      ]);
      expect(notifications.directSchedules, isEmpty);
      expect(notifications.isPausedForMaintenance, isFalse);
      expect(gate.paused, isFalse);
      expect(lan.isRunning, isFalse);
      expect(live.isCurrent(beforeRecovery), isFalse);
      await expectState('old');
      await backupsUnchanged();
      coordinator.acknowledge();
      await coordinator.restore(await prepare(coordinator));
      expect(coordinator.state.phase, RecoveryPhase.succeeded);
      await expectState('new');
    },
  );
}
