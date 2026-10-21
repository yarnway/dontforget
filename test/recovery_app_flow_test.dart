import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dont_forget/app.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/recovery_coordinator.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/ui/screens/backup_preview_screen.dart';
import 'package:dont_forget/ui/screens/dashboard_screen.dart';
import 'package:dont_forget/ui/screens/home_screen.dart';
import 'package:dont_forget/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Native implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
  final schedules = <String>[];
  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #initialize:
        return Future<bool>.value(true);
      case #getNotificationAppLaunchDetails:
        return Future<NotificationAppLaunchDetails?>.value(
          const NotificationAppLaunchDetails(false),
        );
      case #cancelAll:
        pending.clear();
        return Future<void>.value();
      case #cancel:
        pending.remove(call.positionalArguments[0]);
        return Future<void>.value();
      case #zonedSchedule:
        final title = call.positionalArguments[1] as String;
        schedules.add(title);
        pending[call.positionalArguments[0] as int] = title;
        return Future<void>.value();
      default:
        throw UnsupportedError('${call.memberName}');
    }
  }
}

class _ReportService implements LLMService {
  final reply = Completer<String>();
  bool disposed = false;
  List<String> requestedTaskIds = [];
  String? requestedModel;

  @override
  Future<String> generateReviewReport(
    List<Reminder> reminders,
    AppSettings settings, {
    String language = 'zh',
  }) {
    requestedTaskIds = reminders.map((reminder) => reminder.id).toList();
    requestedModel = settings.modelName;
    return reply.future;
  }

  @override
  void dispose() => disposed = true;

  @override
  dynamic noSuchMethod(Invocation call) => super.noSuchMethod(call);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DatabaseHelper database;
  late ProviderContainer container;
  late NotificationService notifications;
  late _Native native;
  late LanSyncService lan;
  late BackupInspector inspector;
  late File sqlite;
  late File json;
  final audioChannels = <MethodChannel>[];
  Completer<void>? entered;
  Completer<void>? release;

  Future<String> hash(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();

  setUp(() async {
    sqfliteFfiInit();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    audioChannels.addAll(const [
      MethodChannel('xyz.luan/audioplayers.global'),
      MethodChannel('xyz.luan/audioplayers.global/events'),
      MethodChannel('xyz.luan/audioplayers'),
    ]);
    for (final channel in audioChannels.take(2)) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    messenger.setMockMethodCallHandler(audioChannels.last, (call) async {
      if (call.method == 'create') {
        final playerId = (call.arguments as Map)['playerId'];
        final channel = MethodChannel('xyz.luan/audioplayers/events/$playerId');
        audioChannels.add(channel);
        messenger.setMockMethodCallHandler(channel, (_) async => null);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('tray_manager'),
      (_) async => null,
    );
    directory = await Directory.systemTemp.createTemp('recovery-ui-flow-');
    database = DatabaseHelper.forTesting(
      p.join(directory.path, 'live'),
      databaseFactoryFfi,
    );
    native = _Native();
    notifications = NotificationService.forTesting(
      native,
      usesNativeNotifications: true,
    );
    lan = LanSyncService.forTesting();
    inspector = BackupInspector(
      databaseFactoryFfi,
      temporaryDirectory: directory,
    );
    entered = null;
    release = null;
    await database.writeTransaction(database.captureGeneration(), (db) async {
      await db.update('Settings', {
        'language': 'en',
        'model_name': 'original-model',
      });
      await db.insert(
        'Reminders',
        Reminder(
          id: 'original',
          taskTitle: 'Original task',
          quadrantLevel: 2,
          triggerTime: DateTime.now().add(const Duration(days: 2)),
        ).toJson(),
      );
    });
    await database.createMirrorBackup();
    final source = DatabaseHelper.forTesting(
      p.join(directory.path, 'source'),
      databaseFactoryFfi,
    );
    await source.writeTransaction(source.captureGeneration(), (db) async {
      await db.update('Settings', {
        'language': 'ja',
        'model_name': 'recovered-model',
        'api_key': 'synthetic-private-key',
      });
      await db.insert(
        'MediaRecords',
        MediaRecord(
          id: 'recovered-record',
          type: 'text',
          contentOrPath: 'Recovered note',
          createdAt: DateTime(2026),
        ).toJson(),
      );
      await db.insert(
        'Reminders',
        Reminder(
          id: 'recovered',
          recordId: 'recovered-record',
          taskTitle: 'Recovered task',
          quadrantLevel: 2,
          triggerTime: DateTime.now().add(const Duration(days: 2)),
        ).toJson(),
      );
    });
    await source.close();
    sqlite = File(p.join(directory.path, 'source', 'dont_forget_v3.mirror.db'));
    json = File(p.join(directory.path, 'source', 'ha_snapshot.json'));
    final engine = DatabaseRecovery(
      database,
      notifications: notifications,
      inspector: inspector,
      checkpoint: (point) async {
        if (point == RecoveryCheckpoint.candidateReady && entered != null) {
          entered!.complete();
          await release!.future;
        }
      },
    );
    container = ProviderContainer(
      overrides: [
        databaseHelperProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notifications),
        lanSyncServiceProvider.overrideWithValue(lan),
        databaseRecoveryProvider.overrideWithValue(engine),
        llmServiceProvider.overrideWith((ref) {
          final service = _ReportService();
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
    await container.read(settingsProvider.notifier).ready;
    await container.read(mediaRecordsProvider.notifier).ready;
    await container.read(remindersProvider.notifier).ready;
  });

  tearDown(() async {
    if (release != null && !release!.isCompleted) release!.complete();
    await lan.stopServer();
    await notifications.pauseForMaintenance();
    container.dispose();
    await database.close(createBackup: false);
    await directory.delete(recursive: true);
    for (final channel in audioChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    audioChannels.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tray_manager'), null);
  });

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 300; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      if (condition()) return;
    }
    fail('Recovery UI did not reach its expected state.');
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    // Provider state may reach a terminal phase one frame before MaterialApp
    // finishes rebuilding its navigator and loading the restored locale.
    await until(tester, () => finder.evaluate().isNotEmpty);
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => tester.tap(finder));
    await tester.pump();
  }

  Future<void> openPreview(
    WidgetTester tester,
    File source, {
    bool mountApp = true,
  }) async {
    if (mountApp) {
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const MyApp()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => BackupPreviewScreen(
            inspector: inspector,
            pickPath: () async => source.path,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tap(tester, 'backup-preview-select');
    await until(
      tester,
      () => find
          .byKey(const ValueKey('backup-preview-result'))
          .evaluate()
          .isNotEmpty,
    );
    await tap(tester, 'backup-restore-review');
    await until(
      tester,
      () => find
          .byKey(const ValueKey('recovery-confirmation-dialog'))
          .evaluate()
          .isNotEmpty,
    );
  }

  for (final format in ['json', 'sqlite']) {
    testWidgets(
      '$format: inspect, confirm, coordinate, replace and rebuild the real app session',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(375, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final source = format == 'json' ? json : sqlite;
        final sourceHash = await tester.runAsync(() => hash(source));
        final mirror = File(
          p.join(directory.path, 'live', 'dont_forget_v3.mirror.db'),
        );
        final mirrorHash = await tester.runAsync(() => hash(mirror));
        final oldSettings = container.read(settingsProvider.notifier);
        final oldMedia = container.read(mediaRecordsProvider.notifier);
        final oldTasks = container.read(remindersProvider.notifier);
        entered = Completer<void>();
        release = Completer<void>();
        await tester.runAsync(
          () => lan.startServer(port: 0, dbHelper: database),
        );
        await openPreview(tester, source);
        expect(find.textContaining('synthetic-private-key'), findsNothing);
        expect(container.read(remindersProvider).single.id, 'original');
        final confirm = find.byKey(
          const ValueKey('recovery-confirmation-confirm'),
        );
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tap(tester, 'recovery-acknowledge');
        await tap(tester, 'recovery-confirmation-confirm');
        await until(tester, () => entered!.isCompleted);
        expect(lan.isRunning, isFalse);
        expect(container.read(runtimeRecoveryGateProvider).paused, isTrue);
        expect(
          container.read(recoveryCoordinatorProvider).state.working,
          isTrue,
        );
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(
          container.read(recoveryCoordinatorProvider).state.working,
          isTrue,
        );
        await tester.runAsync(() async {
          release!.complete();
        });
        await until(
          tester,
          () => container.read(recoveryCoordinatorProvider).state.terminal,
        );
        final coordinator = container.read(recoveryCoordinatorProvider);
        expect(coordinator.state.phase, RecoveryPhase.succeeded);
        expect(find.byType(BackupPreviewScreen), findsNothing);
        expect(find.byType(SettingsScreen), findsNothing);
        expect(
          identical(container.read(settingsProvider.notifier), oldSettings),
          isFalse,
        );
        expect(
          identical(container.read(mediaRecordsProvider.notifier), oldMedia),
          isFalse,
        );
        expect(
          identical(container.read(remindersProvider.notifier), oldTasks),
          isFalse,
        );
        expect(container.read(settingsProvider).language, 'ja');
        expect(container.read(settingsProvider).modelName, 'recovered-model');
        expect(
          container.read(mediaRecordsProvider).single.id,
          'recovered-record',
        );
        expect(container.read(remindersProvider).single.id, 'recovered');
        expect(native.pending.values, ['Recovered task']);
        expect(
          native.schedules.where((title) => title == 'Recovered task'),
          hasLength(1),
        );
        await tester.runAsync(() async {
          expect(await hash(source), sourceHash);
          expect(await hash(mirror), mirrorHash);
          expect(
            await File(
              p.join(coordinator.state.rollbackDirectory!, 'rollback.db'),
            ).exists(),
            isTrue,
          );
        });
        expect(
          tester
              .widget<MaterialApp>(find.byType(MaterialApp))
              .locale
              ?.languageCode,
          'ja',
        );
        await tap(tester, 'recovery-outcome-continue');
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(HomeScreen), findsOneWidget);
        // Phone layouts show one category at a time; the recovered fixture is
        // in Q2 while a fresh workspace deliberately starts on Q1.
        await tap(tester, 'category-2');
        await tester.pump();
        expect(find.text('Recovered task'), findsOneWidget);
        expect(find.text('Original task'), findsNothing);
        expect(container.read(homeControllerProvider).pendingTasksCount, 0);
        expect(container.read(homeControllerProvider).isRecording, isFalse);
        expect(lan.isRunning, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('cancel leaves running LAN and current data intact', (
    tester,
  ) async {
    final generation = database.captureGeneration();
    final pin = (await tester.runAsync(
      () => lan.startServer(port: 0, dbHelper: database),
    ))!.pin;
    await openPreview(tester, json);
    await tap(tester, 'recovery-confirmation-cancel');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      container.read(recoveryCoordinatorProvider).state.phase,
      RecoveryPhase.idle,
    );
    expect(database.isCurrent(generation), isTrue);
    expect(container.read(remindersProvider).single.id, 'original');
    expect(container.read(mediaRecordsProvider), isEmpty);
    expect(container.read(settingsProvider).language, 'en');
    expect(container.read(settingsProvider).modelName, 'original-model');
    expect(lan.isRunning, isTrue);
    expect(lan.pin, pin);
    expect(container.read(runtimeRecoveryGateProvider).paused, isFalse);
    await tester.runAsync(() async {
      expect(
        await Directory(p.join(directory.path, 'live'))
            .list()
            .where((e) => p.basename(e.path).startsWith('recovery-'))
            .isEmpty,
        isTrue,
      );
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'recovery disposes a pending dashboard report and rejects its late result',
    (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const MyApp()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const DashboardScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final generate = find.text(
        AppLocalizations(const Locale('en')).get('generateAiReview'),
      );
      await tester.ensureVisible(generate);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => tester.tap(generate));
      await tester.pump();
      final report = container.read(llmServiceProvider) as _ReportService;
      expect(report.requestedTaskIds, ['original']);
      expect(report.requestedModel, 'original-model');
      expect(report.disposed, isFalse);
      entered = Completer<void>();
      release = Completer<void>();
      await openPreview(tester, json, mountApp: false);
      await tap(tester, 'recovery-acknowledge');
      await tap(tester, 'recovery-confirmation-confirm');
      await until(tester, () => entered!.isCompleted);
      expect(report.disposed, isTrue);
      // Keep the old dashboard mounted beneath the recovery routes while the
      // engine is paused. A mounted check alone cannot reject this stale result.
      expect(find.byType(DashboardScreen, skipOffstage: false), findsOneWidget);
      await tester.runAsync(() async {
        report.reply.complete('STALE ORIGINAL DATA REPORT');
      });
      await tester.pump();
      expect(
        find.text('STALE ORIGINAL DATA REPORT', skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async => release!.complete());
      await until(
        tester,
        () => container.read(recoveryCoordinatorProvider).state.terminal,
      );
      expect(
        container.read(recoveryCoordinatorProvider).state.phase,
        RecoveryPhase.succeeded,
      );
      expect(find.byType(DashboardScreen, skipOffstage: false), findsNothing);
      expect(container.read(remindersProvider).single.id, 'recovered');
      await tap(tester, 'recovery-outcome-continue');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('STALE ORIGINAL DATA REPORT'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
