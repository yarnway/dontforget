import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:dont_forget/models/ai_profile.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/study_plan.dart';
import 'package:dont_forget/services/ai/priority_router.dart';
import 'package:dont_forget/services/spaced_repetition_service.dart';
import 'package:dont_forget/services/study_plan_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> vocabulary({int days = 1, int words = 5}) => {
  'daily_time': '20:30',
  'days': [
    for (var d = 0; d < days; d++)
      {
        'title': 'Day ${d + 1}',
        'words': [
          for (var i = 0; i < words; i++)
            {
              'word': 'word-$d-$i',
              'meaning': 'Synthetic meaning',
              'ipa': '/wɜːd/',
              'part_of_speech': 'noun',
              'usage': 'use a word',
              'translation': '合成例句译文。',
              'example': 'Synthetic original example.',
            },
        ],
      },
  ],
};

void main() {
  const request = StudyRequest(days: 1, wordsPerDay: 5);
  final settings = AppSettings.defaults().copyWith(
    apiKey: 'test-only',
    baseUrl: 'https://study.invalid/v1',
    modelName: 'synthetic',
  );
  const service = SpacedRepetitionService();

  for (final exam in StudyExam.values) {
    test(
      'validates editable ${exam.name} batches with stable IDs and calendar dates',
      () {
        final batches = StudyPlan.parse(
          jsonEncode(vocabulary(days: 3)),
          StudyRequest(exam: exam, days: 3, wordsPerDay: 5),
        );
        final plan = StudyPlan(batches: batches);
        final edited = [...batches]
          ..[0] = batches[0].copyWith(title: 'Edited title');
        final start = DateTime(2030, 1, 31, 20, 30);
        final rows = plan.reminders(edited: edited, firstReminder: start);
        expect(rows.map((r) => r.triggerTime), [
          start,
          DateTime(2030, 2, 1, 20, 30),
          DateTime(2030, 2, 2, 20, 30),
        ]);
        expect(
          rows.every(
            (r) =>
                r.reviewNotificationsEnabled &&
                !r.isRecurring &&
                r.quadrantLevel == 2,
          ),
          isTrue,
        );
        expect(rows.first.taskTitle, 'Edited title');
        expect(
          plan.reminders(edited: edited, firstReminder: start).map((r) => r.id),
          rows.map((r) => r.id),
        );
        expect(StudyPlan.parseSuggestedMinute(jsonEncode(vocabulary())), 1230);
        expect(
          () => plan.reminders(edited: edited, firstReminder: DateTime(2000)),
          throwsFormatException,
        );
        expect(
          () => plan.reminders(
            edited: [edited.first.copyWith(content: '')],
            firstReminder: start,
          ),
          throwsFormatException,
        );
      },
    );
  }
  test(
    'rejects missing, excessive, repeated and incomplete model vocabulary',
    () {
      for (final raw in [
        '{}',
        '[]',
        'not json',
        jsonEncode(vocabulary(days: 3)),
        jsonEncode(vocabulary(words: 4)),
        ' ' * 120001,
      ]) {
        expect(() => StudyPlan.parse(raw, request), throwsFormatException);
      }
      final duplicate = vocabulary();
      final words = ((duplicate['days'] as List).first as Map)['words'] as List;
      words[1] = words[0];
      expect(
        () => StudyPlan.parse(jsonEncode(duplicate), request),
        throwsFormatException,
      );
      for (final time in ['24:00', '12:60', '8:30', '', null, 123]) {
        expect(
          () => StudyPlan.parseSuggestedMinute(
            jsonEncode({...vocabulary(), 'daily_time': time}),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => const StudyRequest(days: 100).validate(),
        throwsFormatException,
      );
    },
  );
  test(
    'learning feedback advances from one day and retains selected local time',
    () {
      var card = Reminder(
        id: 'learning',
        taskTitle: 'Batch',
        quadrantLevel: 2,
        spacedRepetitionLevel: 1,
        reviewNotificationsEnabled: true,
        nextReviewAt: DateTime(2030, 1, 1, 20, 30),
        triggerTime: DateTime(2030, 1, 1, 20, 30),
      );
      var now = DateTime(2030, 1, 1, 8);
      for (final days in [1, 2, 4, 7, 15, 15]) {
        card = service.reviewCard(card, true, referenceTime: now);
        final expected = DateTime(now.year, now.month, now.day + days, 20, 30);
        expect(card.nextReviewAt, expected);
        expect(card.triggerTime, expected);
        now = expected;
      }
      final difficult = service.reviewCard(card, false, referenceTime: now);
      expect(difficult.spacedRepetitionLevel, 1);
      expect(
        difficult.nextReviewAt,
        DateTime(now.year, now.month, now.day + 1, 20, 30),
      );
      expect(service.isDue(card.copyWith(isCompleted: true), now), isFalse);
      final disabled = service.disableCard(card);
      expect(disabled.triggerTime, isNull);
      expect(disabled.reviewNotificationsEnabled, isFalse);
      final plain = card.copyWith(reviewNotificationsEnabled: false);
      expect(service.disableCard(plain).triggerTime, plain.triggerTime);
      expect(
        service.reviewCard(plain, true, referenceTime: now).triggerTime,
        plain.triggerTime,
      );
    },
  );
  test(
    'model request uses chosen profile and validates response before preview',
    () async {
      final dio = Dio();
      final calls = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls.add(options);
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'choices': [
                    {
                      'message': {'content': jsonEncode(vocabulary())},
                      'finish_reason': 'stop',
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      final model = StudyPlanService(client: dio);
      final result = await model.generate(
        request,
        settings,
        cancelToken: CancelToken(),
      );
      expect(result.batches, hasLength(1));
      expect(result.suggestedMinute, 1230);
      expect(calls.single.followRedirects, isFalse);
      expect(
        calls.single.uri.toString(),
        'https://study.invalid/v1/chat/completions',
      );
      expect((calls.single.data as Map)['model'], 'synthetic');
      model.dispose();
      await expectLater(
        model.generate(request, settings, cancelToken: CancelToken()),
        throwsStateError,
      );
    },
  );
  test(
    'invalid primary response falls back only when user enabled it',
    () async {
      for (final fallback in [false, true]) {
        final dio = Dio();
        final hosts = <String>[];
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              hosts.add(o.uri.host);
              h.resolve(
                Response(
                  requestOptions: o,
                  data: {
                    'choices': [
                      {
                        'message': {
                          'content': o.uri.host == 'first.invalid'
                              ? '{}'
                              : jsonEncode(vocabulary()),
                        },
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
        final configured = settings.copyWith(
          aiFallbackEnabled: fallback,
          aiProfiles: [
            for (final host in ['first', 'second'])
              AiProfile(
                id: host,
                label: host,
                settings: settings.copyWith(
                  baseUrl: 'https://$host.invalid/v1',
                ),
              ),
          ],
        );
        final model = StudyPlanService(client: dio);
        final future = model.generate(
          request,
          configured,
          cancelToken: CancelToken(),
        );
        if (fallback) {
          final plan = await future;
          expect(plan.usedFallback, isTrue);
          expect(plan.modelLabel, 'second');
        } else {
          await expectLater(future, throwsA(isA<AiRouteFailure>()));
        }
        expect(
          hosts,
          fallback ? ['first.invalid', 'second.invalid'] : ['first.invalid'],
        );
        model.dispose();
      }
    },
  );
  test('cancelled generation never exposes a late preview', () async {
    final dio = Dio();
    final started = Completer<void>();
    late RequestInterceptorHandler pending;
    late RequestOptions options;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          options = o;
          pending = h;
          started.complete();
        },
      ),
    );
    final model = StudyPlanService(client: dio);
    final token = CancelToken();
    final future = model.generate(request, settings, cancelToken: token);
    final expectation = expectLater(future, throwsA(isA<DioException>()));
    await started.future;
    token.cancel();
    pending.resolve(
      Response(
        requestOptions: options,
        data: {
          'choices': [
            {
              'message': {'content': jsonEncode(vocabulary())},
            },
          ],
        },
      ),
    );
    await expectation;
    model.dispose();
  });

  test(
    'disposing a model session cancels pending work without fallback',
    () async {
      final dio = Dio();
      final started = Completer<void>();
      final calls = <String>[];
      late RequestInterceptorHandler pending;
      late RequestOptions options;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            calls.add(o.uri.host);
            options = o;
            pending = h;
            started.complete();
          },
        ),
      );
      final model = StudyPlanService(client: dio);
      final configured = settings.copyWith(
        aiFallbackEnabled: true,
        aiProfiles: [
          for (final host in ['first', 'second'])
            AiProfile(
              id: host,
              label: host,
              settings: settings.copyWith(baseUrl: 'https://$host.invalid/v1'),
            ),
        ],
      );
      final future = model.generate(
        request,
        configured,
        cancelToken: CancelToken(),
      );
      final assertion = expectLater(future, throwsA(isA<DioException>()));
      await started.future;
      model.dispose();
      pending.resolve(Response(requestOptions: options, data: {}));
      await assertion;
      expect(calls, ['first.invalid']);
    },
  );

  test(
    'learning banners are bounded without truncating stored words or Unicode',
    () {
      final text = '🧠' * 200;
      final reminder = Reminder(
        id: 'bounded',
        taskTitle: 'Vocabulary',
        quadrantLevel: 2,
        taskSummary: text,
        reviewNotificationsEnabled: true,
      );
      expect(reminder.notificationSummary, '${'🧠' * 160}…');
      expect(reminder.taskSummary, text);
      expect(
        reminder
            .copyWith(reviewNotificationsEnabled: false)
            .notificationSummary,
        text,
      );
    },
  );
}
