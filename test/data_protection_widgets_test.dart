import 'support/real_io.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:dont_forget/services/backup_file_exporter.dart';
import 'package:dont_forget/services/backup_cache_service.dart';
import 'package:dont_forget/services/backup_export_history.dart';
import 'package:dont_forget/ui/widgets/portable_backup_panel.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/credential_status_panel.dart';
import 'support/offline_management_harness.dart';
import 'support/workspace_drafts.dart';

class _Backup extends StreamingBackupService {
  final passwords = <String?>[];
  BackupControl? control;
  Completer<void>? barrier;
  int calls = 0;
  @override
  Future<BackupFile> createFile(
    DatabaseHelper database,
    DataGeneration generation,
    Directory cacheRoot, {
    String? password,
    BackupControl? control,
    bool Function()? isCurrent,
    BackupProgressCallback? onProgress,
    DateTime? now,
  }) async {
    calls++;
    passwords.add(password);
    this.control = control;
    onProgress?.call(const BackupProgress('write', 1, 2));
    await barrier?.future;
    control?.check();
    if (isCurrent?.call() == false) throw BackupCancelled();
    final dir = await cacheRoot.createTemp('export-');
    BackupCacheService.activeDirectories.add(dir.path);
    final file = await File(
      '${dir.path}/backup.dfbackup',
    ).writeAsString('synthetic test backup');
    return BackupFile(
      file,
      2,
      const ['missing'],
      DateTime(2030),
      password != null,
    );
  }
}

class _Exporter extends BackupFileExporter {
  int calls = 0;
  bool cancel = false;
  final filenames = <String>[];
  String? chosenLocation;
  @override
  Future<String?> save(File source, String filename) async {
    calls++;
    filenames.add(filename);
    return cancel ? null : chosenLocation ?? 'synthetic-export/$filename';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineManagementHarness h;
  late _Backup backup;
  late _Exporter exporter;
  late Directory cache;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    cache = await Directory('${h.directory.path}/cache').create();
    backup = _Backup();
    exporter = _Exporter();
  });
  tearDown(() => h.dispose());
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 18; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await drainWorkspaceDrafts(tester, h.container);
    await pumpUntilRealIo(
      tester,
      () => !tester.binding.hasScheduledFrame,
      reason: 'Credential or backup operation must finish before settling UI',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  Future<void> host(
    WidgetTester tester, {
    double width = 375,
    String locale = 'zh',
    double scale = 1,
    Brightness brightness = Brightness.light,
    double keyboard = 0,
    Widget? child,
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
            streamingBackupServiceProvider.overrideWithValue(backup),
            backupFileExporterProvider.overrideWithValue(exporter),
            backupCacheRootProvider.overrideWithValue(() async => cache),
          ],
          child: MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
            localizationsDelegates: const [
              AppLocalizationsDelegate(),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: InlineFeedback(child: child!),
            ),
            home: Scaffold(body: child ?? const PortableBackupPanel()),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    if (finder.evaluate().isEmpty) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 30000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        finder,
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await drainWorkspaceDrafts(tester, h.container);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> passwords(WidgetTester tester, String one, String two) async {
    await tester.enterText(find.byKey(const ValueKey('backup-password')), one);
    await tester.enterText(
      find.byKey(const ValueKey('backup-password-repeat')),
      two,
    );
    await settle(tester);
  }

  testWidgets(
    'encrypted export requires matching passwords, saves no password in workspace, and clears fields',
    (tester) async {
      await host(tester);
      await tap(tester, const ValueKey('backup-export'));
      expect(backup.calls, 0);
      expect(find.text('请输入至少 12 个字符且两次一致的密码。'), findsOneWidget);
      await passwords(tester, 'Synthetic backup password', 'mismatch');
      await tap(tester, const ValueKey('backup-export'));
      expect(backup.calls, 0);
      await passwords(
        tester,
        'Synthetic backup password',
        'Synthetic backup password',
      );
      await tap(tester, const ValueKey('backup-export'));
      expect(backup.passwords, ['Synthetic backup password']);
      expect(exporter.calls, 1);
      final raw = await tester.runAsync(h.drafts);
      expect(raw, isNot(contains('Synthetic backup password')));
      expect(raw, contains('"encrypted":true'));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('backup-password')))
            .controller!
            .text,
        isEmpty,
      );
      expect(await tester.runAsync(() => cache.list().toList()), isEmpty);
      await finish(tester);
    },
  );
  testWidgets(
    'custom backup names are exported and shown without exposing the full location',
    (tester) async {
      exporter.chosenLocation = 'content://documents/document/opaque-123';
      await host(tester);
      await tap(tester, const ValueKey('backup-encryption'));
      await tester.enterText(
        find.byKey(const ValueKey('backup-name')),
        '会议资料.DFBACKUP',
      );
      await tap(tester, const ValueKey('backup-export'));
      expect(exporter.filenames, ['会议资料.dfbackup']);
      expect(
        h.container.read(workspaceDraftsProvider)['lastPortableBackup']['name'],
        '会议资料.dfbackup',
      );
      expect(find.text('备份已导出'), findsOneWidget);
      expect(find.text('缺失附件: 0'), findsNothing);
      await tap(tester, const ValueKey('backup-location'));
      expect(
        find.textContaining('content://documents/document/opaque-123'),
        findsOneWidget,
      );
      await tester.tap(find.text('关闭'));
      await settle(tester);
      expect(
        find.textContaining('content://documents/document/opaque-123'),
        findsNothing,
      );
      await finish(tester);
    },
  );
  testWidgets('invalid or unconfirmed IME names never start a backup', (
    tester,
  ) async {
    await host(tester);
    await tap(tester, const ValueKey('backup-encryption'));
    final name = find.byKey(const ValueKey('backup-name'));
    await tester.enterText(name, '../bad');
    await tap(tester, const ValueKey('backup-export'));
    expect(backup.calls, 0);
    expect(exporter.calls, 0);
    expect(find.text('请使用有效名称，不含路径或系统保留字'), findsOneWidget);
    await tester.enterText(name, 'ming');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ming',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.pump();
    await tap(tester, const ValueKey('backup-export'));
    expect(backup.calls, 0);
    expect(find.text('请先确认输入'), findsOneWidget);
    await finish(tester);
  });
  testWidgets(
    'history preserves legacy exports, stays read-only, survives reopen and ignores cancelled exports',
    (tester) async {
      await tester.runAsync(
        () => h.container.read(workspaceDraftsProvider.notifier).put(
          'lastPortableBackup',
          {'at': '2029-01-01T10:00:00', 'location': r'C:\backups\旧备份.dfbackup'},
        ),
      );
      await host(tester);
      await tap(tester, const ValueKey('backup-encryption'));
      await tester.enterText(find.byKey(const ValueKey('backup-name')), '新备份');
      await tap(tester, const ValueKey('backup-export'));
      final persisted = await tester.runAsync(h.drafts);
      final history = BackupExportHistory.read(
        h.container.read(workspaceDraftsProvider)['lastPortableBackup'],
      );
      expect(history.map((e) => e['name']), ['新备份.dfbackup', '旧备份.dfbackup']);
      expect(find.text('旧备份.dfbackup'), findsNothing);
      await tap(tester, const ValueKey('backup-history'));
      expect(find.text('旧备份.dfbackup'), findsOneWidget);
      expect(find.textContaining(r'C:\backups'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('backup-history-entry-1')));
      await settle(tester);
      expect(find.textContaining(r'C:\backups\旧备份.dfbackup'), findsOneWidget);
      await tester.tap(find.text('关闭').last);
      await settle(tester);
      await tester.tap(find.text('关闭'));
      await settle(tester);
      expect(await tester.runAsync(h.drafts), persisted);
      exporter.cancel = true;
      await tap(tester, const ValueKey('backup-export'));
      expect(await tester.runAsync(h.drafts), persisted);
      await finish(tester);
      await tester.runAsync(() async {
        await h.close();
        await h.open();
      });
      await host(tester);
      await tap(tester, const ValueKey('backup-history'));
      expect(find.text('旧备份.dfbackup'), findsOneWidget);
      expect(await tester.runAsync(h.drafts), persisted);
      await finish(tester);
    },
  );
  testWidgets(
    'future history is preserved when a new export record cannot be merged',
    (tester) async {
      final future = {
        'at': '2029-01-01T10:00:00',
        'location': '/synthetic/future.dfbackup',
        'history_version': 2,
        'previous_exports': ['future-format'],
      };
      await tester.runAsync(
        () => h.container
            .read(workspaceDraftsProvider.notifier)
            .put('lastPortableBackup', future),
      );
      final persisted = await tester.runAsync(h.drafts);
      await host(tester);
      await tap(tester, const ValueKey('backup-encryption'));
      await tap(tester, const ValueKey('backup-export'));
      expect(exporter.calls, 1);
      expect(find.text('备份已导出，导出记录未保存'), findsOneWidget);
      expect(await tester.runAsync(h.drafts), persisted);
      expect(await tester.runAsync(() => cache.list().toList()), isEmpty);
      await finish(tester);
    },
  );
  testWidgets(
    'an exported file is reported successful even if recording metadata fails',
    (tester) async {
      await host(tester);
      await tap(tester, const ValueKey('backup-encryption'));
      await tester.runAsync(
        () => h.database.writeTransaction(
          h.database.captureGeneration(),
          (db) => db.execute(
            "CREATE TRIGGER deny_backup_record BEFORE UPDATE OF workspace_drafts_json ON Settings BEGIN SELECT RAISE(ABORT,'fixture'); END",
          ),
        ),
      );
      await tap(tester, const ValueKey('backup-export'));
      expect(exporter.calls, 1);
      expect(find.text('备份已导出，导出记录未保存'), findsOneWidget);
      expect(
        h.container.read(workspaceDraftsProvider)['lastPortableBackup'],
        isNull,
      );
      expect(await tester.runAsync(() => cache.list().toList()), isEmpty);
      await tester.runAsync(
        () => h.database.writeTransaction(
          h.database.captureGeneration(),
          (db) => db.execute('DROP TRIGGER deny_backup_record'),
        ),
      );
      await finish(tester);
    },
  );
  testWidgets(
    'legacy locations remain viewable and help is available on demand',
    (tester) async {
      await tester.runAsync(
        () => h.container
            .read(workspaceDraftsProvider.notifier)
            .put('lastPortableBackup', {
              'at': '2030-01-01T10:00:00',
              'location': r'C:\backup\legacy.dfbackup',
              'media': 1,
              'missing': 0,
              'encrypted': true,
            }),
      );
      await host(tester);
      await tap(tester, const ValueKey('backup-location'));
      expect(find.textContaining('legacy.dfbackup'), findsWidgets);
      await tester.tap(find.text('关闭'));
      await settle(tester);
      await tap(tester, const ValueKey('backup-help'));
      expect(find.textContaining('单附件最多 512 MiB'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await settle(tester);
      await finish(tester);
    },
  );
  testWidgets(
    'plaintext choice needs no password and cancelled destination does not record a completed export',
    (tester) async {
      exporter.cancel = true;
      await host(tester);
      await tap(tester, const ValueKey('backup-encryption'));
      expect(find.byKey(const ValueKey('backup-password')), findsNothing);
      await tap(tester, const ValueKey('backup-export'));
      expect(backup.passwords, [null]);
      expect(
        h.container.read(workspaceDraftsProvider)['lastPortableBackup'],
        isNull,
      );
      await finish(tester);
    },
  );
  testWidgets(
    'cancel export cooperates with the job and never opens destination picker',
    (tester) async {
      backup.barrier = Completer<void>();
      await host(tester);
      await tap(tester, const ValueKey('backup-encryption'));
      await tester.tap(find.byKey(const ValueKey('backup-export')));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      await tester.ensureVisible(find.byKey(const ValueKey('backup-cancel')));
      await tester.tap(find.byKey(const ValueKey('backup-cancel')));
      await tester.pump();
      expect(backup.control!.cancelled, isTrue);
      backup.barrier!.complete();
      await settle(tester);
      expect(exporter.calls, 0);
      expect(
        h.container.read(workspaceDraftsProvider)['lastPortableBackup'],
        isNull,
      );
      await finish(tester);
    },
  );
  testWidgets(
    'remove credentials requires explicit confirmation and preserves other data',
    (tester) async {
      await tester.runAsync(
        () => h.container
            .read(settingsProvider.notifier)
            .updateSettings(
              h.container
                  .read(settingsProvider)
                  .copyWith(apiKey: 'Synthetic API key'),
            ),
      );
      await host(tester, child: const ListViewCredential());
      await tap(tester, const ValueKey('credential-remove'));
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(h.container.read(settingsProvider).apiKey, 'Synthetic API key');
      await tap(tester, const ValueKey('credential-remove'));
      await tester.tap(find.text('确认移除'));
      await settle(tester);
      expect(h.container.read(settingsProvider).apiKey, isEmpty);
      expect(await tester.runAsync(h.rows), isEmpty);
      await finish(tester);
    },
  );
  testWidgets(
    'old credential dialog cannot remove keys after a recovery generation changes',
    (tester) async {
      await tester.runAsync(
        () => h.container
            .read(settingsProvider.notifier)
            .updateSettings(
              h.container
                  .read(settingsProvider)
                  .copyWith(apiKey: 'Synthetic API key'),
            ),
      );
      await host(tester, child: const ListViewCredential());
      await tap(tester, const ValueKey('credential-remove'));
      await tester.runAsync(() async {
        final lease = await h.database.beginMaintenance();
        await lease.resume();
      });
      await tester.tap(find.text('确认移除'));
      await settle(tester);
      expect(h.container.read(settingsProvider).apiKey, 'Synthetic API key');
      await finish(tester);
    },
  );
  for (final databasePaused in [false, true]) {
    testWidgets(
      'credential panel mounted during recovery stays inert until remounted (database paused: $databasePaused)',
      (tester) async {
        final gate = h.container.read(runtimeRecoveryGateProvider);
        final token = await tester.runAsync(gate.pause);
        final lease = databasePaused
            ? await tester.runAsync(h.database.beginMaintenance)
            : null;
        var resumed = false;
        var retries = 0;
        try {
          await host(
            tester,
            child: CredentialStatusPanel(onRetry: () async => retries++),
          );
          expect(tester.takeException(), isNull);
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('credential-retry')),
                )
                .onPressed,
            isNull,
          );
          if (lease != null) await tester.runAsync(lease.resume);
          gate.resume(token!);
          resumed = true;
          // A widget created during recovery must not adopt the new session.
          await host(
            tester,
            child: CredentialStatusPanel(onRetry: () async => retries++),
          );
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('credential-retry')),
                )
                .onPressed,
            isNull,
          );
          expect(retries, 0);
          await host(
            tester,
            child: CredentialStatusPanel(
              key: const ValueKey('fresh-credential-session'),
              onRetry: () async => retries++,
            ),
          );
          await tap(tester, const ValueKey('credential-retry'));
          expect(retries, 1);
          expect(tester.takeException(), isNull);
          await finish(tester);
        } finally {
          if (!resumed) {
            if (lease != null) await tester.runAsync(lease.resume);
            gate.resume(token!);
          }
        }
      },
    );
  }
  testWidgets(
    'cache cleanup previews only generated files and cancellation preserves them',
    (tester) async {
      final dir = await tester.runAsync(
        () => Directory('${cache.path}/export-old').create(),
      );
      final file = await tester.runAsync(
        () => File('${dir!.path}/backup.dfbackup').writeAsString('cache'),
      );
      await host(tester);
      await tap(tester, const ValueKey('backup-cache-inspect'));
      await tap(tester, const ValueKey('backup-cache-clear'));
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(await tester.runAsync(file!.exists), isTrue);
      await tap(tester, const ValueKey('backup-cache-clear'));
      await tester.tap(find.widgetWithText(FilledButton, '清理选中缓存'));
      await settle(tester);
      expect(await tester.runAsync(file.exists), isFalse);
      await finish(tester);
    },
  );
  for (final width in [375.0, 768.0, 1440.0]) {
    for (final locale in ['zh', 'en', 'ja']) {
      testWidgets(
        'security and password controls fit $width $locale dark large text with keyboard',
        (tester) async {
          await host(
            tester,
            width: width,
            locale: locale,
            scale: 1.8,
            brightness: Brightness.dark,
            keyboard: 260,
          );
          await tap(tester, const ValueKey('backup-export'));
          expect(tester.takeException(), isNull);
          await tap(tester, const ValueKey('backup-cache-inspect'));
          expect(tester.takeException(), isNull);
          await finish(tester);
        },
      );
    }
  }
  for (final locale in ['zh', 'en', 'ja']) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        'history fits $locale $brightness large text and scrolls to oldest export',
        (tester) async {
          Object? history;
          for (var day = 1; day <= 20; day++) {
            history = BackupExportHistory.prepend({
              'name': '${'较长的备份名称' * 8}-$day.dfbackup',
              'at': DateTime(2030, 1, day).toIso8601String(),
              'location': '/synthetic/export-$day.dfbackup',
            }, history);
          }
          await tester.runAsync(
            () => h.container
                .read(workspaceDraftsProvider.notifier)
                .put('lastPortableBackup', history),
          );
          final before = await tester.runAsync(h.drafts);
          await host(
            tester,
            width: brightness == Brightness.dark ? 320 : 768,
            locale: locale,
            scale: 2,
            brightness: brightness,
          );
          await tap(tester, const ValueKey('backup-history'));
          expect(tester.takeException(), isNull);
          final dialog = find.byKey(const ValueKey('backup-history-dialog'));
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('backup-history-entry-19')),
            300,
            scrollable: find
                .descendant(of: dialog, matching: find.byType(Scrollable))
                .first,
            maxScrolls: 60,
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('backup-history-entry-19')).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('backup-history-entry-19')),
          );
          await settle(tester);
          expect(
            find.textContaining('/synthetic/export-1.dfbackup'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          expect(await tester.runAsync(h.drafts), before);
          await finish(tester);
        },
      );
    }
  }
}

class ListViewCredential extends StatelessWidget {
  const ListViewCredential({super.key});
  @override
  Widget build(BuildContext context) =>
      ListView(children: const [CredentialStatusPanel()]);
}
