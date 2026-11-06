import 'dart:io';
import 'support/interaction_preview.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/services/local_media_store.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/models/task_metadata_patch.dart';
import 'package:dont_forget/models/task_template.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/task_templates_provider.dart';
import 'package:dont_forget/services/content/content_cleanup_service.dart';
import 'package:dont_forget/services/task_template_file_service.dart';
import 'package:dont_forget/ui/widgets/content_management_panel.dart';
import 'package:dont_forget/ui/widgets/task_metadata_dialog.dart';
import 'package:dont_forget/ui/widgets/task_template_library.dart';
import 'package:dont_forget/ui/widgets/task_template_transfer_dialog.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';
import 'support/workspace_drafts.dart';

const imported = TaskTemplate(
  id: 'remote',
  name: 'Travel',
  title: 'Pack',
  items: ['Passport'],
);

class _Files extends TaskTemplateFileService {
  int saved = 0;
  @override
  Future<List<TaskTemplate>?> pick() async => [imported];
  @override
  Future<bool> save(List<TaskTemplate> items) async {
    saved++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  late Directory docs;
  late ContentCleanupService service;
  late _Files files;
  setUpAll(loadInteractionPreviewFonts);
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    docs = await Directory('${h.directory.path}/Documents').create();
    service = ContentCleanupService(
      h.database,
      docs,
      clock: () => DateTime(2032),
    );
    files = _Files();
  });
  tearDown(() => h.dispose());
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 300; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (i >= 18 && find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  Future<void> host(
    WidgetTester tester,
    Widget child, {
    double width = 375,
    String locale = 'zh',
    double scale = 1,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: ProviderScope(
          overrides: [
            contentCleanupServiceProvider.overrideWithValue(
              Future.value(service),
            ),
            taskTemplateFileServiceProvider.overrideWithValue(files),
          ],
          child: RepaintBoundary(
            key: interactionPreviewKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: Locale(locale),
              supportedLocales: const [
                Locale('zh'),
                Locale('en'),
                Locale('ja'),
              ],
              localizationsDelegates: const [
                AppLocalizationsDelegate(),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: const bool.fromEnvironment('UI_PREVIEW')
                  ? AppTheme.dark
                  : ThemeData(brightness: Brightness.dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  viewInsets: EdgeInsets.only(bottom: keyboard),
                ),
                child: InlineFeedback(child: child!),
              ),
              home: Scaffold(body: child),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  Widget launch(Widget dialog) => Builder(
    builder: (context) => TextButton(
      key: const ValueKey('open'),
      onPressed: () =>
          showDialog<void>(context: context, builder: (_) => dialog),
      child: const Text('Open'),
    ),
  );
  testWidgets(
    'storage summary filters referenced files and selects only visible eligible content',
    (tester) async {
      late File external;
      late String owned;
      await tester.runAsync(() async {
        external = await File(
          '${h.directory.path}/sample.bin',
        ).writeAsBytes(List.filled(4096, 7));
        owned = await LocalMediaStore(
          documentsDirectory: () async => docs,
        ).importFile(external.path);
        await h.container
            .read(mediaRecordsProvider.notifier)
            .addRecord(
              MediaRecord(
                id: 'reclaim',
                type: 'image',
                contentOrPath: owned,
                createdAt: DateTime(2020),
              ),
            );
        await h.container
            .read(mediaRecordsProvider.notifier)
            .addRecord(
              MediaRecord(
                id: 'protected',
                type: 'text',
                contentOrPath: 'Referenced note',
                createdAt: DateTime(2020),
              ),
            );
        await h.container
            .read(remindersProvider.notifier)
            .addReminder(
              Reminder(
                id: 'retain-task',
                recordId: 'protected',
                taskTitle: 'Retain',
                quadrantLevel: 2,
              ),
            );
      });
      await host(tester, const ContentManagementPanel());
      await tap(tester, const ValueKey('content-scan'));
      expect(find.text('当前可清理 1 项，约 4.00 KiB'), findsOneWidget);
      await tap(tester, const ValueKey('content-eligible-only'));
      expect(
        find.byKey(const ValueKey('content-entry:record:protected')),
        findsNothing,
      );
      await tap(tester, const ValueKey('content-select-visible'));
      expect(find.text('已选 1 项，约可释放 4.00 KiB'), findsOneWidget);
      await captureInteractionPreview(tester, 'content-space-63-selected');
      await tap(tester, const ValueKey('content-clear-selection'));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('content-clean')))
            .onPressed,
        isNull,
      );
      expect(await tester.runAsync(() => File(owned).exists()), isTrue);
      expect(await tester.runAsync(() => external.exists()), isTrue);
      expect(h.container.read(mediaRecordsProvider), hasLength(2));
      await finish(tester);
    },
  );

  testWidgets(
    'bulk eligible selection respects the 100 item limit without deleting',
    (tester) async {
      await tester.runAsync(() async {
        await h.database.writeTransaction(h.database.captureGeneration(), (
          db,
        ) async {
          for (var i = 0; i < 103; i++) {
            await db.insert(
              'MediaRecords',
              MediaRecord(
                id: 'unused-$i',
                type: 'text',
                contentOrPath: 'Synthetic note $i',
                createdAt: DateTime(2020),
              ).toJson(),
            );
          }
        });
      });
      await host(tester, const ContentManagementPanel());
      await tap(tester, const ValueKey('content-scan'));
      await tap(tester, const ValueKey('content-select-visible'));
      expect(find.text('已选 100 项，约可释放 0 B'), findsOneWidget);
      final rows = await tester.runAsync(
        () => h.database.read(
          h.database.captureGeneration(),
          (db) => db.query('MediaRecords'),
        ),
      );
      expect(rows, hasLength(103));
      await finish(tester);
    },
  );

  testWidgets(
    'cleanup requires a concrete selection and confirmation; cancelling retains the original record',
    (tester) async {
      await tester.runAsync(
        () => h.container
            .read(mediaRecordsProvider.notifier)
            .addRecord(
              MediaRecord(
                id: 'unused',
                type: 'text',
                contentOrPath: 'Synthetic standalone note',
                createdAt: DateTime(2020),
              ),
            ),
      );
      await host(tester, const ContentManagementPanel());
      await tap(tester, const ValueKey('content-scan'));
      await tap(tester, const ValueKey('content-entry:record:unused'));
      await tap(tester, const ValueKey('content-clean'));
      expect(find.text('永久清理这些未引用内容？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settle(tester);
      expect(
        await tester.runAsync(
          () => h.database.read(
            h.database.captureGeneration(),
            (db) => db.query('MediaRecords'),
          ),
        ),
        hasLength(1),
      );
      await tap(tester, const ValueKey('content-clean'));
      await tap(tester, const ValueKey('content-confirm'));
      expect(
        await tester.runAsync(
          () => h.database.read(
            h.database.captureGeneration(),
            (db) => db.query('MediaRecords'),
          ),
        ),
        isEmpty,
      );
      await finish(tester);
    },
  );
  testWidgets(
    'a new task reference during cleanup confirmation preserves the record',
    (tester) async {
      await tester.runAsync(
        () => h.container
            .read(mediaRecordsProvider.notifier)
            .addRecord(
              MediaRecord(
                id: 'unused',
                type: 'text',
                contentOrPath: 'New source',
                createdAt: DateTime(2020),
              ),
            ),
      );
      await host(tester, const ContentManagementPanel());
      await tap(tester, const ValueKey('content-scan'));
      await tap(tester, const ValueKey('content-entry:record:unused'));
      await tap(tester, const ValueKey('content-clean'));
      await tester.runAsync(
        () => h.seed(
          Reminder(
            id: 'new',
            recordId: 'unused',
            taskTitle: 'Keep source',
            quadrantLevel: 2,
          ),
        ),
      );
      await tap(tester, const ValueKey('content-confirm'));
      expect(find.text('操作未完成或内容已变化，请重新检查。'), findsOneWidget);
      expect(
        await tester.runAsync(
          () => h.database.read(
            h.database.captureGeneration(),
            (db) => db.query('MediaRecords'),
          ),
        ),
        hasLength(1),
      );
      await finish(tester);
    },
  );
  testWidgets(
    'unified archive moves an active item and returns it without completion',
    (tester) async {
      await tester.runAsync(
        () => h.seed(
          Reminder(
            id: 'a',
            taskTitle: 'Ordinary active',
            quadrantLevel: 2,
            triggerTime: DateTime(2035),
          ),
        ),
      );
      await host(tester, const ContentManagementPanel());
      await tester.tap(find.widgetWithText(ChoiceChip, '统一归档'));
      await settle(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, '可归档事项'));
      await settle(tester);
      await tap(tester, const ValueKey('content-archive:a'));
      expect(find.text('归档并停止提醒'), findsOneWidget);
      await tap(tester, const ValueKey('content-confirm'));
      expect((await tester.runAsync(() => h.row('a')))!.isCompleted, isFalse);
      await tester.tap(find.widgetWithText(ChoiceChip, '归档库'));
      await settle(tester);
      await tap(tester, const ValueKey('content-archive:a'));
      await tap(tester, const ValueKey('content-confirm'));
      expect((await tester.runAsync(() => h.row('a')))!.isVisible, isTrue);
      await finish(tester);
    },
  );
  testWidgets(
    'metadata preview displays before and after values before returning a patch',
    (tester) async {
      TaskMetadataPatch? result;
      final row = Reminder(
        id: 'a',
        taskTitle: 'Sample task',
        quadrantLevel: 2,
        detailsJson: const TaskDetails(project: 'Old').encode(),
      );
      await host(
        tester,
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open'),
            onPressed: () async {
              result = await showDialog<TaskMetadataPatch>(
                context: context,
                builder: (_) => TaskMetadataDialog(rows: [row]),
              );
            },
            child: const Text('Open'),
          ),
        ),
      );
      await tap(tester, const ValueKey('open'));
      await tap(tester, const ValueKey('metadata-project-mode'));
      await tester.tap(find.text('设为填写内容').last);
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('metadata-project')),
        'New',
      );
      await tap(tester, const ValueKey('metadata-preview'));
      expect(find.text('项目: Old → New'), findsOneWidget);
      expect(result, isNull);
      await tap(tester, const ValueKey('metadata-save'));
      expect(result!.apply(row.details).project, 'New');
      await finish(tester);
    },
  );
  testWidgets(
    'template import previews conflicts and defaults matching names to skip',
    (tester) async {
      final store = h.container.read(taskTemplateStoreProvider);
      await tester.runAsync(
        () => store.save(
          name: 'Travel',
          title: 'Local original',
          items: [],
          tags: [],
          project: '',
        ),
      );
      await host(tester, launch(const TaskTemplateLibrary()));
      await tap(tester, const ValueKey('open'));
      await tap(tester, const ValueKey('templates-import'));
      expect(find.text('同名模板已存在'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('template-import-confirm')),
      );
      expect(button.onPressed, isNull);
      await tap(tester, const ValueKey('template-import-choice:0'));
      await tester.tap(find.text('新增副本').last);
      await settle(tester);
      await tap(tester, const ValueKey('template-import-confirm'));
      expect((await tester.runAsync(store.load))!.map((e) => e.name), [
        'Travel',
        'Travel (2)',
      ]);
      await tap(tester, const ValueKey('templates-export'));
      expect(files.saved, 1);
      await finish(tester);
    },
  );
  for (final width in [375.0, 768.0, 1440.0]) {
    for (final locale in ['zh', 'en', 'ja']) {
      testWidgets(
        'content and transfer dialogs fit $width $locale with large text and keyboard',
        (tester) async {
          await host(
            tester,
            const ContentManagementPanel(),
            width: width,
            locale: locale,
            scale: 1.8,
            keyboard: 260,
          );
          await tap(tester, const ValueKey('content-scan'));
          expect(tester.takeException(), isNull);
          await finish(tester);
          await host(
            tester,
            launch(const TaskMetadataDialog(rows: [])),
            width: width,
            locale: locale,
            scale: 1.8,
            keyboard: 260,
          );
          await tap(tester, const ValueKey('open'));
          expect(tester.takeException(), isNull);
          await finish(tester);
          await host(
            tester,
            launch(
              const TaskTemplateTransferDialog(
                current: [],
                imported: [imported],
              ),
            ),
            width: width,
            locale: locale,
            scale: 1.8,
            keyboard: 260,
          );
          await tap(tester, const ValueKey('open'));
          expect(tester.takeException(), isNull);
          await finish(tester);
        },
      );
    }
  }
}
