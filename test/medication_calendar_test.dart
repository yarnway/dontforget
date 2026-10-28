import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/calendar_exceptions.dart';
import 'package:dont_forget/models/departure_plan.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/medication_evidence.dart';
import 'package:dont_forget/models/medication_plan.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/medication_review_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/offline_management_harness.dart';

class _Model extends LLMService {
  Map<String, dynamic> result = {'medicines': []};
  Object? content;
  Completer<void>? barrier;
  int calls = 0, audioCalls = 0;
  @override
  Future<Map<String, dynamic>> structuredProposal(
    String prompt,
    Object input,
    AppSettings settings, {
    CancelToken? cancelToken,
  }) async {
    calls++;
    content = input;
    await barrier?.future;
    return result;
  }

  @override
  Future<String> transcribeAudio(String path, AppSettings settings) async {
    audioCalls++;
    return 'Fixture 1 unit after meal';
  }
}

Medicine medicine({
  List<String> times = const [],
  List<MealDoseTime> links = const [
    MealDoseTime(mealId: 'breakfast', offsetMinutes: -30),
  ],
}) => Medicine(
  id: 'medicine',
  name: 'Synthetic medicine',
  strength: 'fixture form',
  amount: '1',
  unit: 'fixture unit',
  meal: 'explicit synthetic instruction',
  times: times,
  mealLinks: links,
);
MedicationPlan course({
  String clock = '08:00',
  DateTime? start,
  DateTime? end,
}) => MedicationPlan(
  id: 'course',
  title: 'Synthetic course',
  start: start ?? DateTime(2030, 1, 7),
  end: end ?? DateTime(2030, 1, 9),
  medicines: [medicine()],
  meals: [MealTime(id: 'breakfast', label: 'Breakfast', time: clock)],
);
DeparturePlan departure({
  CalendarExceptions exceptions = const CalendarExceptions(),
}) => DeparturePlan(
  id: 'departure',
  title: 'Synthetic departure',
  departureMinute: 5,
  leadMinutes: 10,
  weekdays: const [2],
  items: const [ChecklistItem('keys', 'Keys')],
  exceptions: exceptions,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('calendar exceptions', () {
    test(
      'strict bounded independent dates reject rollover, duplicate and overlap',
      () {
        for (final raw in [
          {
            'skip': ['2030-02-30'],
          },
          {
            'add': ['2030-1-01'],
          },
          {
            'skip': ['2030-01-01', '2030-01-01'],
          },
          {
            'skip': ['2030-01-01'],
            'add': ['2030-01-01'],
          },
          {'add': List.filled(367, '2030-01-01')},
          {'unknown': []},
        ]) {
          expect(() => CalendarExceptions.fromJson(raw), throwsFormatException);
        }
        final e = CalendarExceptions.fromJson({
          'skip': ['2030-01-01'],
          'add': ['2029-12-31'],
        });
        expect(e.shift(-1).toJson(), {
          'skip': ['2029-12-31'],
          'add': ['2029-12-30'],
        });
        expect(() => e.skip.clear(), throwsUnsupportedError);
      },
    );
    test(
      'workday extra weekend and skipped holiday retain original cadence',
      () {
        final base = DateTime(2030, 1, 4, 8); // Friday
        const r = RepeatWindow(
          exceptions: CalendarExceptions(
            skip: ['2030-01-07'],
            add: ['2030-01-05'],
          ),
        );
        expect(r.next(base, base, 'workday'), DateTime(2030, 1, 5, 8));
        expect(
          r.next(base, DateTime(2030, 1, 5, 8), 'workday'),
          DateTime(2030, 1, 8, 8),
        );
        expect(
          const RepeatWindow(
            interval: 2,
            exceptions: CalendarExceptions(add: ['2030-01-05']),
          ).next(base, DateTime(2030, 1, 5, 8), 'daily'),
          DateTime(2030, 1, 6, 8),
        );
      },
    );
    test(
      'monthly skipped first date preserves month-end and extra date clock',
      () {
        final base = DateTime(2030, 1, 31, 8);
        final r = RepeatWindow(
          anchor: base,
          exceptions: const CalendarExceptions(
            skip: ['2030-01-31', '2030-02-28'],
            add: ['2030-03-02'],
          ),
        );
        expect(
          r.next(DateTime(2030, 2, 28, 8), DateTime(2030, 2, 28, 8), 'monthly'),
          DateTime(2030, 3, 2, 8),
        );
        expect(
          r.next(DateTime(2030, 3, 2, 8), DateTime(2030, 3, 2, 8), 'monthly'),
          DateTime(2030, 3, 31, 8),
        );
        expect(
          r.next(base, DateTime(2030, 3, 31, 8), 'monthly'),
          DateTime(2030, 4, 30, 8),
        );
      },
    );
    test('extra dates obey range, cutoff and leap-year yearly schedule', () {
      final base = DateTime(2028, 2, 29, 8);
      final r = RepeatWindow(
        end: DateTime(2030, 3, 1, 23, 59),
        exceptions: const CalendarExceptions(
          skip: ['2029-02-28'],
          add: ['2030-03-01'],
        ),
      );
      expect(r.next(base, base, 'yearly'), DateTime(2030, 2, 28, 8));
      expect(
        r.next(base, DateTime(2030, 2, 28, 8), 'yearly'),
        DateTime(2030, 3, 1, 8),
      );
      expect(r.next(base, DateTime(2030, 3, 1, 8), 'yearly'), isNull);
      expect(
        () => RepeatWindow.fromJson({
          ...r.toJson(),
          'end': '2030-02-01T23:59:00',
        }),
        throwsFormatException,
      );
    });
    test(
      'cross-midnight departure exceptions use departure day, stable IDs',
      () {
        final start = DateTime(2030, 1, 7, 6);
        final p = departure(
          exceptions: const CalendarExceptions(
            skip: ['2030-01-08'],
            add: ['2030-01-09'],
          ),
        );
        final rows = p.schedule(start);
        expect(rows.occurrences.first.id, 'departure:departure:2030-01-09');
        expect(
          rows.occurrences.first.triggerTime,
          DateTime(2030, 1, 8, 23, 55),
        );
        expect(rows.occurrences.first.eventTime, DateTime(2030, 1, 9, 0, 5));
        expect(p.build(start).details.repeat!.exceptions.skip, ['2030-01-07']);
        expect(
          p.schedule(DateTime(2030, 1, 8, 6)).occurrences.first.id,
          rows.occurrences.first.id,
        );
        expect(
          rows.occurrences.any((r) => r.id.endsWith('2030-01-08')),
          isFalse,
        );
      },
    );
    test('skipping the entire rolling window remains a saved future plan', () {
      final start = DateTime(2030, 1, 7);
      final p = departure(
        exceptions: CalendarExceptions(
          skip: [
            for (var i = 0; i <= 60; i++)
              CalendarExceptions.key(DateTime(2030, 1, 7 + i)),
          ],
        ),
      );
      expect(p.schedule(start).occurrences, isEmpty);
      expect(p.build(start).triggerTime!.isAfter(DateTime(2030, 3, 8)), isTrue);
    });
    test(
      'old details remain v1, advanced details fence v1 readers and unfenced imports',
      () {
        expect(const TaskDetails().toJson()['version'], 1);
        expect(
          TaskDetails.decode(const TaskDetails().encode()).encode(),
          const TaskDetails().encode(),
        );
        for (final details in [
          TaskDetails(repeat: RepeatWindow(anchor: DateTime(2030))),
          const TaskDetails(
            repeat: RepeatWindow(
              exceptions: CalendarExceptions(skip: ['2030-01-01']),
            ),
          ),
          departure(
            exceptions: const CalendarExceptions(add: ['2030-01-09']),
          ).schedule(DateTime(2030, 1, 7)).owner.details,
          course().build(now: DateTime(2030, 1, 6)).owner.details,
          course().build(now: DateTime(2030, 1, 6)).doses.first.details,
        ]) {
          expect(details.toJson()['version'], 2);
          expect(
            TaskDetails.decode(details.encode()).toJson(),
            details.toJson(),
          );
          expect(
            () => TaskDetails.decode(
              jsonEncode({...details.toJson(), 'version': 1}),
            ),
            throwsFormatException,
          );
        }
        expect(
          () => TaskDetails.decode('{"version":2}'),
          throwsFormatException,
        );
      },
    );
  });
  group('medication evidence and meal times', () {
    const citations = [
      MedicationCitation(
        field: 'amount',
        sourceId: 'label',
        value: '1',
        quote: 'one',
      ),
      MedicationCitation(
        field: 'amount',
        sourceId: 'order',
        value: '2',
        quote: 'two',
      ),
    ];
    test(
      'conflicts require explicit review bound to exact values and excerpts',
      () {
        expect(MedicationFacts.conflicts({'amount': '1'}, citations, {}), [
          'amount',
        ]);
        final reviewed = {
          'amount': MedicationFacts.fingerprint('amount', '1', citations),
        };
        expect(
          MedicationFacts.conflicts({'amount': '1.0'}, citations, reviewed),
          isEmpty,
        );
        expect(
          MedicationFacts.conflicts({'amount': '2'}, citations, reviewed),
          ['amount'],
        );
        expect(
          MedicationFacts.conflicts(
            {'amount': '1'},
            citations.take(1).toList(),
            reviewed,
          ),
          isEmpty,
        );
        final changed = [
          const MedicationCitation(
            field: 'amount',
            sourceId: 'label',
            value: '1',
            quote: 'new',
          ),
          citations[1],
        ];
        expect(MedicationFacts.conflicts({'amount': '1'}, changed, reviewed), [
          'amount',
        ]);
        expect(
          MedicationFacts.conflicts(
            {'name': 'Fixture'},
            [],
            {},
            requiredFields: {'name'},
          ),
          ['name'],
        );
      },
    );
    test('unknown sources and fabricated text excerpts fail closed', () {
      expect(
        () => MedicationFacts.validateSources([], citations),
        throwsFormatException,
      );
      expect(
        () => MedicationFacts.validateSources(const [
          MedicationSource(
            id: 'label',
            kind: 'text',
            label: 'label',
            text: 'other',
          ),
        ], citations.take(1)),
        throwsFormatException,
      );
      expect(
        () => MedicationPlan.fromJson({
          ...course().toJson(),
          'sources': List.filled(
            9,
            const MedicationSource(id: 'x', kind: 'text', label: 'x').toJson(),
          ),
        }),
        throwsFormatException,
      );
    });
    test(
      'sparse long intervals and 366 excluded weekly dates retain a next date',
      () {
        final base = DateTime(2030, 1, 7, 8);
        final first = DateTime(2030, 1, 7 + 365 * 7, 8);
        final repeat = RepeatWindow(
          interval: 365,
          weekdays: const [1],
          exceptions: CalendarExceptions(skip: [CalendarExceptions.key(first)]),
        );
        expect(
          repeat.next(base, base, 'weekly'),
          DateTime(2030, 1, 7 + 730 * 7, 8),
        );
        final p = departure(
          exceptions: CalendarExceptions(
            skip: [
              for (var i = 0; i < 366; i++)
                CalendarExceptions.key(DateTime(2030, 1, 8 + i * 7)),
            ],
          ),
        );
        expect(
          p.build(DateTime(2030, 1, 7)).eventTime,
          DateTime(2030, 1, 8 + 366 * 7, 0, 5),
        );
      },
    );
    test(
      'meal-linked times are explicit, immutable dose snapshots and round trip',
      () {
        final p = course(), built = p.build(now: DateTime(2030, 1, 6));
        expect(built.doses, hasLength(3));
        expect(built.doses.first.triggerTime, DateTime(2030, 1, 7, 7, 30));
        expect(built.doses.first.details.data['times'], ['07:30']);
        expect(
          built.doses.first.details.data.containsKey('meal_links'),
          isFalse,
        );
        expect(built.doses.first.details.data['meal_context'], [
          {
            'id': 'breakfast',
            'label': 'Breakfast',
            'time': '08:00',
            'offset': -30,
          },
        ]);
        expect(MedicationPlan.fromJson(p.toJson()).encode(), p.encode());
        final after = medicine(
          links: const [MealDoseTime(mealId: 'breakfast', offsetMinutes: 30)],
        );
        expect(after.resolvedMinutes(p.meals), [510]);
      },
    );
    test(
      'missing, duplicate, out-of-range and cross-day meal links cannot activate',
      () {
        final p = course();
        for (final m in [
          medicine(
            links: const [MealDoseTime(mealId: 'missing', offsetMinutes: 10)],
          ),
          medicine(links: const [MealDoseTime(mealId: 'breakfast')]),
          medicine(times: const ['07:30']),
          medicine(
            links: const [
              MealDoseTime(mealId: 'breakfast', offsetMinutes: 181),
            ],
          ),
          medicine(times: List.filled(8, '09:00')),
        ]) {
          expect(
            () => MedicationPlan.fromJson({
              ...p.toJson(),
              'medicines': [m.toJson()],
            }).build(now: DateTime(2030, 1, 6)),
            throwsFormatException,
          );
        }
        expect(
          () => course(clock: '00:10').build(now: DateTime(2030, 1, 6)),
          throwsFormatException,
        );
        expect(
          () => course(clock: 'bad').build(now: DateTime(2030, 1, 6)),
          throwsFormatException,
        );
      },
    );
    test('multi-source populated fields without evidence block activation', () {
      final raw = {...course().toJson(), 'review_sources': true};
      final p = MedicationPlan.fromJson(raw);
      expect(p.issues, contains('planSources'));
      expect(p.issues, contains('medicineSources:1'));
      expect(() => p.build(now: DateTime(2030, 1, 6)), throwsFormatException);
      raw['resolved_fields'] = {
        for (final f in ['title', 'start', 'end'])
          f: MedicationFacts.fingerprint(f, raw[f], []),
      };
      final m = raw['medicines'][0] as Map<String, dynamic>;
      m['resolved_fields'] = {
        for (final f in ['name', 'strength', 'amount', 'unit', 'meal', 'times'])
          f: MedicationFacts.fingerprint(
            f,
            f == 'times' ? ['07:30'] : m[f],
            [],
          ),
      };
      expect(
        MedicationPlan.fromJson(raw).build(now: DateTime(2030, 1, 6)).doses,
        hasLength(3),
      );
      m['start'] = '2030-01-08';
      expect(
        MedicationPlan.fromJson(raw).issues,
        contains('medicineSources:1'),
      );
      m['resolved_fields']['start'] = MedicationFacts.fingerprint(
        'start',
        m['start'],
        [],
      );
      expect(
        MedicationPlan.fromJson(raw).build(now: DateTime(2030, 1, 6)).doses,
        hasLength(2),
      );
    });
  });
  group('source extraction ownership', () {
    late Directory temp;
    late _Model model;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('medication-review-');
      model = _Model();
    });
    tearDown(() async {
      model.dispose();
      await temp.delete(recursive: true);
    });
    MediaRecord record(String id, String type, String content) => MediaRecord(
      id: id,
      type: type,
      contentOrPath: content,
      createdAt: DateTime(2030),
    );
    Future<MedicationPlan> extract(
      Map<String, dynamic> draft,
      List<MediaRecord> rows, {
      bool Function()? current,
    }) => MedicationReviewService().extract(
      draft: draft,
      records: rows,
      model: model,
      settings: AppSettings.defaults(),
      isCurrent: current,
    );
    test(
      'text, image and audio sources are labelled, transcribed and kept together',
      () async {
        final image = await File(
          '${temp.path}/label.png',
        ).writeAsBytes([137, 80, 78, 71]);
        final audio = await File('${temp.path}/order.m4a').writeAsBytes([1, 2]);
        final rows = [
          record('photo', 'image', image.path),
          record('voice', 'audio', audio.path),
          record('text', 'text', 'Fixture instruction'),
        ];
        model.result = {
          'title': 'Fixture',
          'medicines': [
            {
              'name': 'Fixture',
              'amount': '1',
              'provenance': [
                {
                  'field': 'amount',
                  'source_id': 's-voice',
                  'value': '1',
                  'quote': '1 unit',
                },
              ],
            },
          ],
        };
        final result = await extract({
          ...MedicationPlan().toJson(),
          'source': 'Manual note',
          'sources': [
            for (final r in rows)
              MedicationSource(
                id: 's-${r.id}',
                kind: r.type,
                label: r.id,
                recordId: r.id,
              ).toJson(),
          ],
        }, rows);
        expect(result.sources.map((s) => s.kind), [
          'manual',
          'image',
          'audio',
          'text',
        ]);
        expect(result.sources[2].text, 'Fixture 1 unit after meal');
        expect(model.audioCalls, 1);
        expect(
          (model.content as List).where((e) => e['type'] == 'image_url'),
          hasLength(1),
        );
        expect(jsonEncode(model.content), contains('SOURCE s-photo'));
        expect(jsonEncode(model.content), contains('SOURCE s-voice'));
        expect(result.requireEvidence, isTrue);
        expect(result.medicines.single.citations.single.sourceId, 's-voice');
      },
    );
    test(
      'model IDs, review approvals and meal links are ignored; manual facts survive',
      () async {
        final p = course();
        model.result = {
          ...p.toJson(),
          'resolved_fields': {'title': '0' * 64},
          'medicines': [
            {
              ...p.medicines.first.toJson(),
              'amount': '9',
              'id': 'model-owned',
              'resolved_fields': {'amount': '0' * 64},
              'meal_links': [
                {'meal_id': 'bad', 'offset': 99},
              ],
            },
          ],
        };
        final result = await extract({
          ...p.toJson(),
          'source': 'Fixture text',
        }, []);
        expect(result.id, p.id);
        expect(result.medicines.single.id, 'medicine');
        expect(result.medicines.single.amount, '1');
        expect(result.medicines.single.mealLinks.single.mealId, 'breakfast');
        expect(result.medicines.single.resolvedFields, isEmpty);
        expect(result.resolvedFields, isEmpty);
        expect(result.meals.single.time, '08:00');
      },
    );
    test(
      'missing, wrong-kind, too many sources stop before a model request',
      () async {
        for (final draft in [
          {...MedicationPlan().toJson(), 'record_id': 'absent'},
          {
            ...MedicationPlan().toJson(),
            'sources': [
              const MedicationSource(
                id: 'x',
                kind: 'image',
                label: 'x',
                recordId: 'x',
              ).toJson(),
            ],
          },
          {
            ...MedicationPlan().toJson(),
            'sources': List.filled(
              9,
              const MedicationSource(
                id: 'x',
                kind: 'text',
                label: 'x',
              ).toJson(),
            ),
          },
        ]) {
          await expectLater(
            extract(draft, [record('x', 'text', 'text')]),
            throwsFormatException,
          );
        }
        expect(model.calls, 0);
      },
    );
    test('changed generation discards a delayed AI response', () async {
      var current = true;
      model.barrier = Completer<void>();
      final pending = extract(
        {...MedicationPlan().toJson(), 'source': 'Fixture'},
        [],
        current: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      model.barrier!.complete();
      await expectLater(pending, throwsStateError);
    });
    test('two images retain separate source labels in one proposal', () async {
      final image = await File(
        '${temp.path}/label.png',
      ).writeAsBytes([137, 80, 78, 71]);
      final rows = [
        record('one', 'image', image.path),
        record('two', 'image', image.path),
      ];
      final result = await extract({
        ...MedicationPlan().toJson(),
        'sources': [
          for (final r in rows)
            MedicationSource(
              id: 's-${r.id}',
              kind: r.type,
              label: r.id,
              recordId: r.id,
            ).toJson(),
        ],
      }, rows);
      expect(result.sources.map((s) => s.id), ['s-one', 's-two']);
      expect(
        (model.content as List).where((c) => c['type'] == 'image_url'),
        hasLength(2),
      );
      expect(model.calls, 1);
    });
    test('oversized source files fail before model processing', () async {
      for (final entry in [
        ('image', MedicationReviewService.maxImageBytes),
        ('audio', MedicationReviewService.maxAudioBytes),
      ]) {
        final file = File('${temp.path}/${entry.$1}.bin');
        final writer = await file.open(mode: FileMode.write);
        await writer.truncate(entry.$2 + 1);
        await writer.close();
        final row = record(entry.$1, entry.$1, file.path);
        await expectLater(
          extract({...MedicationPlan().toJson(), 'record_id': row.id}, [row]),
          throwsFormatException,
        );
      }
      expect(model.calls, 0);
      expect(model.audioCalls, 0);
    });
    test(
      'invented text quotes and duplicate medicine candidates never silently enable',
      () async {
        final p = course();
        model.result = {
          ...p.toJson(),
          'medicines': [
            {
              ...medicine(links: const [], times: const ['08:00']).toJson(),
              'provenance': [
                {
                  'field': 'amount',
                  'source_id': 'manual',
                  'value': '1',
                  'quote': 'invented',
                },
              ],
            },
          ],
        };
        await expectLater(
          extract({
            ...MedicationPlan().toJson(),
            'source': 'Original text',
          }, []),
          throwsFormatException,
        );
        model.result = {
          ...p.toJson(),
          'medicines': [
            for (var i = 0; i < 2; i++)
              medicine(links: const [], times: const ['08:00']).toJson(),
          ],
        };
        final result = await extract({
          ...MedicationPlan().toJson(),
          'source': 'Original text',
        }, []);
        expect(result.medicines.every((m) => m.unresolved.isNotEmpty), isTrue);
        expect(result.issues, isNotEmpty);
      },
    );
  });
  group('durable changes', () {
    late OfflineManagementHarness h;
    setUp(() async {
      h = OfflineManagementHarness();
      await h.create();
    });
    tearDown(() => h.dispose());
    Future<void> save(MedicationPlan p, {Reminder? baseline}) async {
      final built = p.build(now: DateTime.now());
      await h.notifier.saveRoutine(
        built.owner,
        built.doses,
        h.database.captureGeneration(),
        baseline: baseline,
      );
    }

    test(
      'taken dose stays protected across repeated meal changes and new slots remain schedulable',
      () async {
        final start = DateTime.now().add(const Duration(days: 2));
        MedicationPlan at(List<String> times) => MedicationPlan(
          id: 'course',
          title: 'Fixture',
          start: start,
          end: start,
          medicines: [medicine(times: times, links: const [])],
        );
        await save(at(['07:00', '19:00']));
        final first = (await h.rows()).firstWhere(
          (r) => r.details.kind == 'medication' && r.triggerTime!.hour == 7,
        );
        await h.notifier.recordDoseTakenAt(
          first,
          DateTime.now(),
          h.database.captureGeneration(),
        );
        final history = (await h.row(first.id)).toJson();
        await save(at(['08:00', '20:00']), baseline: await h.row('course'));
        await save(
          at(['09:00', '18:00', '21:00']),
          baseline: await h.row('course'),
        );
        final active = (await h.rows())
            .where(
              (r) =>
                  r.details.kind == 'medication' &&
                  r.isVisible &&
                  !r.isCompleted,
            )
            .toList();
        expect(active.map((r) => r.triggerTime!.hour).toList()..sort(), [
          18,
          21,
        ]);
        expect((await h.row(first.id)).toJson(), history);
      },
    );
    test(
      'departure refill after date edits and reopening never revives an excluded day',
      () async {
        final now = DateTime.now();
        final first = departure().schedule(now).occurrences.first;
        final p = departure(
          exceptions: CalendarExceptions(
            skip: [CalendarExceptions.key(first.eventTime!)],
          ),
        );
        final built = p.schedule(now);
        await h.notifier.saveRoutine(
          built.owner,
          built.occurrences,
          h.database.captureGeneration(),
        );
        await h.notifier.refreshDepartureSchedules(now: now);
        expect((await h.rows()).any((r) => r.id == first.id), isFalse);
        final before = (await h.rows()).map((r) => r.toJson()).toList();
        await h.close();
        await h.open();
        await h.notifier.refreshDepartureSchedules(now: now);
        expect((await h.rows()).map((r) => r.toJson()).toList(), before);
        await h.notifier.refreshDepartureSchedules(
          now: DateTime(now.year, now.month, now.day + 15),
        );
        expect((await h.rows()).any((r) => r.id == first.id), isFalse);
        expect(
          (await h.rows()).map((r) => r.id).toSet().length,
          (await h.rows()).length,
        );
      },
    );
    test(
      'monthly extra reminder aligns event day when its alarm precedes midnight',
      () async {
        final base = DateTime(2030, 1, 30, 23, 55);
        final row = Reminder(
          id: 'monthly',
          taskTitle: 'Fixture',
          quadrantLevel: 2,
          createdAt: DateTime.now(),
          triggerTime: base,
          eventTime: DateTime(2030, 1, 31, 0, 5),
          isRecurring: true,
          recurrenceRule: 'monthly',
          detailsJson: TaskDetails(
            repeat: RepeatWindow(
              anchor: base,
              exceptions: const CalendarExceptions(add: ['2030-02-02']),
            ),
          ).encode(),
        );
        await h.seed(row);
        await h.notifier.completeOccurrence(row, now: base);
        final next = await h.row(row.id);
        expect(next.triggerTime, DateTime(2030, 2, 2, 23, 55));
        expect(next.eventTime, DateTime(2030, 2, 3, 0, 5));
        await h.notifier.completeOccurrence(next, now: next.triggerTime);
        final regular = await h.row(row.id);
        expect(regular.triggerTime, DateTime(2030, 2, 28, 23, 55));
        expect(regular.eventTime, DateTime(2030, 3, 1, 0, 5));
      },
    );

    test(
      'meal changes cancel future clocks and preserve completed historical snapshots',
      () async {
        final day = DateTime.now().add(const Duration(days: 2));
        final p = course(
          start: day,
          end: DateTime(day.year, day.month, day.day + 2),
        );
        await save(p);
        final rows = await h.rows();
        final first = rows.where((r) => r.details.kind == 'medication').first;
        await h.notifier.recordDoseTakenAt(
          first,
          DateTime.now(),
          h.database.captureGeneration(),
        );
        final history = (await h.row(first.id)).toJson();
        final beforeOwner = await h.row('course');
        await save(
          course(clock: '09:00', start: p.start, end: p.end),
          baseline: beforeOwner,
        );
        expect((await h.row(first.id)).toJson(), history);
        final future = (await h.rows())
            .where(
              (r) =>
                  r.details.kind == 'medication' &&
                  r.isVisible &&
                  !r.isCompleted,
            )
            .toList();
        expect(future, hasLength(2));
        expect(
          future.every(
            (r) => r.triggerTime!.hour == 8 && r.triggerTime!.minute == 30,
          ),
          isTrue,
        );
        final obsolete = rows.where(
          (r) => r.id != first.id && r.details.kind == 'medication',
        );
        expect(
          h.notifications.cancelled,
          containsAll(obsolete.map((r) => r.id)),
        );
        await h.close();
        await h.open();
        expect((await h.row(first.id)).toJson(), history);
        expect(
          MedicationPlan.fromJson(
            (await h.row('course')).details.data,
          ).meals.single.time,
          '09:00',
        );
      },
    );
    test(
      'date edits cancel removed departure days; explicit save can restore future dates',
      () async {
        final now = DateTime.now();
        final p = departure();
        final initial = p.schedule(now);
        await h.notifier.saveRoutine(
          initial.owner,
          initial.occurrences,
          h.database.captureGeneration(),
        );
        final day = initial.occurrences.first.eventTime!;
        final changed = departure(
          exceptions: CalendarExceptions(skip: [CalendarExceptions.key(day)]),
        ).schedule(now);
        await h.notifier.saveRoutine(
          changed.owner,
          changed.occurrences,
          h.database.captureGeneration(),
          baseline: await h.row('departure'),
        );
        expect((await h.row(initial.occurrences.first.id)).isVisible, isFalse);
        expect(
          h.notifications.cancelled,
          contains(initial.occurrences.first.id),
        );
        final unchanged = await h.row('departure');
        await h.notifier.saveRoutine(
          initial.owner,
          initial.occurrences,
          h.database.captureGeneration(),
          baseline: unchanged,
        );
        expect((await h.row(initial.occurrences.first.id)).isVisible, isTrue);
      },
    );
    test(
      'routine transaction rollback and stale generation preserve original facts',
      () async {
        final day = DateTime.now().add(const Duration(days: 2));
        final p = course(start: day, end: day);
        await save(p);
        final before = (await h.rows()).map((r) => r.toJson()).toList();
        final db = await h.database.database;
        await db.execute(
          "CREATE TRIGGER fail_meal BEFORE UPDATE ON Reminders BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END",
        );
        await expectLater(
          save(
            course(clock: '09:00', start: day, end: day),
            baseline: await h.row('course'),
          ),
          throwsA(isA<DatabaseException>()),
        );
        expect((await h.rows()).map((r) => r.toJson()).toList(), before);
        await db.execute('DROP TRIGGER fail_meal');
        final generation = h.database.captureGeneration();
        final lease = await h.database.beginMaintenance();
        await lease.resume();
        final built = p.build(now: DateTime.now());
        await expectLater(
          h.notifier.saveRoutine(built.owner, built.doses, generation),
          throwsA(isA<DatabaseAccessException>()),
        );
        expect((await h.rows()).map((r) => r.toJson()).toList(), before);
      },
    );
    test(
      'notification failure keeps committed meal plan and reports separate retryable failure',
      () async {
        final day = DateTime.now().add(const Duration(days: 2));
        final built = course(start: day, end: day).build(now: DateTime.now());
        h.notifications.fail = true;
        final result = await h.notifier.saveRoutine(
          built.owner,
          built.doses,
          h.database.captureGeneration(),
        );
        expect(result.nativeSyncFailures, greaterThan(0));
        expect((await h.row('course')).details.toJson()['version'], 2);
        h.notifications.fail = false;
        expect((await h.notifier.retryNotificationDelivery()).failed, 0);
      },
    );
    for (final format in ['json', 'sqlite']) {
      test(
        '$format actual restore retains meal evidence and date exceptions exactly',
        () async {
          final day = DateTime.now().add(const Duration(days: 2));
          final raw = course(start: day, end: day).toJson();
          raw['sources'] = [
            const MedicationSource(
              id: 'label',
              kind: 'text',
              label: 'Label',
              text: 'one tablet',
            ).toJson(),
            const MedicationSource(
              id: 'order',
              kind: 'audio',
              label: 'Order transcript',
              text: 'two tablets',
            ).toJson(),
          ];
          final med = raw['medicines'][0] as Map<String, dynamic>;
          const citations = [
            MedicationCitation(
              field: 'amount',
              sourceId: 'label',
              value: '1',
              quote: 'one tablet',
            ),
            MedicationCitation(
              field: 'amount',
              sourceId: 'order',
              value: '2',
              quote: 'two tablets',
            ),
          ];
          med['provenance'] = citations.map((e) => e.toJson()).toList();
          med['resolved_fields'] = {
            'amount': MedicationFacts.fingerprint('amount', '1', citations),
          };
          await save(MedicationPlan.fromJson(raw));
          final departureRows = departure(
            exceptions: CalendarExceptions(add: [CalendarExceptions.key(day)]),
          ).schedule(DateTime.now());
          await h.notifier.saveRoutine(
            departureRows.owner,
            departureRows.occurrences,
            h.database.captureGeneration(),
          );
          final repeat = Reminder(
            id: 'repeat',
            taskTitle: 'Repeat',
            quadrantLevel: 2,
            createdAt: DateTime.now(),
            triggerTime: day,
            eventTime: day,
            isRecurring: true,
            recurrenceRule: 'daily',
            detailsJson: TaskDetails(
              repeat: RepeatWindow(
                anchor: day,
                exceptions: CalendarExceptions(
                  skip: [
                    CalendarExceptions.key(
                      DateTime(day.year, day.month, day.day + 1),
                    ),
                  ],
                ),
              ),
            ).encode(),
          );
          await h.seed(repeat);
          final before = (await h.rows()).map((r) => r.toJson()).toList();
          await h.database.createMirrorBackup();
          final source = await File(
            '${h.directory.path}/${format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db'}',
          ).copy('${h.directory.path}/source-$format');
          final inspector = BackupInspector(databaseFactoryFfi);
          final preview = await inspector.inspect(source);
          expect(preview.version, 16);
          await h.seed(
            Reminder(
              id: 'later',
              taskTitle: 'Later',
              quadrantLevel: 2,
              createdAt: DateTime.now(),
            ),
          );
          await DatabaseRecovery(
            h.database,
            inspector: inspector,
            notifications: NotificationService.forTesting(
              FlutterLocalNotificationsPlugin(),
              usesNativeNotifications: false,
            ),
          ).restore(source, expectedDigest: preview.digest);
          expect((await h.rows()).map((r) => r.toJson()).toList(), before);
          await h.close();
          await h.open();
          expect((await h.rows()).map((r) => r.toJson()).toList(), before);
        },
      );
    }
  });
}
