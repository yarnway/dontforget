import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/agent_models.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/multi_agent_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Gate {
  _Gate() {
    addTearDown(() {
      if (!release.isCompleted) {
        release.complete();
      }
    });
  }
  final started = Completer<void>();
  final release = Completer<void>();

  Future<void> pause() async {
    started.complete();
    await release.future;
  }
}

class _DelayedDatabase extends DatabaseHelper {
  _DelayedDatabase(String directory)
    : super.forTesting(directory, databaseFactoryFfi);

  _Gate? nextRead;
  _Gate? nextWrite;

  @override
  Future<T> read<T>(
    DataGeneration generation,
    Future<T> Function(DatabaseExecutor) operation,
  ) async {
    final gate = nextRead;
    nextRead = null;
    final result = await super.read(generation, operation);
    // Models a completed read whose consumer has not yet received its result.
    await gate?.pause();
    return result;
  }

  @override
  Future<T> writeTransaction<T>(
    DataGeneration generation,
    Future<T> Function(Transaction) operation,
  ) {
    final gate = nextWrite;
    nextWrite = null;
    return super.writeTransaction(generation, (transaction) async {
      final result = await operation(transaction);
      await gate?.pause();
      return result;
    });
  }
}

class _Notifications implements NotificationService {
  final scheduled = <String>[];
  _Gate? gate;

  @override
  Future<void> scheduleReminder(Reminder reminder) async {
    scheduled.add(reminder.id);
    await gate?.pause();
  }

  @override
  Future<void> cancelReminder(String id) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedLlm extends LLMService {
  final started = Completer<void>();
  final result = Completer<List<Reminder>>();

  Future<List<Reminder>> _extract() {
    if (!started.isCompleted) {
      started.complete();
    }
    return result.future;
  }

  @override
  Future<List<Reminder>> extractTasks(String text, AppSettings settings) =>
      _extract();

  @override
  Future<List<Reminder>> extractTasksFromImage(
    String image,
    AppSettings settings,
  ) => _extract();

  @override
  Future<List<Reminder>> extractTasksFromFile(
    String name,
    String content,
    AppSettings settings,
  ) => _extract();

  @override
  Future<List<Reminder>> extractTasksFromVideo(
    String name,
    AppSettings settings,
  ) => _extract();

  @override
  String formatErrorMessage(dynamic error) => 'Synthetic model error';
}

class _DelayedAgent extends MultiAgentService {
  final started = Completer<void>();
  final result = Completer<MultiAgentExecutionResult>();

  @override
  Future<MultiAgentExecutionResult> executePipeline(
    String userInput, {
    AppSettings? settings,
    List<Reminder>? existingTasks,
    String language = 'zh',
  }) {
    started.complete();
    return result.future;
  }
}

final class _PickedFile extends PlatformFile {
  _PickedFile(this.path);
  @override
  final String path;
  @override
  String get name => 'fixture.txt';
  @override
  Uri get uri => Uri.file(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recorderChannel = MethodChannel('com.llfbandit.record/messages');
  late Directory directory;
  late _DelayedDatabase database;
  late _Notifications notifications;
  ProviderContainer? container;
  final disposable = <void Function()>[];

  Reminder task(String id) => Reminder(id: id, taskTitle: id, quadrantLevel: 2);
  Matcher getRejected() => isA<DatabaseAccessException>().having(
    (error) => error.code,
    'generation rejection',
    anyOf(DatabaseAccessError.maintenance, DatabaseAccessError.staleGeneration),
  );

  Future<List<Map<String, Object?>>> rows(String table) =>
      database.read(database.captureGeneration(), (db) => db.query(table));

  Future<void> idle(HomeController controller) async {
    if (controller.state.pendingTasksCount == 0) {
      return;
    }
    final complete = Completer<void>();
    final stop = controller.addListener((state) {
      if (state.pendingTasksCount == 0 && !complete.isCompleted) {
        complete.complete();
      }
    }, fireImmediately: false);
    try {
      await complete.future.timeout(const Duration(seconds: 5));
    } finally {
      stop();
    }
  }

  Future<HomeController> controller({
    _DelayedLlm? llm,
    _DelayedAgent? agent,
    Future<XFile?> Function(ImageSource)? pickImage,
    Future<XFile?> Function()? pickVideo,
    Future<PlatformFile?> Function()? pickFile,
    Future<String> Function(String)? importFile,
  }) async {
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        if (llm != null) llmServiceProvider.overrideWithValue(llm),
        if (agent != null) multiAgentServiceProvider.overrideWithValue(agent),
        homeControllerProvider.overrideWith(
          (ref) => HomeController(
            ref,
            pickImage: pickImage,
            pickVideo: pickVideo,
            pickFile: pickFile,
            importFile: importFile,
          ),
        ),
      ],
    );
    await container!.read(settingsProvider.notifier).ready;
    await container!
        .read(settingsProvider.notifier)
        .updateSettings(
          AppSettings.defaults().copyWith(
            apiKey: llm == null ? '' : 'synthetic-only',
          ),
        );
    await container!.read(remindersProvider.notifier).ready;
    await container!.read(mediaRecordsProvider.notifier).ready;
    return container!.read(homeControllerProvider.notifier);
  }

  setUp(() async {
    // No recording is started; prevent native calls when the controller disposes.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, (_) async => null);
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('generation-test-');
    database = _DelayedDatabase(directory.path);
    notifications = _Notifications();
    container = null;
    disposable.clear();
  });

  tearDown(() async {
    container?.dispose();
    for (final dispose in disposable.reversed) {
      dispose();
    }
    await database.close();
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recorderChannel, null);
  });

  test(
    'settings load and save waiting for ready keep their initial generation',
    () async {
      await database.writeTransaction(
        database.captureGeneration(),
        (txn) => txn.update(
          'Settings',
          {'model_name': 'old-model'},
          where: 'id = ?',
          whereArgs: ['default'],
        ),
      );
      final gate = database.nextRead = _Gate();
      final settings = SettingsNotifier(database);
      disposable.add(settings.dispose);
      final loaded = expectLater(settings.ready, throwsA(getRejected()));
      final saved = expectLater(
        settings.updateSettings(
          AppSettings.defaults().copyWith(modelName: 'queued-old-model'),
        ),
        throwsA(getRejected()),
      );
      await gate.started.future;
      final maintenance = await database.beginMaintenance();
      await maintenance.resume();
      await database.writeTransaction(
        database.captureGeneration(),
        (txn) => txn.update(
          'Settings',
          {'model_name': 'restored-model'},
          where: 'id = ?',
          whereArgs: ['default'],
        ),
      );
      gate.release.complete();
      await Future.wait([loaded, saved]);
      expect(settings.state.modelName, AppSettings.defaults().modelName);
      expect((await rows('Settings')).single['model_name'], 'restored-model');
      final fresh = SettingsNotifier(database);
      disposable.add(fresh.dispose);
      await fresh.ready;
      expect(fresh.state.modelName, 'restored-model');
    },
  );

  test(
    'late reminder load cannot publish old rows or schedule notifications',
    () async {
      final old = task(
        'old',
      ).copyWith(triggerTime: DateTime.now().add(const Duration(days: 1)));
      await database.writeTransaction(
        database.captureGeneration(),
        (txn) => txn.insert('Reminders', old.toJson()),
      );
      final gate = database.nextRead = _Gate();
      final reminders = RemindersNotifier(
        database,
        notifications: notifications,
      );
      disposable.add(reminders.dispose);
      final rejected = expectLater(reminders.ready, throwsA(getRejected()));
      await gate.started.future;
      final maintenance = await database.beginMaintenance();
      await maintenance.resume();
      gate.release.complete();
      await rejected;
      expect(reminders.state, isEmpty);
      expect(notifications.scheduled, isEmpty);
    },
  );

  test(
    'late media load cannot publish old records or admit a pending addition',
    () async {
      await database.writeTransaction(
        database.captureGeneration(),
        (txn) => txn.insert(
          'MediaRecords',
          MediaRecord(
            id: 'old',
            type: 'file',
            contentOrPath: 'synthetic',
            createdAt: DateTime.utc(2026),
          ).toJson(),
        ),
      );
      final gate = database.nextRead = _Gate();
      final media = MediaRecordsNotifier(database);
      disposable.add(media.dispose);
      final loaded = expectLater(media.ready, throwsA(getRejected()));
      final saved = expectLater(
        media.addRecord(
          MediaRecord(
            id: 'queued',
            type: 'file',
            contentOrPath: 'synthetic',
            createdAt: DateTime.utc(2026),
          ),
        ),
        throwsA(getRejected()),
      );
      await gate.started.future;
      final maintenance = await database.beginMaintenance();
      await maintenance.resume();
      gate.release.complete();
      await Future.wait([loaded, saved]);
      expect(media.state, isEmpty);
      expect((await rows('MediaRecords')).map((row) => row['id']), ['old']);
    },
  );

  test(
    'queued reminder writes do not obtain a new ticket after maintenance',
    () async {
      final reminders = RemindersNotifier(
        database,
        notifications: notifications,
      );
      disposable.add(reminders.dispose);
      await reminders.ready;
      final gate = database.nextWrite = _Gate();
      final first = expectLater(
        reminders.addReminder(task('admitted')),
        throwsA(getRejected()),
      );
      await gate.started.future;
      final queued = expectLater(
        reminders.addReminder(task('queued-old')),
        throwsA(getRejected()),
      );
      var drained = false;
      final pendingMaintenance = database.beginMaintenance().then((lease) {
        drained = true;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      gate.release.complete();
      final maintenance = await pendingMaintenance;
      await Future.wait([first, queued]);
      expect(reminders.state, isEmpty);
      await maintenance.resume();
      expect((await rows('Reminders')).map((row) => row['id']), ['admitted']);
      await reminders.refreshReminders();
      await reminders.addReminder(task('new-generation'));
      expect(reminders.state.map((row) => row.id), [
        'admitted',
        'new-generation',
      ]);
    },
  );

  test(
    'explicit stale tickets cannot add update delete or save media',
    () async {
      final reminders = RemindersNotifier(
        database,
        notifications: notifications,
      );
      final media = MediaRecordsNotifier(database);
      disposable.addAll([reminders.dispose, media.dispose]);
      await Future.wait([reminders.ready, media.ready]);
      await reminders.addReminder(task('existing'));
      final generation = database.captureGeneration();
      final maintenance = await database.beginMaintenance();
      await maintenance.resume();
      for (final operation in [
        () => reminders.addReminderForGeneration(task('stale'), generation),
        () => reminders.updateReminderForGeneration(
          task('existing').copyWith(taskTitle: 'stale edit'),
          generation,
        ),
        () => reminders.deleteReminderForGeneration('existing', generation),
        () => media.addRecordForGeneration(
          MediaRecord(
            id: 'stale',
            type: 'file',
            contentOrPath: 'synthetic',
            createdAt: DateTime.utc(2026),
          ),
          generation,
        ),
      ]) {
        await expectLater(operation(), throwsA(getRejected()));
      }
      expect((await rows('Reminders')).single['task_title'], 'existing');
      expect(await rows('MediaRecords'), isEmpty);
    },
  );

  test(
    'old reminder state cannot acquire a fresh ticket until explicitly refreshed',
    () async {
      final reminders = RemindersNotifier(
        database,
        notifications: notifications,
      );
      disposable.add(reminders.dispose);
      await reminders.ready;
      await reminders.addReminder(
        task('same-id').copyWith(taskSummary: 'Old summary'),
      );
      final oldUiTask = reminders.state.single;
      final maintenance = await database.beginMaintenance();
      await maintenance.resume();
      await database.writeTransaction(
        database.captureGeneration(),
        (txn) => txn.update(
          'Reminders',
          {'task_title': 'Restored title', 'task_summary': 'Restored summary'},
          where: 'id = ?',
          whereArgs: ['same-id'],
        ),
      );
      await expectLater(
        reminders.updateReminder(oldUiTask.copyWith(taskTitle: 'Old UI edit')),
        throwsA(getRejected()),
      );
      await expectLater(
        reminders.deleteReminder('same-id'),
        throwsA(getRejected()),
      );
      await expectLater(
        reminders.addReminder(task('old-ui-add')),
        throwsA(getRejected()),
      );
      expect((await rows('Reminders')).single['task_title'], 'Restored title');
      expect(reminders.state.single.taskSummary, 'Old summary');
      await reminders.refreshReminders();
      expect(reminders.state.single.taskSummary, 'Restored summary');
      await reminders.updateReminder(
        reminders.state.single.copyWith(taskTitle: 'Current edit'),
      );
      final saved = (await rows('Reminders')).single;
      expect(saved['task_title'], 'Current edit');
      expect(saved['task_summary'], 'Restored summary');
    },
  );

  test(
    'old settings state cannot overwrite restored settings with a fresh ticket',
    () async {
      final settings = SettingsNotifier(database);
      disposable.add(settings.dispose);
      await settings.ready;
      final oldState = settings.state;
      final maintenance = await database.beginMaintenance();
      await maintenance.resume();
      await database.writeTransaction(
        database.captureGeneration(),
        (txn) => txn.update(
          'Settings',
          {'model_name': 'Restored model'},
          where: 'id = ?',
          whereArgs: ['default'],
        ),
      );
      await expectLater(
        settings.updateSettings(oldState.copyWith(apiKey: 'Old UI key')),
        throwsA(getRejected()),
      );
      expect((await rows('Settings')).single['model_name'], 'Restored model');
      final reloaded = SettingsNotifier(database);
      disposable.add(reloaded.dispose);
      await reloaded.ready;
      await reloaded.updateSettings(
        reloaded.state.copyWith(apiKey: 'Current key'),
      );
      expect((await rows('Settings')).single['model_name'], 'Restored model');
    },
  );

  test(
    'old media state cannot append under a fresh generation without reloading',
    () async {
      final media = MediaRecordsNotifier(database);
      disposable.add(media.dispose);
      await media.ready;
      final maintenance = await database.beginMaintenance();
      await maintenance.resume();
      final record = MediaRecord(
        id: 'new',
        type: 'file',
        contentOrPath: 'synthetic',
        createdAt: DateTime.utc(2026),
      );
      await expectLater(media.addRecord(record), throwsA(getRejected()));
      expect(await rows('MediaRecords'), isEmpty);
      final reloaded = MediaRecordsNotifier(database);
      disposable.add(reloaded.dispose);
      await reloaded.ready;
      await reloaded.addRecord(record);
      expect((await rows('MediaRecords')).single['id'], 'new');
    },
  );

  for (final fail in [false, true]) {
    test(
      'late text AI ${fail ? 'failure cannot fallback' : 'success cannot save'} after maintenance',
      () async {
        final llm = _DelayedLlm();
        final home = await controller(llm: llm);
        await home.processText('Old input');
        await llm.started.future;
        final maintenance = await database.beginMaintenance();
        await maintenance.resume();
        if (fail) {
          llm.result.completeError(StateError('synthetic network failure'));
        } else {
          llm.result.complete([task('late-result')]);
        }
        await idle(home);
        expect(await rows('Reminders'), isEmpty);
        expect(notifications.scheduled, isEmpty);
        expect(home.state.error, isNull);
      },
    );
  }

  test(
    'late multi-agent result cannot save or notify and remains rejected',
    () async {
      final agent = _DelayedAgent();
      final home = await controller(agent: agent);
      final rejected = expectLater(
        home.processWithMultiAgent('Old goal'),
        throwsA(getRejected()),
      );
      await agent.started.future;
      final maintenance = await database.beginMaintenance();
      await maintenance.resume();
      agent.result.complete(
        MultiAgentExecutionResult(
          originalInput: 'Old goal',
          macroGoalTitle: 'Old goal',
          overallPriorityQuadrant: 2,
          decomposedMilestones: [],
          scheduledTasks: [task('old-agent')],
          executionTrace: [],
        ),
      );
      await rejected;
      expect(await rows('Reminders'), isEmpty);
      expect(notifications.scheduled, isEmpty);
      expect(home.state.error, isNull);
    },
  );

  for (final kind in ['image', 'file', 'video']) {
    test(
      'late $kind picker result cannot import media into a new generation',
      () async {
        final selected = Completer<XFile?>();
        final selectedFile = Completer<PlatformFile?>();
        var imports = 0;
        final home = await controller(
          pickImage: (_) => selected.future,
          pickVideo: () => selected.future,
          pickFile: () => selectedFile.future,
          importFile: (path) async {
            imports++;
            return path;
          },
        );
        final pending = switch (kind) {
          'image' => home.processImage(),
          'file' => home.processFile(),
          _ => home.processVideo(),
        };
        final maintenance = await database.beginMaintenance();
        await maintenance.resume();
        if (kind == 'file') {
          selectedFile.complete(_PickedFile('${directory.path}/fixture.txt'));
        } else {
          selected.complete(XFile('${directory.path}/fixture.png'));
        }
        await pending;
        expect(imports, 0);
        expect(await rows('MediaRecords'), isEmpty);
        expect(await rows('Reminders'), isEmpty);
        expect(notifications.scheduled, isEmpty);
      },
    );
  }

  for (final kind in ['image', 'file', 'video']) {
    test(
      'late $kind model result cannot add reminders after maintenance',
      () async {
        final fixture = await File(
          '${directory.path}/fixture.txt',
        ).writeAsString('Synthetic metadata');
        final llm = _DelayedLlm();
        final home = await controller(
          llm: llm,
          pickImage: (_) async => XFile(fixture.path),
          pickVideo: () async => XFile(fixture.path),
          pickFile: () async => _PickedFile(fixture.path),
          importFile: (path) async => path,
        );
        switch (kind) {
          case 'image':
            await home.processImage();
          case 'file':
            await home.processFile();
          case 'video':
            await home.processVideo();
        }
        await llm.started.future;
        final maintenance = await database.beginMaintenance();
        await maintenance.resume();
        llm.result.complete([task('late-$kind')]);
        await idle(home);
        expect(await rows('Reminders'), isEmpty);
        expect(notifications.scheduled, isEmpty);
        expect(home.state.error, isNull);
      },
    );
  }

  test(
    'maintenance drains an admitted notification and blocks the next task',
    () async {
      final llm = _DelayedLlm();
      final home = await controller(llm: llm);
      final gate = notifications.gate = _Gate();
      await home.processText('Two tasks');
      await llm.started.future;
      llm.result.complete([task('first'), task('second')]);
      await gate.started.future;
      var drained = false;
      final pendingMaintenance = database.beginMaintenance().then((lease) {
        drained = true;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      gate.release.complete();
      final maintenance = await pendingMaintenance;
      await idle(home);
      await maintenance.resume();
      expect(notifications.scheduled, ['first']);
      expect((await rows('Reminders')).map((row) => row['id']), ['first']);
    },
  );

  test(
    'ordinary local text still saves without a model or notification',
    () async {
      final home = await controller();
      await home.processText('Local task');
      await idle(home);
      expect((await rows('Reminders')).single['task_title'], 'Local task');
      expect(notifications.scheduled, isEmpty);
    },
  );

  test('a disposed controller ignores a late model result', () async {
    final llm = _DelayedLlm();
    final home = await controller(llm: llm);
    await home.processText('Old disposed input');
    await llm.started.future;
    container!.dispose();
    container = null;
    llm.result.complete([task('disposed-result')]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await rows('Reminders'), isEmpty);
    expect(notifications.scheduled, isEmpty);
  });
}
