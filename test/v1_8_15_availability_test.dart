import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/task_details.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/shared_text_inbox.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:dont_forget/ui/screens/task_detail_screen.dart';
import 'package:dont_forget/ui/theme/app_theme.dart';
import 'package:dont_forget/ui/widgets/content_management_panel.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/portable_backup_panel.dart';
import 'package:dont_forget/ui/widgets/task_attachments_panel.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/offline_management_harness.dart';
import 'support/real_io.dart';

class _DirectHttpOverrides extends HttpOverrides {}

class _StubProbeLlm extends LLMService {
  @override
  Future<List<LocalInferenceEndpoint>> probeLocalInferenceEndpoints() async => [
    LocalInferenceEndpoint(
      name: 'Ollama',
      url: 'http://127.0.0.1:11434/v1',
      port: 11434,
      isAvailable: true,
      recommendedModel: 'qwen2.5:7b',
      latencyMs: 5,
    ),
  ];
}

Widget _appShell(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en'), Locale('ja')],
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light,
      builder: (context, inner) => InlineFeedback(child: inner!),
      home: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedText handoff boundary', () {
    const shareId = '00000000-0000-4000-8000-000000000001';

    test('parse accepts valid private handoff path and rejects arbitrary paths', () {
      final validPath = p.join(
        Directory.systemTemp.path,
        'shared_handoff',
        shareId,
        'note.txt',
      );
      final parsed = SharedText.parse({
        'id': shareId,
        'text': 'from share',
        'created_at': 1762300800000,
        'attachment_path': validPath,
      });
      expect(parsed.attachmentPath, validPath);
      expect(parsed.attachmentName, 'note.txt');

      final forgedOutside = p.join(Directory.systemTemp.path, 'secret.txt');
      expect(
        () => SharedText.parse({
          'id': shareId,
          'text': 'forged',
          'created_at': 1762300800000,
          'attachment_path': forgedOutside,
        }),
        throwsFormatException,
      );

      final wrongShareDir = p.join(
        Directory.systemTemp.path,
        'shared_handoff',
        '00000000-0000-4000-8000-000000000099',
        'note.txt',
      );
      expect(
        () => SharedText.parse({
          'id': shareId,
          'text': 'wrong dir',
          'created_at': 1762300800000,
          'attachment_path': wrongShareDir,
        }),
        throwsFormatException,
      );
    });
  });

  group('LAN sync IP prioritization and structured failures', () {
    test('selectPreferredLocalIp prefers physical LAN over virtual adapters', () {
      final ip = LanSyncService.selectPreferredLocalIp([
        (name: 'vEthernet (WSL)', address: '172.24.16.1'),
        (name: 'docker0', address: '172.17.0.1'),
        (name: 'Tailscale', address: '100.64.0.12'),
        (name: 'Wi-Fi', address: '192.168.1.42'),
      ]);
      expect(ip, '192.168.1.42');

      final fallbackPrivate = LanSyncService.selectPreferredLocalIp([
        (name: 'vEthernet (Default Switch)', address: '192.168.128.1'),
        (name: 'Ethernet', address: '10.0.0.15'),
      ]);
      expect(fallbackPrivate, '10.0.0.15');

      final onlyVirtual = LanSyncService.selectPreferredLocalIp([
        (name: 'vEthernet (WSL)', address: '172.24.16.1'),
      ]);
      expect(onlyVirtual, '172.24.16.1');
    });

    test('syncWithPeer reports invalidPin, pinLocked, payloadTooLarge, unreachable', () async {
      await HttpOverrides.runZoned(() async {
        sqfliteFfiInit();
        final dir = await Directory.systemTemp.createTemp('lan-failures-');
        final db = DatabaseHelper.forTesting(dir.path, databaseFactoryFfi);
        final service = LanSyncService.forTesting();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
          await db.close();
          await dir.delete(recursive: true);
        });

        var nextStatus = HttpStatus.unauthorized;
        server.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = nextStatus;
          request.response.write('{"error":"synthetic"}');
          await request.response.close();
        });

        LanSyncFailure? reported;
        for (final (status, expected) in [
          (HttpStatus.unauthorized, LanSyncFailure.invalidPin),
          (HttpStatus.tooManyRequests, LanSyncFailure.pinLocked),
          (HttpStatus.requestEntityTooLarge, LanSyncFailure.payloadTooLarge),
        ]) {
          nextStatus = status;
          reported = null;
          final ok = await service.syncWithPeer(
            peerIp: '127.0.0.1',
            port: server.port,
            pin: '123456',
            dbHelper: db,
            onFailure: (f) => reported = f,
          );
          expect(ok, isFalse);
          expect(reported, expected);
        }

        final closedPort = server.port;
        await server.close(force: true);
        reported = null;
        final okClosed = await service.syncWithPeer(
          peerIp: '127.0.0.1',
          port: closedPort,
          pin: '123456',
          dbHelper: db,
          onFailure: (f) => reported = f,
        );
        expect(okClosed, isFalse);
        expect(reported, LanSyncFailure.unreachable);
      }, createHttpClient: _DirectHttpOverrides().createHttpClient);
    });
  });

  group('ConsoleUrlLauncher mobile fallback', () {
    test('uses external URL launcher on Android and iOS', () async {
      Uri? launched;
      final launcher = ConsoleUrlLauncher(
        runProcess: (_, _) => throw StateError('must not invoke desktop shell'),
        launchExternalUrl: (uri) async {
          launched = uri;
          return true;
        },
      );
      expect(
        await launcher.open(
          'https://platform.deepseek.com/api_keys',
          platform: TargetPlatform.android,
        ),
        isTrue,
      );
      expect(launched, Uri.parse('https://platform.deepseek.com/api_keys'));

      launched = null;
      expect(
        await launcher.open(
          'https://console.cloud.tencent.com/cam/capi',
          platform: TargetPlatform.iOS,
        ),
        isTrue,
      );
      expect(launched?.host, 'console.cloud.tencent.com');
    });
  });

  group('Widget availability features', () {
    late OfflineManagementHarness h;

    setUp(() async {
      h = OfflineManagementHarness();
      await h.create();
    });

    tearDown(() => h.dispose());

    testWidgets('TaskDetailScreen copy button copies content without mutating DB', (
      tester,
    ) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      final task = Reminder(
        id: 'copy-test',
        taskTitle: '整理发布清单',
        taskSummary: '核对版本号与升级脚本',
        quadrantLevel: 1,
        detailsJson: const TaskDetails(
          checklist: [
            ChecklistItem('c1', '打包验证', done: true),
            ChecklistItem('c2', '覆盖安装', done: false),
          ],
        ).encode(),
      );
      await tester.runAsync(() => h.seed(task));

      await tester.pumpWidget(
        _appShell(h.container, TaskDetailScreen(task: task)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('task-detail-copy')));
      await tester.pumpAndSettle();

      expect(copiedText, isNotNull);
      expect(copiedText, contains('整理发布清单'));
      expect(copiedText, contains('核对版本号与升级脚本'));
      expect(copiedText, contains('[x] 打包验证'));
      expect(copiedText, contains('[ ] 覆盖安装'));
      final stored = await tester.runAsync(() => h.row(task.id));
      expect(stored!.taskTitle, '整理发布清单');
    });

    testWidgets('TaskCard menu supports Move Category and Quick Postpone', (
      tester,
    ) async {
      final originalTrigger = DateTime(2030, 5, 1, 10, 0);
      final task = Reminder(
        id: 'card-actions',
        taskTitle: '准备演示环境',
        quadrantLevel: 3,
        triggerTime: originalTrigger,
      );
      await tester.runAsync(() => h.seed(task));

      await tester.pumpWidget(
        _appShell(
          h.container,
          Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final current = ref
                    .watch(remindersProvider)
                    .firstWhere((r) => r.id == task.id);
                return TaskCard(task: current, onPlayMedia: () {});
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Move category Q3 -> Q1
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('调整分类'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('task-move-category-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('task-move-category-1')));
      await pumpUntilRealIo(
        tester,
        () => h.container
                .read(remindersProvider)
                .firstWhere((r) => r.id == task.id)
                .quadrantLevel ==
            1,
        reason: 'moveCategory should persist quadrantLevel=1',
      );
      await tester.pumpAndSettle();

      expect((await tester.runAsync(() => h.row(task.id)))!.quadrantLevel, 1);

      // Quick postpone +1h
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('延后提醒'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('task-postpone-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('task-postpone-60')));
      await pumpUntilRealIo(
        tester,
        () => h.container
                .read(remindersProvider)
                .firstWhere((r) => r.id == task.id)
                .triggerTime !=
            originalTrigger,
        reason: 'quickPostpone should persist updated triggerTime',
      );
      await tester.pumpAndSettle();

      final postponed = (await tester.runAsync(() => h.row(task.id)))!;
      expect(postponed.triggerTime, isNotNull);
      expect(postponed.triggerTime!.isAfter(DateTime.now()), isTrue);
    });

    testWidgets('TaskAttachmentPreview previews UTF-8 text and truncates >128 KiB', (
      tester,
    ) async {
      late Directory tmp;
      late File largeUtf8;
      late File binaryFile;
      await tester.runAsync(() async {
        tmp = await Directory.systemTemp.createTemp('att-preview-');
        largeUtf8 = File(p.join(tmp.path, 'notes.md'));
        const unit = '中文记录-line\n';
        await largeUtf8.writeAsBytes(utf8.encode(unit * 12000));
        binaryFile = File(p.join(tmp.path, 'data.txt'));
        await binaryFile.writeAsBytes([0x41, 0x00, 0x42, 0x00]);
      });
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });

      final media = MediaRecord(
        id: 'm1',
        type: 'file',
        contentOrPath: 'notes.md',
        createdAt: DateTime(2026),
      );
      await tester.pumpWidget(
        _appShell(
          h.container,
          TaskAttachmentPreview(media: media, resolvedPath: largeUtf8.path),
        ),
      );
      await pumpUntilRealIo(
        tester,
        () => find.byKey(const ValueKey('attachment-copy-text')).evaluate().isNotEmpty,
        reason: 'UTF-8 text preview should load and expose copy button',
      );

      expect(find.byKey(const ValueKey('attachment-copy-text')), findsOneWidget);
      expect(find.textContaining('前 128 KB'), findsOneWidget);

      await tester.pumpWidget(
        _appShell(
          h.container,
          TaskAttachmentPreview(media: media, resolvedPath: binaryFile.path),
        ),
      );
      await pumpUntilRealIo(
        tester,
        () => find.byKey(const ValueKey('attachment-copy-text')).evaluate().isEmpty,
        reason: 'Binary NUL-byte file should not render text preview copy button',
      );

      expect(find.byKey(const ValueKey('attachment-copy-text')), findsNothing);
    });

    testWidgets('PortableBackupPanel toggles password visibility', (
      tester,
    ) async {
      await tester.pumpWidget(
        _appShell(h.container, const Scaffold(body: PortableBackupPanel())),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      final pwFieldFinder = find.byKey(const ValueKey('backup-password'));
      expect(tester.widget<TextField>(pwFieldFinder).obscureText, isTrue);

      await tester.tap(find.byKey(const ValueKey('backup-password-toggle')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(pwFieldFinder).obscureText, isFalse);

      final repeatFinder = find.byKey(const ValueKey('backup-password-repeat'));
      expect(tester.widget<TextField>(repeatFinder).obscureText, isTrue);
      await tester.tap(
        find.byKey(const ValueKey('backup-password-repeat-toggle')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(repeatFinder).obscureText, isFalse);
    });

    testWidgets('ContentManagementPanel shows pending shared draft badge', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final drafts = h.container.read(workspaceDraftsProvider.notifier);
        final inbox = SharedTextInbox(drafts);
        await inbox.accept(
          const SharedText(
            id: '00000000-0000-4000-8000-000000000011',
            text: '待归档草稿',
            createdAt: 1762300800000,
          ),
        );
      });

      await tester.pumpWidget(
        _appShell(
          h.container,
          const Scaffold(body: ContentManagementPanel()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('content-shared-drafts-count')),
        findsOneWidget,
      );
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('SettingsArea.sync reveals Save action after Edge AI probe apply', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          databaseHelperProvider.overrideWithValue(h.database),
          notificationServiceProvider.overrideWithValue(h.notifications),
          llmServiceProvider.overrideWithValue(_StubProbeLlm()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(
        () => container.read(settingsProvider.notifier).ready,
      );

      await tester.pumpWidget(
        _appShell(
          container,
          const SettingsScreen(area: SettingsArea.sync),
        ),
      );
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byType(SettingsScreen)),
      );

      // Initially clean sync view has no Save bar.
      expect(find.text(l10n.get('save')), findsNothing);

      // Scroll to and tap Edge AI Probe.
      final probeButton = find.text(l10n.get('probeNow'));
      await tester.scrollUntilVisible(
        probeButton,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(probeButton);
      await tester.pumpAndSettle();

      // Apply endpoint -> marks settings dirty -> Save button appears on sync area.
      final applyButton = find.text(l10n.get('applyToSettings'));
      await tester.scrollUntilVisible(
        applyButton,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(applyButton);
      await tester.pumpAndSettle();

      expect(find.text(l10n.get('save')), findsOneWidget);
    });
  });
}
