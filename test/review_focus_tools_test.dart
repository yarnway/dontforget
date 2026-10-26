import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/spaced_repetition_service.dart';
import 'package:dont_forget/ui/widgets/focus_mode_sheet.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/spaced_repetition_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/interaction_preview.dart';

class _Tasks extends RemindersNotifier {
  _Tasks(super.db) : super(runLoadEffects: false);
  void replace(List<Reminder> tasks) => state = tasks;
}

class _Counted extends ListBase<Reminder> {
  _Counted(this.items);
  final List<Reminder> items;
  int reads = 0;
  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  Reminder operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, Reminder value) =>
      throw UnsupportedError('immutable');
}

class _Notifications implements NotificationService {
  final calls = <bool>[];
  Completer<({int attempted, int failed})>? pending;
  @override
  Future<({int attempted, int failed})> applyFocusMode(bool enabled) {
    calls.add(enabled);
    return pending?.future ?? Future.value((attempted: 0, failed: 0));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profile extends ContextProfileNotifier {
  _Profile(DatabaseHelper database, NotificationService notifications)
    : super(ContextTriggerService(), database, notifications);
  void replace(ContextProfile value) => state = value;
}

void main() {
  setUpAll(loadInteractionPreviewFonts);
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late _Tasks tasks;
  late _Notifications notifications;
  late _Profile profile;
  Reminder card(int index, {DateTime? next}) => Reminder(
    id: 'review-$index',
    taskTitle: 'Review card $index',
    taskSummary: 'Answer line one\nAnswer line two',
    subTasks: '["Step one","Step two"]',
    quadrantLevel: 2,
    spacedRepetitionLevel: 1,
    nextReviewAt: next ?? DateTime(2020),
  );
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('review-focus-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    tasks = _Tasks(database);
    await tasks.ready;
    notifications = _Notifications();
    profile = _Profile(database, notifications)
      ..replace(ContextProfile.general);
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        remindersProvider.overrideWith((_) => tasks),
        notificationServiceProvider.overrideWithValue(notifications),
        contextProfileProvider.overrideWith((_) => profile),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });
  Future<void> open(
    WidgetTester tester,
    Widget body, {
    String language = 'zh',
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: InlineFeedback(
              child: RepaintBoundary(key: interactionPreviewKey, child: child!),
            ),
          ),
          home: Scaffold(body: Center(child: body)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'queue reuses ten thousand tasks and expires on date or source change',
    () {
      final source = _Counted(
        List.generate(10000, (i) => card(i, next: DateTime(2026, 10, 27))),
      );
      const service = SpacedRepetitionService();
      final cache = ReviewQueueCache();
      final before = cache.read(
        source,
        service,
        now: DateTime(2026, 10, 26, 23, 59),
      );
      expect(before.due, isEmpty);
      expect(before.total, 10000);
      final reads = source.reads;
      for (var i = 0; i < 50; i++) {
        expect(
          cache.read(source, service, now: DateTime(2026, 10, 26, 23, 59, 30)),
          same(before),
        );
      }
      expect(source.reads, reads);
      expect(
        cache.read(source, service, now: DateTime(2026, 10, 27)).due,
        hasLength(10000),
      );
      expect(source.reads, reads * 2);
      expect(
        cache
            .read([card(1)], service, now: DateTime(2026, 10, 27))
            .due
            .single
            .id,
        'review-1',
      );
    },
  );
  testWidgets(
    'flipping a ten-thousand-card deck does not rescan; replacing first card hides answer',
    (tester) async {
      final source = _Counted(List.generate(10000, card));
      tasks.replace(source);
      await open(tester, const SpacedRepetitionSheet());
      final reads = source.reads;
      await tester.tap(find.byKey(const ValueKey('review-flip')));
      await tester.pumpAndSettle();
      expect(find.text('Answer line one\nAnswer line two'), findsOneWidget);
      expect(source.reads, reads);
      tasks.replace([card(1)]);
      await tester.pumpAndSettle();
      expect(find.text('Review card 1'), findsOneWidget);
      expect(find.text('Answer line one\nAnswer line two'), findsNothing);
    },
  );
  testWidgets(
    'focus pending state, partial failure, retry and context exception stay explicit',
    (tester) async {
      await open(tester, const FocusModeSheet());
      expect(find.text('专注已关闭'), findsOneWidget);
      notifications.pending = Completer();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(notifications.calls, [true]);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      expect(find.text('正在更新提醒安排…'), findsOneWidget);
      notifications.pending!.complete((attempted: 2, failed: 1));
      await tester.pumpAndSettle();
      expect(find.text('专注已开启'), findsOneWidget);
      final retry = find.text('重试应用策略');
      await tester.ensureVisible(retry);
      notifications.pending = null;
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(notifications.calls, [true, true]);
      expect(find.text('提醒安排已处理，实际送达仍受系统权限和策略影响。'), findsOneWidget);
      profile.replace(ContextProfile.office);
      await tester.pumpAndSettle();
      expect(find.textContaining('办公或深度专注'), findsOneWidget);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.text('专注已关闭'), findsOneWidget);
      expect(find.textContaining('办公或深度专注'), findsOneWidget);
    },
  );
  for (final width in [375.0, 768.0, 1440.0]) {
    for (final language in ['zh', 'en', 'ja']) {
      for (final focus in [false, true]) {
        testWidgets(
          '${focus ? 'focus' : 'review'} $width $language fits large text and short windows',
          (tester) async {
            tester.view.physicalSize = Size(width, 650);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            tasks.replace([card(0)]);
            await open(
              tester,
              focus ? const FocusModeSheet() : const SpacedRepetitionSheet(),
              language: language,
              scale: 2,
              brightness: width == 768 ? Brightness.dark : Brightness.light,
            );
            expect(tester.takeException(), isNull);
            if (!focus) {
              final flip = find.byKey(const ValueKey('review-flip'));
              await tester.ensureVisible(flip);
              expect(flip.hitTestable(), findsOneWidget);
              await tester.tap(flip);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
            await captureInteractionPreview(
              tester,
              '${focus ? 'focus' : 'review'}-${width.toInt()}-$language',
            );
            tester.view.physicalSize = Size(width, 360);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            if (!focus) {
              final remembered = find.widgetWithText(
                ElevatedButton,
                AppLocalizations(Locale(language)).get('markRemembered'),
              );
              await tester.ensureVisible(remembered);
              expect(remembered.hitTestable(), findsOneWidget);
            }
          },
        );
      }
    }
  }
}
