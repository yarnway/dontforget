import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late DatabaseHelper helper;
  late Database database;
  RemindersNotifier? notifier;

  Reminder task(String id, {DateTime? triggerTime, String? title}) => Reminder(
    id: id,
    taskTitle: title ?? id,
    quadrantLevel: 2,
    triggerTime: triggerTime,
  );

  Future<RemindersNotifier> loadedNotifier() async {
    final result = notifier = RemindersNotifier(helper);
    await result.ready;
    return result;
  }

  Future<Reminder> stored(String id) async => Reminder.fromJson(
    (await database.query(
      'Reminders',
      where: 'id = ?',
      whereArgs: [id],
    )).single,
  );

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('reminder-operations-');
    helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    database = await helper.database;
    notifier = null;
  });

  tearDown(() async {
    notifier?.dispose();
    await helper.close();
    await directory.delete(recursive: true);
  });

  test(
    'link requested during startup waits for both persisted tasks',
    () async {
      await database.insert('Reminders', task('alpha').toJson());
      await database.insert('Reminders', task('beta').toJson());
      final current = notifier = RemindersNotifier(helper);
      await current.linkTwoTasks('alpha', 'beta');
      expect(current.state[0].linkedTaskIds, ['beta']);
      expect(current.state[1].linkedTaskIds, ['alpha']);
      expect((await stored('alpha')).linkedTaskIds, ['beta']);
      expect((await stored('beta')).linkedTaskIds, ['alpha']);
    },
  );

  test('startup and concurrent additions retain all persisted tasks', () async {
    await database.insert('Reminders', task('alpha').toJson());
    final current = notifier = RemindersNotifier(helper);
    await Future.wait([
      current.addReminder(task('beta')),
      current.addReminder(task('gamma')),
    ]);
    expect(current.state.map((item) => item.id), ['alpha', 'beta', 'gamma']);
    expect(await database.query('Reminders'), hasLength(3));
  });

  test('queued edits preserve changes to different fields', () async {
    final current = await loadedNotifier();
    final original = task('alpha');
    await current.addReminder(original);
    await Future.wait([
      current.updateReminder(original.copyWith(taskTitle: 'Edited title')),
      current.updateReminder(original.copyWith(taskSummary: 'Edited summary')),
    ]);
    expect(current.state.single.taskTitle, 'Edited title');
    expect(current.state.single.taskSummary, 'Edited summary');
    final saved = await stored('alpha');
    expect(saved.taskTitle, 'Edited title');
    expect(saved.taskSummary, 'Edited summary');
  });

  test(
    'delete, scan, edit and add keep their call order without lost data',
    () async {
      final current = await loadedNotifier();
      final due = DateTime.now().add(const Duration(hours: 2));
      final alpha = task('alpha', triggerTime: due);
      final beta = task('beta', triggerTime: due);
      await current.addReminder(alpha);
      await current.addReminder(beta);
      final deleted = current.deleteReminder('alpha');
      final scan = current.scanAndApplyDynamicUrgency();
      final edited = current.updateReminder(
        beta.copyWith(taskTitle: 'Edited beta'),
      );
      final added = current.addReminder(task('gamma'));
      await Future.wait([deleted, edited, added]);
      expect((await scan).changed, 1);
      expect(current.state.map((item) => item.id), ['beta', 'gamma']);
      final promoted = current.state.first;
      expect(promoted.taskTitle, 'Edited beta');
      expect(promoted.quadrantLevel, 1);
      expect(promoted.isDynamicallyPromoted, isTrue);
      expect((await stored('beta')).toJson(), promoted.toJson());
      expect(
        await database.query(
          'Reminders',
          where: 'id = ?',
          whereArgs: ['alpha'],
        ),
        isEmpty,
      );
    },
  );

  test('failed promotion rolls back every row and the queue can retry', () async {
    final current = await loadedNotifier();
    final due = DateTime.now().add(const Duration(hours: 2));
    await current.addReminder(task('alpha', triggerTime: due));
    await current.addReminder(task('beta', triggerTime: due));
    final before = current.state;
    await database.execute(
      "CREATE TRIGGER reject_promotion BEFORE UPDATE ON Reminders WHEN NEW.id = 'beta' "
      "BEGIN SELECT RAISE(ABORT, 'promotion failure'); END",
    );
    await expectLater(
      current.scanAndApplyDynamicUrgency(),
      throwsA(isA<DatabaseException>()),
    );
    expect(current.state, same(before));
    expect((await stored('alpha')).quadrantLevel, 2);
    expect((await stored('beta')).quadrantLevel, 2);
    await database.execute('DROP TRIGGER reject_promotion');
    expect((await current.scanAndApplyDynamicUrgency()).changed, 2);
    expect(current.state.every((item) => item.quadrantLevel == 1), isTrue);
  });

  test(
    'automatic links and insertion roll back together on a write failure',
    () async {
      final current = await loadedNotifier();
      await current.addReminder(
        task('alpha', title: 'Shared project planning'),
      );
      final before = current.state;
      await database.execute(
        "CREATE TRIGGER reject_link BEFORE UPDATE ON Reminders WHEN NEW.id = 'alpha' "
        "BEGIN SELECT RAISE(ABORT, 'link failure'); END",
      );
      final added = task('beta', title: 'Shared project planning');
      await expectLater(
        current.addReminder(added),
        throwsA(isA<DatabaseException>()),
      );
      expect(current.state, same(before));
      expect((await stored('alpha')).linkedTaskIds, isEmpty);
      expect(await database.query('Reminders'), hasLength(1));
      await database.execute('DROP TRIGGER reject_link');
      await current.addReminder(added);
      expect((await stored('alpha')).linkedTaskIds, ['beta']);
      expect((await stored('beta')).linkedTaskIds, ['alpha']);
    },
  );

  test(
    'duplicate insertion does not overwrite existing content or links',
    () async {
      final current = await loadedNotifier();
      await current.addReminder(task('alpha'));
      await current.addReminder(task('beta', title: 'Shared project planning'));
      final before = current.state;
      await expectLater(
        current.addReminder(task('alpha', title: 'Shared project planning')),
        throwsA(isA<DatabaseException>()),
      );
      expect(current.state, same(before));
      expect((await stored('alpha')).taskTitle, 'alpha');
      expect((await stored('beta')).linkedTaskIds, isEmpty);
    },
  );

  test('link and unlink failures never leave a one-sided relationship', () async {
    final current = await loadedNotifier();
    await current.addReminder(task('alpha'));
    await current.addReminder(task('beta'));
    Future<void> rejectBeta() => database.execute(
      "CREATE TRIGGER reject_beta BEFORE UPDATE ON Reminders WHEN NEW.id = 'beta' "
      "BEGIN SELECT RAISE(ABORT, 'second endpoint failure'); END",
    );
    await rejectBeta();
    final unlinked = current.state;
    await expectLater(
      current.linkTwoTasks('alpha', 'beta'),
      throwsA(isA<DatabaseException>()),
    );
    expect(current.state, same(unlinked));
    expect((await stored('alpha')).linkedTaskIds, isEmpty);
    expect((await stored('beta')).linkedTaskIds, isEmpty);
    await database.execute('DROP TRIGGER reject_beta');
    await current.linkTwoTasks('alpha', 'beta');
    final linked = current.state;
    await rejectBeta();
    await expectLater(
      current.unlinkTwoTasks('alpha', 'beta'),
      throwsA(isA<DatabaseException>()),
    );
    expect(current.state, same(linked));
    expect((await stored('alpha')).linkedTaskIds, ['beta']);
    expect((await stored('beta')).linkedTaskIds, ['alpha']);
    await database.execute('DROP TRIGGER reject_beta');
    await current.unlinkTwoTasks('alpha', 'beta');
    expect(current.state.every((item) => item.linkedTaskIds.isEmpty), isTrue);
  });

  test('a failed refresh retains the last successfully loaded list', () async {
    final current = await loadedNotifier();
    await current.addReminder(task('alpha'));
    final before = current.state;
    await database.execute(
      'ALTER TABLE Reminders RENAME TO UnavailableReminders',
    );
    try {
      await current.refreshReminders();
      expect(current.state, same(before));
    } finally {
      await database.execute(
        'ALTER TABLE UnavailableReminders RENAME TO Reminders',
      );
    }
    await current.addReminder(task('beta'));
    expect(current.state.map((item) => item.id), ['alpha', 'beta']);
  });
}
