import 'dart:async';
import 'dart:io';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/content/external_backup_references.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/ui/widgets/external_backup_references_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/offline_management_harness.dart';
import 'support/workspace_drafts.dart';
import 'external_backup_references_test.dart' show preview;

class _Inspector extends BackupInspector {
  _Inspector() : super(databaseFactoryFfi);
  Completer<BackupPreview>? pending;
  bool fail = false;
  int calls = 0;
  @override
  Future<BackupPreview> inspect(
    File source, {
    BackupInspectionCancellation? cancellation,
  }) async {
    calls++;
    if (fail) throw const FormatException('synthetic');
    return pending == null ? preview(1) : pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  late _Inspector inspector;
  int picks = 0;
  bool cancelled = false;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    inspector = _Inspector();
    picks = 0;
    cancelled = false;
    await h.container.read(workspaceDraftsProvider.notifier).put('keep', {
      'text': 'existing draft',
    });
  });
  tearDown(() => h.dispose());
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await drainWorkspaceDrafts(tester, h.container);
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
    }
  }

  Future<void> host(
    WidgetTester tester, {
    String locale = 'zh',
    double width = 375,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = Size(width, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: ProviderScope(
          overrides: [
            externalBackupInspectorProvider.overrideWithValue(inspector),
            externalBackupPickerProvider.overrideWithValue(() async {
              picks++;
              return cancelled
                  ? null
                  : (
                      file: File('${h.directory.path}/not-opened-by-fake.json'),
                      name: '旧备份.json',
                    );
            }),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            locale: Locale(locale),
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
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  key: const ValueKey('open'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const ExternalBackupReferencesDialog(),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('open')));
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await settle(tester);
  }

  Future<Object?> stored(WidgetTester tester) async {
    Object? result;
    await tester.runAsync(() async {
      result = await h.container
          .read(workspaceDraftsProvider.notifier)
          .readPersistedKey(ExternalBackupReferences.storageKey);
    });
    return result;
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'opening is read-only, registration requires confirmation and removal requires separate confirmation',
    (tester) async {
      await host(tester);
      expect(picks, 0);
      expect(inspector.calls, 0);
      expect(await stored(tester), isNull);
      await tap(tester, 'external-backup-register');
      expect(await stored(tester), isNull);
      expect(find.textContaining('旧备份.json'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(await stored(tester), isNull);
      await tap(tester, 'external-backup-register');
      await tap(tester, 'external-backup-confirm');
      expect(ExternalBackupReferences.read(await stored(tester)), hasLength(1));
      expect(h.container.read(workspaceDraftsProvider)['keep'], {
        'text': 'existing draft',
      });
      await tap(tester, 'external-backup-${preview(1).digest}');
      expect(find.textContaining('/old/file.png'), findsOneWidget);
      await tap(tester, 'external-backup-remove');
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(ExternalBackupReferences.read(await stored(tester)), hasLength(1));
      await tap(tester, 'external-backup-${preview(1).digest}');
      await tap(tester, 'external-backup-remove');
      await tap(tester, 'external-backup-confirm');
      expect(await stored(tester), isNull);
      await finish(tester);
    },
  );
  testWidgets(
    'picker cancellation, invalid source and SQL rejection preserve registry and drafts',
    (tester) async {
      await host(tester);
      cancelled = true;
      await tap(tester, 'external-backup-register');
      expect(inspector.calls, 0);
      expect(await stored(tester), isNull);
      cancelled = false;
      inspector.fail = true;
      await tap(tester, 'external-backup-register');
      expect(await stored(tester), isNull);
      inspector.fail = false;
      await tester.runAsync(() async {
        await (await h.database.database).execute(
          "CREATE TRIGGER fail_registry BEFORE UPDATE ON Settings BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
        );
      });
      await tap(tester, 'external-backup-register');
      await tap(tester, 'external-backup-confirm');
      expect(await stored(tester), isNull);
      expect(h.container.read(workspaceDraftsProvider)['keep'], {
        'text': 'existing draft',
      });
      await finish(tester);
    },
  );
  testWidgets(
    'a concurrent writer is preserved when confirming an earlier preview',
    (tester) async {
      await host(tester);
      await tap(tester, 'external-backup-register');
      final concurrent = ExternalBackupReferences.add(
        null,
        preview(2),
        'concurrent.db',
        at: DateTime(2026),
      );
      await tester.runAsync(
        () => h.container
            .read(workspaceDraftsProvider.notifier)
            .put(ExternalBackupReferences.storageKey, concurrent),
      );
      await tap(tester, 'external-backup-confirm');
      expect(await stored(tester), concurrent);
      await finish(tester);
    },
  );
  testWidgets('closing during inspection ignores a late result', (
    tester,
  ) async {
    inspector.pending = Completer<BackupPreview>();
    await host(tester);
    await tap(tester, 'external-backup-register');
    await tester.tap(find.text('关闭'));
    await settle(tester);
    inspector.pending!.complete(preview(1));
    await settle(tester);
    expect(find.byKey(const ValueKey('external-backup-confirm')), findsNothing);
    expect(await stored(tester), isNull);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets('future registries remain untouched and cannot be edited', (
    tester,
  ) async {
    final raw = {'version': 2, 'entries': [], 'future': 'keep'};
    await tester.runAsync(
      () => h.container
          .read(workspaceDraftsProvider.notifier)
          .put(ExternalBackupReferences.storageKey, raw),
    );
    await host(tester);
    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('external-backup-register')),
    );
    expect(button.onPressed, isNull);
    expect(await stored(tester), raw);
    expect(picks, 0);
    await finish(tester);
  });
  testWidgets('an expired data generation cannot commit a completed preview', (
    tester,
  ) async {
    await host(tester);
    await tap(tester, 'external-backup-register');
    await tester.runAsync(() async {
      final lease = await h.database.beginMaintenance();
      await lease.resume();
    });
    await tap(tester, 'external-backup-confirm');
    Object? value;
    await tester.runAsync(() async {
      final rows = await h.database.read(
        h.database.captureGeneration(),
        (db) => db.query('Settings'),
      );
      value = rows.single['workspace_drafts_json'];
    });
    expect(value, isNot(contains(ExternalBackupReferences.storageKey)));
    await finish(tester);
  });
  for (final locale in ['zh', 'en', 'ja']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '$locale $brightness narrow large text keeps 20 registrations scrollable and read-only',
        (tester) async {
          Object? raw;
          for (var i = 0; i < 20; i++) {
            raw = ExternalBackupReferences.add(
              raw,
              preview(i),
              '备份-$i.json',
              at: DateTime(2026),
            );
          }
          await tester.runAsync(
            () => h.container
                .read(workspaceDraftsProvider.notifier)
                .put(ExternalBackupReferences.storageKey, raw),
          );
          await host(
            tester,
            locale: locale,
            width: 320,
            scale: 1.8,
            brightness: brightness,
          );
          final list = find
              .descendant(
                of: find.byKey(const ValueKey('external-backup-dialog')),
                matching: find.byType(Scrollable),
              )
              .first;
          final last = find.byKey(
            ValueKey('external-backup-${preview(0).digest}'),
          );
          await tester.scrollUntilVisible(last, 240, scrollable: list);
          await tester.pumpAndSettle();
          await tester.tap(last);
          await settle(tester);
          expect(find.textContaining('/old/file.png'), findsOneWidget);
          expect(await stored(tester), raw);
          expect(tester.takeException(), isNull);
          await finish(tester);
        },
      );
    }
  }
}
