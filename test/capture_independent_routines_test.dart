import 'dart:convert';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/models/ordinary_series.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/services/quick_reminder_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'support/offline_management_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime(2030, 1, 7, 6), due = DateTime(2030, 1, 7, 8);
  late OfflineManagementHarness h;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
    h = OfflineManagementHarness();
    await h.create();
  });
  tearDown(() async {
    await h.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          null,
        );
  });
  Reminder raw({String source = '每天早上8点喝水', String? media}) => Reminder(
    id: 'capture',
    taskTitle: source,
    sourceText: source,
    quadrantLevel: 2,
    createdAt: at,
    capturePending: true,
    triggerTime: due,
    eventTime: due,
    recordId: media,
  );
  Reminder result({String rule = 'daily', RepeatWindow? repeat}) => Reminder(
    id: 'model',
    taskTitle: '喝水',
    quadrantLevel: 2,
    triggerTime: due.subtract(const Duration(minutes: 10)),
    eventTime: due,
    isRecurring: true,
    recurrenceRule: rule,
    detailsJson: TaskDetails(
      repeat: repeat,
      data: const {
        'capture_requires_review': false,
        'capture_evidence': '每天早上8点喝水',
      },
    ).encode(),
  );
  test(
    'clear AI recurrence applies atomically with a logical count of one and no extra confirmation',
    () async {
      final before = raw();
      await h.seed(before);
      final applied = await h.notifier.enrichCapture(
        await h.row('capture'),
        [result()],
        h.database.captureGeneration(),
        now: at,
      );
      expect(applied.changed, 1);
      final owner = await h.row('capture');
      expect(OrdinarySeries.isOwner(owner), true);
      expect(owner.captureProposalJson, isNull);
      expect(owner.capturePending, false);
      expect(owner.sourceText, before.sourceText);
      final dates = (await h.rows())
          .where(OrdinarySeries.isOccurrence)
          .toList();
      expect(dates.length, 61);
      expect(dates.first.triggerTime, due);
      expect(
        dates.first.suggestedTriggerTime,
        due.subtract(const Duration(minutes: 10)),
      );
      expect(dates[1].suggestedTriggerTime, DateTime(2030, 1, 8, 7, 50));
      expect(
        (await h.notifier.enrichCapture(
          before,
          [result()],
          h.database.captureGeneration(),
          now: at,
        )).changed,
        0,
      );
      final second = dates[1].toJson();
      await h.notifier.completeOccurrence(dates.first, now: due);
      expect((await h.row(dates[1].id)).toJson(), second);
    },
  );
  for (final type in ['audio', 'image']) {
    test(
      '$type normalized capture keeps source references in independent dates',
      () async {
        final media = MediaRecord(
          id: 'source',
          type: type,
          contentOrPath: 'synthetic-source',
          createdAt: at,
        );
        await h.container.read(mediaRecordsProvider.notifier).addRecord(media);
        await h.seed(raw(media: 'source'));
        await h.notifier.enrichCapture(
          await h.row('capture'),
          [result()],
          h.database.captureGeneration(),
          now: at,
        );
        expect(OrdinarySeries.isOwner(await h.row('capture')), true);
        expect((await h.rows()).every((r) => r.recordId == 'source'), true);
      },
    );
  }
  test(
    'complex recurrence remains a proposal; explicit application retains repeat interval and checklist',
    () async {
      await h.seed(raw(source: '每两天早上8点喝水，细节待核对'));
      final candidate = result(repeat: const RepeatWindow(interval: 2))
          .copyWith(
            detailsJson: const TaskDetails(
              repeat: RepeatWindow(interval: 2),
              checklist: [ChecklistItem('cup', 'Cup')],
              tags: ['routine'],
            ).encode(),
          );
      await h.notifier.enrichCapture(
        await h.row('capture'),
        [candidate],
        h.database.captureGeneration(),
        now: at,
      );
      final pending = await h.row('capture');
      expect(pending.captureProposalJson, isNotNull);
      expect(await h.rows(), hasLength(1));
      final batch = await h.notifier.applyCaptureProposal(
        pending,
        [candidate],
        generation: h.database.captureGeneration(),
        now: at,
      );
      expect(batch.changed, 1);
      final parent = await h.row('capture');
      expect(OrdinarySeries.isOwner(parent), true);
      expect(parent.details.repeat!.interval, 2);
      expect(parent.details.tags, ['routine']);
      expect(
        (await h.rows())
            .where(OrdinarySeries.isOccurrence)
            .every((r) => r.details.checklist.single.label == 'Cup'),
        true,
      );
    },
  );
  test(
    'date-ID collision rolls back the source and every newly generated row',
    () async {
      await h.seed(raw());
      await h.seed(
        Reminder(
          id: 'capture:ordinary:2030-01-08',
          taskTitle: 'Preserve',
          quadrantLevel: 2,
        ),
      );
      final before = (await h.rows()).map((r) => r.toJson()).toList();
      await expectLater(
        h.notifier.enrichCapture(
          await h.row('capture'),
          [result()],
          h.database.captureGeneration(),
          now: at,
        ),
        throwsException,
      );
      expect((await h.rows()).map((r) => r.toJson()).toList(), before);
    },
  );
  test(
    'native failure is reported after the full recurring dataset commits',
    () async {
      await h.seed(raw());
      h.notifications.fail = true;
      final batch = await h.notifier.enrichCapture(
        await h.row('capture'),
        [result()],
        h.database.captureGeneration(),
        now: at,
      );
      expect(batch.changed, 1);
      expect(batch.nativeSyncFailures, greaterThan(0));
      expect(await h.rows(), hasLength(62));
    },
  );
  test(
    'learning reminders retain their dedicated semantics instead of expanding into ordinary dates',
    () async {
      await h.seed(raw(source: 'Learning input'));
      final candidate = result().copyWith(spacedRepetitionLevel: 1);
      await h.notifier.enrichCapture(
        await h.row('capture'),
        [candidate],
        h.database.captureGeneration(),
        allowAutomatic: false,
        now: at,
      );
      await h.notifier.applyCaptureProposal(
        await h.row('capture'),
        [candidate],
        generation: h.database.captureGeneration(),
        now: at,
      );
      expect(await h.rows(), hasLength(1));
      expect((await h.row('capture')).spacedRepetitionLevel, 1);
    },
  );
  test(
    'cross-midnight workday capture keeps event weekdays and stable alarm dates',
    () async {
      final row = Reminder(
        id: 'local',
        taskTitle: 'Fixture',
        quadrantLevel: 2,
        triggerTime: DateTime(2030, 1, 6, 23, 50),
        eventTime: DateTime(2030, 1, 7, 0, 5),
        isRecurring: true,
        recurrenceRule: 'workday',
      );
      await h.notifier.addCapturedReminderForGeneration(
        row,
        h.database.captureGeneration(),
        now: DateTime(2030, 1, 6, 20),
      );
      final dates = (await h.rows())
          .where(OrdinarySeries.isOccurrence)
          .toList();
      expect(dates.first.triggerTime, DateTime(2030, 1, 6, 23, 50));
      expect(
        dates.every(
          (r) =>
              r.eventTime!.weekday <= 5 &&
              r.eventTime!.hour == 0 &&
              r.eventTime!.minute == 5,
        ),
        true,
      );
    },
  );
  test(
    'edited source and old recovery generation win over automatic expansion',
    () async {
      await h.seed(raw());
      final baseline = await h.row('capture');
      await h.notifier.updateReminderForGeneration(
        baseline.copyWith(taskTitle: 'User edit'),
        h.database.captureGeneration(),
        baseline: baseline,
      );
      await h.notifier.enrichCapture(
        baseline,
        [result()],
        h.database.captureGeneration(),
        now: at,
      );
      expect(await h.rows(), hasLength(1));
      expect((await h.row('capture')).taskTitle, 'User edit');
      final old = h.database.captureGeneration(),
          lease = await h.database.beginMaintenance();
      await lease.resume();
      await expectLater(
        h.notifier.enrichCapture(baseline, [result()], old, now: at),
        throwsException,
      );
      expect(await h.rows(), hasLength(1));
    },
  );
  for (final text in [
    '每天早上8点喝水',
    '工作日早上8点带耳机',
    '每周一早上8点开会',
    'daily 8 am drink water',
    '毎日8時水を飲む',
  ]) {
    test('offline grammar supports one clear cadence: $text', () {
      expect(QuickReminderParser.recurrence(text), isNotNull);
      expect(QuickReminderParser.parse(text, now: at), isNotNull);
    });
  }
  for (final text in [
    '每天8点和9点喝水',
    '每天8点持续两周',
    '每周一、三8点开会',
    '可能每天8点喝水',
    '每年1月1日8点提醒',
    '不要每天8点提醒',
    '每天早上8点喝水，提前10分钟提醒',
  ]) {
    test('complex offline expression stays unexpanded: $text', () {
      expect(QuickReminderParser.recurrence(text), isNull);
    });
  }
  test(
    'live offline text creates independent dates without invoking a configured model',
    () async {
      final controller = h.container.read(homeControllerProvider.notifier);
      expect(await controller.processText('每天早上8点喝水'), true);
      final rows = await h.rows();
      expect(rows.where(OrdinarySeries.isOwner), hasLength(1));
      expect(rows.where(OrdinarySeries.isOccurrence).length, greaterThan(50));
    },
  );
  test(
    'unclear offline recurrence saves source without inferring a one-off alarm',
    () async {
      final controller = h.container.read(homeControllerProvider.notifier);
      expect(await controller.processText('每天8点和9点喝水'), true);
      final saved = (await h.rows()).single;
      expect(saved.sourceText, '每天8点和9点喝水');
      expect(saved.triggerTime, isNull);
      expect(h.container.read(homeControllerProvider).error, isNotNull);
    },
  );
  test('local same capture ID retry cannot create a second plan', () async {
    final controller = h.container.read(homeControllerProvider.notifier);
    await controller.processText('每天早上8点喝水', captureId: 'retry');
    final before = jsonEncode((await h.rows()).map((r) => r.toJson()).toList());
    await controller.processText('每天早上8点喝水', captureId: 'retry');
    expect(
      jsonEncode((await h.rows()).map((r) => r.toJson()).toList()),
      before,
    );
  });
  test(
    'adopting one dated suggestion keeps its event and the next date unchanged',
    () async {
      await h.seed(raw());
      await h.notifier.enrichCapture(
        await h.row('capture'),
        [result()],
        h.database.captureGeneration(),
        now: at,
      );
      final first = await h.row('capture:ordinary:2030-01-07'),
          next = (await h.row('capture:ordinary:2030-01-08')).toJson();
      await h.notifier.updateReminderForGeneration(
        first.copyWith(
          triggerTime: first.suggestedTriggerTime,
          timeOrigin: ReminderTimeOrigin.manual,
        ),
        h.database.captureGeneration(),
        baseline: first,
      );
      final saved = await h.row(first.id);
      expect(saved.eventTime, due);
      expect(saved.triggerTime, due.subtract(const Duration(minutes: 10)));
      expect(saved.details.data['scheduled_at'], due.toIso8601String());
      expect((await h.row('capture:ordinary:2030-01-08')).toJson(), next);
    },
  );
  test(
    'automatic capture keeps user metadata and does not adopt invented model classification',
    () async {
      await h.seed(
        raw().copyWith(
          detailsJson: const TaskDetails(
            tags: ['mine'],
            project: 'my-project',
          ).encode(),
        ),
      );
      final proposed = result().copyWith(
        detailsJson: const TaskDetails(
          tags: ['invented'],
          project: 'invented-project',
        ).encode(),
      );
      await h.notifier.enrichCapture(
        await h.row('capture'),
        [proposed],
        h.database.captureGeneration(),
        now: at,
      );
      final owner = await h.row('capture');
      expect(owner.details.tags, ['mine']);
      expect(owner.details.project, 'my-project');
    },
  );
  test(
    'suggestion anchors survive refill and legacy unreferenced hints stay unadopted',
    () {
      final initial = OrdinarySeries.schedule(
        result().copyWith(
          triggerTime: due,
          suggestedTriggerTime: due.subtract(const Duration(minutes: 10)),
        ),
        at,
      );
      final future = OrdinarySeries.schedule(
        OrdinarySeries.template(initial.owner),
        DateTime(2030, 1, 8, 6),
      );
      expect(
        future.occurrences.first.suggestedTriggerTime,
        DateTime(2030, 1, 8, 7, 50),
      );
      final data = {...initial.owner.details.data};
      final oldSeries =
          Map<String, dynamic>.from(data['ordinary_series'] as Map)
            ..['version'] = 1
            ..remove('suggestion_anchor');
      data['ordinary_series'] = oldSeries;
      final legacy = initial.owner.copyWith(
        detailsJson: initial.owner.details.patch({'data': data}).encode(),
        suggestedTriggerTime: DateTime(2030, 5, 1),
      );
      expect(legacy.suggestedTriggerTime, isNotNull);
      expect(OrdinarySeries.template(legacy).suggestedTriggerTime, isNull);
      final first = initial.occurrences.first;
      final legacyData = {...first.details.data}
        ..remove('ordinary_occurrence_version');
      final legacyDate = first.copyWith(
        detailsJson: first.details.patch({'data': legacyData}).encode(),
      );
      expect(legacyDate.suggestedTriggerTime, isNotNull);
      expect(legacyDate.usableSuggestedTriggerTime, isNull);
      expect(first.usableSuggestedTriggerTime, first.suggestedTriggerTime);
      final encoded = initial.owner.details.toJson();
      expect(encoded['version'], 5);
      expect(
        () => TaskDetails.decode(jsonEncode({...encoded, 'version': 4})),
        throwsFormatException,
      );
    },
  );
}
