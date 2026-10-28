import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/capture_automation_policy.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/quick_reminder_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'support/offline_management_harness.dart';

class _Model extends LLMService {
  final requests = <Completer<List<Reminder>>>[];
  @override
  Future<List<Reminder>> extractTasks(String text, AppSettings settings) {
    final request = Completer<List<Reminder>>();
    requests.add(request);
    return request.future;
  }
}

class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({
      'choices': [
        {
          'message': {
            'content': jsonEncode({
              'tasks': [
                {
                  'title': '买牛奶',
                  'requires_confirmation': false,
                  'uncertainties': [],
                  'source_quote': '买牛奶',
                  'event_time': null,
                  'time': null,
                },
              ],
            }),
          },
        },
      ],
    }),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final reference = DateTime(2030, 1, 7, 8);
  Reminder baseline(
    String source, {
    DateTime? event,
    DateTime? trigger,
    String? recordId,
  }) => Reminder(
    id: 'capture',
    taskTitle: source,
    sourceText: source,
    taskSummary: source,
    quadrantLevel: 2,
    createdAt: reference,
    eventTime: event,
    triggerTime: trigger,
    timeOrigin: trigger == null
        ? ReminderTimeOrigin.unknown
        : ReminderTimeOrigin.manual,
    capturePending: true,
    recordId: recordId,
  );
  Reminder item(
    String title, {
    DateTime? event,
    DateTime? trigger,
    bool recurring = false,
    String rule = 'none',
    Map<String, dynamic> metadata = const {},
  }) => Reminder(
    id: 'model',
    taskTitle: title,
    quadrantLevel: 2,
    eventTime: event,
    triggerTime: trigger,
    isRecurring: recurring,
    recurrenceRule: rule,
    detailsJson: metadata.isEmpty ? null : TaskDetails(data: metadata).encode(),
  );
  List<Reminder>? resolve(
    Reminder raw,
    List<Reminder> values, {
    bool image = false,
  }) => CaptureAutomationPolicy.resolve(
    raw,
    values,
    now: reference,
    imageSource: image,
  );
  test(
    'clear memo and explicit task apply without adopting AI preparation offsets',
    () {
      expect(
        resolve(baseline('买牛奶'), [item('买牛奶')])!.single.triggerTime,
        isNull,
      );
      final event = DateTime(2030, 1, 8, 9),
          manual = DateTime(2030, 1, 8, 8, 50),
          suggestion = DateTime(2030, 1, 8, 8, 45);
      final resolved = resolve(
        baseline('明天9点开会', event: event, trigger: manual),
        [item('开会', event: event, trigger: suggestion)],
      )!.single;
      expect(resolved.triggerTime, manual);
      expect(resolved.eventTime, event);
      expect(resolved.suggestedTriggerTime, suggestion);
      expect(resolved.taskSummary, '明天9点开会');
    },
  );
  test('clear separate statements create multiple tasks in source order', () {
    final raw = baseline(
      '明天9点开会；明天下午3点交报告',
      event: DateTime(2030, 1, 8, 9),
      trigger: DateTime(2030, 1, 8, 9),
    );
    final values = resolve(raw, [
      item('交报告', event: DateTime(2030, 1, 8, 15)),
      item('开会', event: DateTime(2030, 1, 8, 9)),
    ])!;
    expect(values.map((e) => e.taskTitle), ['开会', '交报告']);
    expect(values.last.triggerTime, DateTime(2030, 1, 8, 15));
  });
  test(
    'ambiguous questions model omissions and invented dates remain proposals',
    () {
      for (final source in [
        '大概明天9点开会',
        '明天9点还是10点开会',
        '如果下雨明天9点开会',
        '是否买牛奶？',
        '不要提醒我明天9点开会',
      ]) {
        expect(
          resolve(baseline(source), [
            item('开会', event: DateTime(2030, 1, 8, 9)),
          ]),
          isNull,
        );
      }
      expect(
        resolve(baseline('买牛奶'), [item('买牛奶', event: DateTime(2030, 1, 8, 9))]),
        isNull,
      );
      expect(resolve(baseline('买牛奶'), [item('买面包')]), isNull);
      expect(resolve(baseline('买牛奶；交报告'), [item('买牛奶')]), isNull);
      expect(
        resolve(baseline('买牛奶'), [
          item('买牛奶', metadata: {'capture_requires_review': true}),
        ]),
        isNull,
      );
      expect(
        resolve(baseline('买牛奶'), [
          item(
            '买牛奶',
            metadata: {
              'capture_issues': ['quantity conflict'],
            },
          ),
        ]),
        isNull,
      );
    },
  );
  test(
    'explicit absolute dates are checked without overflowing invalid days',
    () {
      expect(
        resolve(baseline('2030-01-09 14:00开会'), [
          item('开会', event: DateTime(2030, 1, 9, 14)),
        ])!.single.triggerTime,
        DateTime(2030, 1, 9, 14),
      );
      expect(
        resolve(baseline('2030-02-31 14:00开会'), [
          item('开会', event: DateTime(2030, 3, 3, 14)),
        ]),
        isNull,
      );
    },
  );
  test('explicit daily recurrence can apply but uncertain rules cannot', () {
    final event = DateTime(2030, 1, 7, 20);
    expect(
      resolve(baseline('每天晚上8点散步'), [
        item('散步', event: event, recurring: true, rule: 'daily'),
      ])!.single.isRecurring,
      isTrue,
    );
    expect(
      resolve(baseline('有空每天晚上8点散步'), [
        item('散步', event: event, recurring: true, rule: 'daily'),
      ]),
      isNull,
    );
    expect(
      resolve(baseline('晚上8点散步'), [
        item('散步', event: event, recurring: true, rule: 'daily'),
      ]),
      isNull,
    );
    expect(resolve(baseline('每天晚上8点散步'), [item('散步', event: event)]), isNull);
  });
  test(
    'image automation needs a clear quoted source and explicit model clarity',
    () {
      final raw = baseline('fixture.png', recordId: 'image');
      expect(resolve(raw, [item('买牛奶')], image: true), isNull);
      expect(
        resolve(raw, [
          item(
            '买牛奶',
            metadata: {
              'capture_requires_review': false,
              'capture_evidence': '买牛奶',
            },
          ),
        ], image: true)!.single.triggerTime,
        isNull,
      );
      expect(
        resolve(raw, [
          item(
            '开会',
            event: DateTime(2030, 1, 8, 9),
            metadata: {
              'capture_requires_review': false,
              'capture_evidence': '明天9点左右开会',
            },
          ),
        ], image: true),
        isNull,
      );
    },
  );
  test(
    'extraction transport retains clarity metadata without changing ordinary storage columns',
    () async {
      final dio = Dio()..httpClientAdapter = _Adapter();
      final service = LLMService(client: dio);
      try {
        final result = await service.extractTasks(
          '买牛奶',
          AppSettings(
            id: 'default',
            modelName: 'fixture',
            language: 'zh',
            apiKey: 'synthetic',
            baseUrl: 'https://fixture.invalid/v1',
          ),
        );
        expect(result.single.details.data['capture_requires_review'], false);
        expect(result.single.details.data['capture_evidence'], '买牛奶');
        expect(result.single.details.data['capture_issues'], isEmpty);
      } finally {
        service.dispose();
      }
    },
  );
  test(
    'weekday and calendar text resolve the first exact occurrence locally',
    () {
      expect(
        QuickReminderParser.parse('每周五下午3点开会', now: reference),
        DateTime(2030, 1, 11, 15),
      );
      expect(
        QuickReminderParser.parse('下周一9点开会', now: reference),
        DateTime(2030, 1, 14, 9),
      );
      expect(
        QuickReminderParser.parse('每天早上7点散步', now: reference),
        DateTime(2030, 1, 8, 7),
      );
      expect(
        QuickReminderParser.parse('工作日早上7点出门', now: DateTime(2030, 1, 11, 18)),
        DateTime(2030, 1, 14, 7),
      );
      expect(
        QuickReminderParser.parse('2030年1月9日下午3点半开会', now: reference),
        DateTime(2030, 1, 9, 15, 30),
      );
      expect(
        QuickReminderParser.parse('2030-02-31下午3点开会', now: reference),
        isNull,
      );
      expect(QuickReminderParser.parse('明天9点左右开会', now: reference), isNull);
      expect(
        QuickReminderParser.parse('2030-01-09T14:00Z开会', now: reference),
        isNull,
      );
      expect(QuickReminderParser.parse('上周五下午3点开会', now: reference), isNull);
      expect(
        QuickReminderParser.parse('每周一、三、五下午3点开会', now: reference),
        isNull,
      );
      final event = DateTime(2030, 1, 11, 15);
      expect(
        resolve(baseline('每周五下午3点开会', event: event, trigger: event), [
          item('开会', event: event, recurring: true, rule: 'weekly'),
        ])!.single.isRecurring,
        isTrue,
      );
    },
  );
  group('capture transactions and live input flow', () {
    late OfflineManagementHarness h;
    late _Model model;
    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            (_) async => null,
          );
      model = _Model();
      h = OfflineManagementHarness(model: model);
      await h.create();
    });
    tearDown(() async {
      await h.dispose();
      model.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            null,
          );
    });
    Future<void> until(bool Function() predicate) async {
      for (var i = 0; i < 500 && !predicate(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(predicate(), isTrue);
    }

    Future<Reminder> seed(String source) async {
      final event = QuickReminderParser.parse(source);
      await h.seed(
        Reminder(
          id: 'capture',
          taskTitle: source,
          sourceText: source,
          taskSummary: source,
          quadrantLevel: 2,
          capturePending: true,
          eventTime: event,
          triggerTime: event,
          timeOrigin: event == null
              ? ReminderTimeOrigin.unknown
              : ReminderTimeOrigin.manual,
        ),
      );
      return h.row('capture');
    }

    test(
      'automatic application preserves identity source and manual time with no confirmation step',
      () async {
        final raw = await seed('明天9点开会');
        final event = raw.eventTime!;
        final result = await h.notifier.enrichCapture(raw, [
          item(
            '开会',
            event: event,
            trigger: event.subtract(const Duration(minutes: 15)),
          ),
        ], h.database.captureGeneration());
        final saved = await h.row('capture');
        expect(result.changed, 1);
        expect(saved.taskTitle, '开会');
        expect(saved.sourceText, raw.sourceText);
        expect(saved.triggerTime, raw.triggerTime);
        expect(
          saved.suggestedTriggerTime,
          event.subtract(const Duration(minutes: 15)),
        );
        expect(saved.capturePending, isFalse);
        expect(saved.captureProposalJson, isNull);
        expect(saved.details.history.last.action, 'capture_auto_applied');
        expect(
          (await h.notifier.enrichCapture(raw, [
            item('开会', event: event),
          ], h.database.captureGeneration())).changed,
          0,
        );
        expect(await h.rows(), hasLength(1));
      },
    );
    test(
      'clear multiple tasks publish all rows and native failures retain durable tasks',
      () async {
        final raw = await seed('买牛奶；交报告');
        h.notifications.fail = true;
        final result = await h.notifier.enrichCapture(raw, [
          item('买牛奶'),
          item('交报告'),
        ], h.database.captureGeneration());
        expect(result.changed, 2);
        expect(result.nativeSyncFailures, 2);
        expect(h.container.read(remindersProvider), hasLength(2));
        expect(
          (await h.rows()).map((e) => e.id),
          containsAll(['capture', 'capture:capture:1']),
        );
      },
    );
    test(
      'user edits and recovery win over delayed automatic results',
      () async {
        final raw = await seed('买牛奶');
        final gen = h.database.captureGeneration();
        await h.notifier.updateReminderForGeneration(
          raw.copyWith(taskTitle: 'My edit'),
          gen,
          baseline: raw,
        );
        await h.notifier.enrichCapture(raw, [item('买牛奶')], gen);
        final edited = await h.row('capture');
        expect(edited.taskTitle, 'My edit');
        expect(edited.captureProposalJson, isNotNull);
        final lease = await h.database.beginMaintenance();
        await lease.resume();
        await expectLater(
          h.notifier.enrichCapture(raw, [item('买牛奶')], gen),
          throwsA(isA<DatabaseAccessException>()),
        );
      },
    );
    test(
      'split collision rolls back the primary row and leaves the source pending',
      () async {
        final raw = await seed('买牛奶；交报告');
        await h.seed(
          Reminder(
            id: 'capture:capture:1',
            taskTitle: 'Preserve existing',
            quadrantLevel: 2,
          ),
        );
        final before = jsonEncode(
          (await h.rows()).map((e) => e.toJson()).toList(),
        );
        await expectLater(
          h.notifier.enrichCapture(raw, [
            item('买牛奶'),
            item('交报告'),
          ], h.database.captureGeneration()),
          throwsException,
        );
        expect(
          jsonEncode((await h.rows()).map((e) => e.toJson()).toList()),
          before,
        );
      },
    );
    test(
      'simple live input is saved first then organized automatically',
      () async {
        await h.container
            .read(settingsProvider.notifier)
            .updateSettings(
              h.container.read(settingsProvider).copyWith(apiKey: 'synthetic'),
            );
        final home = h.container.read(homeControllerProvider.notifier);
        expect(await home.processText('买牛奶', captureId: 'stable'), isTrue);
        await until(() => model.requests.isNotEmpty);
        expect((await h.row('stable')).capturePending, isTrue);
        model.requests.single.complete([item('买牛奶')]);
        await until(() => !home.state.isProcessingInBackground);
        final saved = await h.row('stable');
        expect(saved.captureProposalJson, isNull);
        expect(saved.capturePending, isFalse);
        expect(saved.sourceText, '买牛奶');
        expect(await home.processText('买牛奶', captureId: 'stable'), isTrue);
        expect(await h.rows(), hasLength(1));
      },
    );
    test(
      'ambiguous live time stays unscheduled until review and memo-only never calls AI',
      () async {
        await h.container
            .read(settingsProvider.notifier)
            .updateSettings(
              h.container.read(settingsProvider).copyWith(apiKey: 'synthetic'),
            );
        final home = h.container.read(homeControllerProvider.notifier);
        await home.processText('大概明天9点开会', captureId: 'unclear');
        await until(() => model.requests.isNotEmpty);
        expect((await h.row('unclear')).triggerTime, isNull);
        final now = DateTime.now();
        model.requests.single.complete([
          item('开会', event: DateTime(now.year, now.month, now.day + 1, 9)),
        ]);
        await until(() => !home.state.isProcessingInBackground);
        final saved = await h.row('unclear');
        expect(saved.captureProposalJson, isNotNull);
        expect(saved.triggerTime, isNull);
        await home.processText('明天9点开会', captureId: 'memo', memoOnly: true);
        expect(model.requests, hasLength(1));
        expect((await h.row('memo')).triggerTime, isNull);
      },
    );
  });
}
