import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/data_export_service.dart';
import 'package:dont_forget/services/context_trigger_service.dart';
import 'package:dont_forget/ui/widgets/context_digest_sheet.dart';
import 'package:dont_forget/ui/widgets/data_export_sheet.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/interaction_preview.dart';

class _Tasks extends RemindersNotifier {
  _Tasks(super.db) : super(runLoadEffects: false);
  void replace(List<Reminder> tasks) => state = tasks;
  int calls = 0;
  Completer<ReminderActionResult>? pending;
  @override
  Future<ReminderActionResult> completeOccurrence(
    Reminder expected, {
    DateTime? now,
  }) {
    calls++;
    return pending!.future;
  }
}

class _Counted extends ListBase<Reminder> {
  _Counted(this.items);
  final List<Reminder> items;
  int reads = 0;
  @override
  int get length => items.length;
  @override
  set length(int _) => throw UnsupportedError('immutable');
  @override
  Reminder operator [](int i) {
    reads++;
    return items[i];
  }

  @override
  void operator []=(int i, Reminder v) => throw UnsupportedError('immutable');
}

class _Export extends DataExportService {
  int calls = 0;
  String? localeRead;
  Completer<Uri?>? pending;
  bool fail = false;
  @override
  Future<Uri?> saveWithDialog(
    List<Reminder> tasks, {
    required String locale,
    required String title,
    bool Function()? isCurrent,
  }) async {
    calls++;
    localeRead = locale;
    if (fail) throw StateError('secret diagnostics');
    return pending?.future;
  }
}

void main() {
  test('digest badge and page share active occurrences in linear reads', () {
    final service = ContextTriggerService();
    service.clearSuppressed();
    addTearDown(service.clearSuppressed);
    final old = Reminder(id: 'one', taskTitle: 'old', quadrantLevel: 3);
    final latest = old.copyWith(noticeRevision: 1, taskTitle: 'latest');
    service.recordSuppressed(latest);
    final saved = _Counted([
      latest,
      Reminder(
        id: 'done',
        taskTitle: 'done',
        quadrantLevel: 3,
        isCompleted: true,
      ),
      Reminder(
        id: 'changed',
        taskTitle: 'changed',
        quadrantLevel: 3,
        noticeRevision: 2,
      ),
      ...List.generate(
        10000,
        (i) => Reminder(id: 'other-$i', taskTitle: 'Other', quadrantLevel: 3),
      ),
    ]);
    final result = service.activeDigest(
      saved,
      previous: [
        old,
        Reminder(id: 'done', taskTitle: 'before completion', quadrantLevel: 3),
        Reminder(
          id: 'changed',
          taskTitle: 'before rescheduling',
          quadrantLevel: 3,
        ),
        Reminder(id: 'deleted', taskTitle: 'deleted', quadrantLevel: 3),
      ],
    );
    expect(result.map((r) => r.taskTitle), ['latest']);
    expect(saved.reads, saved.length);
  });
  setUpAll(loadInteractionPreviewFonts);
  late Directory directory;
  late DatabaseHelper database;
  late _Tasks tasks;
  late _Export exporter;
  late ProviderContainer container;
  Reminder task(int i) => Reminder(
    id: 'digest-$i',
    taskTitle: 'Task $i',
    taskSummary: 'Details\nSecond line',
    quadrantLevel: 3,
    noticeRevision: 0,
    triggerTime: DateTime(2026, 10, 20),
  );
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('digest-export-');
    database = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
    tasks = _Tasks(database);
    await tasks.ready;
    exporter = _Export();
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        remindersProvider.overrideWith((_) => tasks),
        dataExportServiceProvider.overrideWithValue(exporter),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });
  Future<void> show(
    WidgetTester tester,
    Widget child, {
    String lang = 'zh',
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(lang),
          supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: InlineFeedback(
              child: RepaintBoundary(key: interactionPreviewKey, child: child!),
            ),
          ),
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'digest follows edits, deletion and occurrence changes without repeating completion',
    (tester) async {
      final original = task(0);
      tasks.replace([original]);
      await show(tester, ContextDigestSheet(digestReminders: [original]));
      tasks.replace([original.copyWith(taskTitle: 'Updated title')]);
      await tester.pumpAndSettle();
      expect(find.text('Q3 · Updated title'), findsOneWidget);
      tasks.pending = Completer();
      final button = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == '标为已完成',
      );
      final action = tester.widget<IconButton>(button).onPressed!;
      action();
      action();
      await tester.pump();
      expect(tasks.calls, 1);
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      tasks.pending!.complete(
        ReminderActionResult(
          ReminderActionDisposition.applied,
          reminder: original.copyWith(isCompleted: true),
        ),
      );
      await tester.pumpAndSettle();
      action();
      expect(tasks.calls, 1);
      expect(find.text('本次摘要没有待处理任务。'), findsOneWidget);
    },
  );
  testWidgets(
    'digest removes a rescheduled occurrence and virtualizes ten thousand rows',
    (tester) async {
      final data = _Counted(List.generate(10000, task));
      tasks.replace(data);
      await show(tester, ContextDigestSheet(digestReminders: data));
      expect(find.byType(Card).evaluate().length, lessThan(20));
      final reads = data.reads;
      tasks.pending = Completer();
      tester
          .widget<IconButton>(
            find
                .byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '标为已完成',
                )
                .first,
          )
          .onPressed!();
      await tester.pump();
      expect(data.reads, reads);
      tasks.pending!.completeError(StateError('failure'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          AppLocalizations(const Locale('zh')).get('reminderUpdateFailed'),
        ),
        findsOneWidget,
      );
      expect(find.byType(Card), findsWidgets);
      tasks.replace([task(0).copyWith(noticeRevision: 1)]);
      await tester.pumpAndSettle();
      expect(find.text('本次摘要没有待处理任务。'), findsOneWidget);
      tasks.replace([]);
      await tester.pumpAndSettle();
      expect(find.text('本次摘要没有待处理任务。'), findsOneWidget);
    },
  );
  testWidgets(
    'export disables empty and duplicate submissions; cancel failure retry and saved path are explicit',
    (tester) async {
      await show(tester, const DataExportSheet(), lang: 'ja');
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      tasks.replace([task(0)]);
      await tester.pumpAndSettle();
      exporter.pending = Completer();
      final action = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      action();
      action();
      await tester.pump();
      expect(exporter.calls, 1);
      expect(exporter.localeRead, 'ja');
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      exporter.pending!.complete(null);
      await tester.pumpAndSettle();
      expect(
        find.text(AppLocalizations(const Locale('ja')).get('exportCancelled')),
        findsOneWidget,
      );
      exporter.fail = true;
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.textContaining('secret'), findsNothing);
      expect(
        find.text(AppLocalizations(const Locale('ja')).get('exportFailed')),
        findsOneWidget,
      );
      exporter.fail = false;
      exporter.pending = Completer()
        ..complete(Uri.file('/tmp/task-export.csv'));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('/tmp/task-export.csv'), findsOneWidget);
    },
  );
  testWidgets('late export result after recovery is discarded', (tester) async {
    tasks.replace([task(0)]);
    await show(tester, const DataExportSheet());
    exporter.pending = Completer();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await container.read(runtimeRecoveryGateProvider).pause();
    exporter.pending!.complete(Uri.file('/tmp/old.csv'));
    await tester.pumpAndSettle();
    expect(find.text('/tmp/old.csv'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
  for (final width in [375.0, 768.0, 1440.0]) {
    for (final lang in ['zh', 'en', 'ja']) {
      for (final export in [true, false]) {
        testWidgets(
          '${export ? 'export' : 'digest'} $width $lang large text short window',
          (tester) async {
            tester.view.physicalSize = Size(width, 650);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final items = [task(0), task(1)];
            tasks.replace(items);
            await show(
              tester,
              export
                  ? const DataExportSheet()
                  : ContextDigestSheet(digestReminders: items),
              lang: lang,
              scale: 2,
            );
            expect(tester.takeException(), isNull);
            await captureInteractionPreview(
              tester,
              '${export ? 'export' : 'digest'}-${width.toInt()}-$lang',
            );
            tester.view.physicalSize = Size(width, 360);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            if (export) {
              await tester.ensureVisible(find.byType(FilledButton));
              expect(find.byType(FilledButton).hitTestable(), findsOneWidget);
            }
          },
        );
      }
    }
  }
}
