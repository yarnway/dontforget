import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/study_plan.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/study_plan_service.dart';
import 'package:dont_forget/ui/widgets/study_plan_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Model extends StudyPlanService {
  Completer<StudyPlan>? pending;
  bool fail = false;
  @override
  Future<StudyPlan> generate(
    StudyRequest request,
    AppSettings settings, {
    required CancelToken cancelToken,
  }) async {
    if (fail) throw StateError('Synthetic model failure');
    if (pending != null) return pending!.future;
    return StudyPlan(
      batches: [
        const StudyBatch(
          title: 'Synthetic batch',
          content: 'recall — remember\nTry to recall the word.',
        ),
      ],
      modelLabel: 'Synthetic',
    );
  }
}

void main() {
  late Directory root;
  late DatabaseHelper database;
  late ProviderContainer container;
  late StudyPlanDraft draft;
  late _Model model;
  setUp(() async {
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('study-panel-');
    database = DatabaseHelper.forTesting(root.path, databaseFactoryFfi);
    model = _Model();
    draft = StudyPlanDraft();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        studyPlanServiceProvider.overrideWithValue(model),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
  });
  tearDown(() async {
    container.dispose();
    draft.dispose();
    model.dispose();
    await database.close(createBackup: false);
    await root.delete(recursive: true);
  });
  Widget app({
    String language = 'en',
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: StudyPlanPanel(
            draft: draft,
            onClose: () {},
            onBusyChanged: (_) {},
            onReview: () {},
          ),
        ),
      ),
    ),
  );
  for (final language in ['en', 'zh', 'ja']) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '$language $brightness $scale fits 320 width and a keyboard-height viewport',
          (tester) async {
            tester.view.physicalSize = const Size(320, 480);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              app(language: language, brightness: brightness, scale: scale),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            draft.plan = StudyPlan(
              batches: [
                const StudyBatch(
                  title: 'Vocabulary',
                  content: 'A synthetic editable word and example.',
                ),
              ],
            );
            draft.edited = draft.plan!.batches.toList();
            draft.firstReminder = DateTime.now().add(const Duration(days: 1));
            draft.changed();
            await tester.pumpAndSettle();
            await tester.ensureVisible(
              find.byKey(const ValueKey('study-save')),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }
  testWidgets(
    'generation is preview-only, edits survive panel reopen, discard is explicit',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('study-generate')));
      await tester.tap(find.byKey(const ValueKey('study-generate')));
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(draft.plan, isNotNull);
      expect(
        await tester.runAsync(
          () async => (await database.database).query('Reminders'),
        ),
        isEmpty,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('study-title-0')));
      await tester.enterText(
        find.byKey(const ValueKey('study-title-0')),
        'Edited title',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('study-edit-0')));
      await tester.tap(find.byKey(const ValueKey('study-edit-0')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('study-content-0')),
        'recall — 回想\nRecall an example.',
      );
      await tester.tap(find.byKey(const ValueKey('study-edit-0')));
      await tester.pump();
      expect(find.text('recall'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(draft.edited.single.title, 'Edited title');
      expect(draft.edited.single.content, 'recall — 回想\nRecall an example.');
      final loc = AppLocalizations(const Locale('en'));
      await tester.ensureVisible(find.text(loc.get('studyStartOver')));
      await tester.tap(find.text(loc.get('studyStartOver')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(loc.get('keepEditing')));
      await tester.pumpAndSettle();
      expect(draft.plan, isNotNull);
      await tester.tap(find.text(loc.get('studyStartOver')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(loc.get('discardChanges')));
      await tester.pumpAndSettle();
      expect(draft.plan, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'failed generation keeps preferences; cancel rejects a late response',
    (tester) async {
      draft.notes = 'Synthetic preference';
      model.fail = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('study-generate')));
      await tester.tap(find.byKey(const ValueKey('study-generate')));
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(draft.feedback, 'studyGenerateFailed');
      expect(draft.notes, 'Synthetic preference');
      model.fail = false;
      model.pending = Completer<StudyPlan>();
      await tester.tap(find.byKey(const ValueKey('study-generate')));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      draft.request!.cancel();
      model.pending!.complete(
        StudyPlan(
          batches: [const StudyBatch(title: 'Late', content: 'Discard')],
        ),
      );
      await tester.pumpAndSettle();
      expect(draft.plan, isNull);
      expect(draft.busy, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('Cmd-S cannot save an incomplete or past preview', (
    tester,
  ) async {
    draft.plan = StudyPlan(
      batches: [const StudyBatch(title: '', content: '')],
    );
    draft.edited = draft.plan!.batches.toList();
    draft.firstReminder = DateTime(2000);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-title-0')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(draft.feedback, 'studyCheckPreview');
    expect(draft.saved, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
