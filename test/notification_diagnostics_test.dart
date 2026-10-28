import 'dart:async';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/services/notification_diagnostics_service.dart';
import 'package:dont_forget/services/notification_permission_service.dart';
import 'package:dont_forget/services/system_notification_reader.dart';
import 'package:dont_forget/ui/widgets/notification_diagnostics_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _PermissionBackend implements NotificationPermissionBackend {
  NotificationPermissionStatus status = NotificationPermissionStatus.granted;
  @override
  TargetPlatform platform = TargetPlatform.macOS;
  @override
  Future<NotificationAuthorization> readAuthorization() async =>
      NotificationAuthorization(status);
  @override
  Future<NotificationPermissionStatus> readExactAlarms() async =>
      NotificationPermissionStatus.unsupported;
  @override
  Future<void> requestExactAlarms() => throw StateError('No permission prompt');
  @override
  Future<void> requestNotifications() =>
      throw StateError('No permission prompt');
}

class _TestBackend implements TestNotificationBackend {
  final events = <String>[];
  final requests = <({String title, String body, DateTime trigger})>[];
  bool failSchedule = false, failCancel = false;
  Completer<void>? gate;
  @override
  bool supportsNativeScheduling = true;
  @override
  Future<void> cancel() async {
    events.add('cancel');
    if (failCancel) throw StateError('Cannot cancel');
  }

  @override
  Future<void> schedule({
    required String title,
    required String body,
    required DateTime trigger,
  }) async {
    events.add('schedule');
    requests.add((title: title, body: body, trigger: trigger));
    await gate?.future;
    if (failSchedule) throw StateError('Cannot schedule');
  }
}

class _Plugin implements FlutterLocalNotificationsPlugin {
  int? scheduledId, cancelledId;
  String? payload;
  NotificationDetails? details;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #cancel) {
      cancelledId = invocation.positionalArguments.first as int;
      return Future<void>.value();
    }
    if (invocation.memberName == #zonedSchedule) {
      scheduledId = invocation.positionalArguments.first as int;
      payload = invocation.namedArguments[#payload] as String?;
      details = invocation.positionalArguments[4] as NotificationDetails;
      return Future<void>.value();
    }
    throw StateError('Unexpected business operation: ${invocation.memberName}');
  }
}

const _schedule = NotificationScheduleStatus(
  upcoming: 5,
  submitted: 3,
  needsAttention: 2,
  cancellations: 1,
  overdueUnconfirmed: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 28, 12);
  late _PermissionBackend permission;
  late _TestBackend backend;
  late NotificationDiagnosticsService service;
  setUp(() {
    permission = _PermissionBackend();
    backend = _TestBackend();
    service = NotificationDiagnosticsService(
      permissions: NotificationPermissionService(backend: permission),
      backend: backend,
      readSystem: () async =>
          SystemNotificationSnapshot(supported: true, pending: []),
      readSchedule: () async => _schedule,
      readFailureHistory: () async =>
          const NotificationFailureHistory(available: true),
      now: () => now,
    );
  });

  test(
    'denied permission cancels the previous test and submits nothing',
    () async {
      permission.status = NotificationPermissionStatus.notEnabled;
      expect(
        await service.sendTest(title: 'Test', body: 'Body'),
        TestNotificationResult.permissionDenied,
      );
      expect(backend.events, ['cancel']);
      expect(backend.requests, isEmpty);
    },
  );

  test(
    'five-second test replacement is serialized and uses action-time clock',
    () async {
      backend.gate = Completer<void>();
      final first = service.sendTest(title: 'First', body: 'Test body');
      await Future<void>.delayed(Duration.zero);
      final second = service.sendTest(title: 'Second', body: 'Test body');
      await Future<void>.delayed(Duration.zero);
      expect(backend.events, ['cancel', 'schedule']);
      backend.gate!.complete();
      expect(await first, TestNotificationResult.submitted);
      expect(await second, TestNotificationResult.submitted);
      expect(backend.events, ['cancel', 'schedule', 'cancel', 'schedule']);
      expect(backend.requests.map((r) => r.title), ['First', 'Second']);
      expect(
        backend.requests.every(
          (r) => r.trigger == now.add(const Duration(seconds: 5)),
        ),
        isTrue,
      );
    },
  );

  test('scheduling and cancellation errors do not report submission', () async {
    backend.failSchedule = true;
    expect(
      await service.sendTest(title: 'Test', body: 'Body'),
      TestNotificationResult.failed,
    );
    backend.failSchedule = false;
    backend.failCancel = true;
    expect(
      await service.sendTest(title: 'Test', body: 'Body'),
      TestNotificationResult.failed,
    );
    expect(backend.requests, hasLength(1));
    backend.failCancel = false;
    expect(
      await service.sendTest(title: 'Test', body: 'Body'),
      TestNotificationResult.submitted,
    );
  });

  test('unsupported platforms do not call a native scheduler', () async {
    backend.supportsNativeScheduling = false;
    expect(
      await service.sendTest(title: 'Test', body: 'Body'),
      TestNotificationResult.unsupported,
    );
    expect(backend.events, isEmpty);
  });

  test('an invalid recovery token cannot submit a test', () async {
    service = NotificationDiagnosticsService(
      permissions: NotificationPermissionService(backend: permission),
      backend: backend,
      readSystem: service.readSystem,
      readSchedule: service.readSchedule,
      readFailureHistory: service.readFailureHistory,
      checkCurrent: () => throw StateError('Recovery started'),
    );
    expect(
      await service.sendTest(title: 'Test', body: 'Body'),
      TestNotificationResult.failed,
    );
    expect(backend.events, isEmpty);
  });

  test(
    'unavailable observations stay unknown while readable observations survive',
    () async {
      service = NotificationDiagnosticsService(
        permissions: NotificationPermissionService(backend: permission),
        backend: backend,
        readSystem: () async => throw StateError('Cannot read OS'),
        readSchedule: () async => _schedule,
        readFailureHistory: () async => throw StateError('Cannot read journal'),
      );
      final snapshot = await service.refresh();
      expect(
        snapshot.permission.authorization.status,
        NotificationPermissionStatus.granted,
      );
      expect(snapshot.pendingCount, isNull);
      expect(snapshot.failureHistory, isNull);
      expect(snapshot.schedule?.needsAttention, 2);
    },
  );

  test(
    'plugin test ID cannot collide with business IDs and payload cannot route',
    () async {
      final plugin = _Plugin();
      final native = PluginTestNotificationBackend(
        plugin: plugin,
        supportsNativeScheduling: true,
      );
      await native.cancel();
      await native.schedule(
        title: 'Localized test',
        body: 'Diagnostic',
        trigger: now,
      );
      expect(plugin.cancelledId, 0);
      expect(plugin.scheduledId, 0);
      expect(NotificationPayload.tryParse(plugin.payload), isNull);
      expect(plugin.details?.android?.channelName, 'Localized test');
      expect(plugin.details?.android?.actions, isNull);
      expect(plugin.details?.iOS?.categoryIdentifier, isNull);
    },
  );

  test(
    'failure readback uses the current journal in an isolated database',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'notification-diagnostics-',
      );
      final database = DatabaseHelper.forTesting(
        directory.path,
        databaseFactoryFfi,
      );
      try {
        final epoch = await database.readNotificationEpoch();
        expect(
          (await NotificationFailureHistory.read(database)).available,
          isFalse,
        );
        await database.withNotificationJournal((journal) async {
          await journal.reset(epoch);
          await journal.begin(
            epoch,
            'synthetic-failure',
            action: 'schedule',
            attemptedAt: now,
          );
          await journal.record(
            epoch,
            'synthetic-failure',
            action: 'schedule',
            status: 'failed',
            attemptedAt: now,
          );
        });
        final observed = await NotificationFailureHistory.read(database);
        expect(observed.available, isTrue);
        expect(observed.latestFailure, now);
        await database.withNotificationJournal(
          (journal) => journal.record(
            epoch,
            'synthetic-failure',
            action: 'schedule',
            status: 'submitted',
            attemptedAt: now,
          ),
        );
        expect(
          (await NotificationFailureHistory.read(database)).latestFailure,
          isNull,
        );
      } finally {
        await database.close(createBackup: false);
        await directory.delete(recursive: true);
      }
    },
  );

  Future<void> show(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh'), Locale('ja')],
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              child: NotificationDiagnosticsPanel(service: service),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const sendKey = ValueKey('notification-diagnostics-send');
  testWidgets(
    'leaving a self-check cancels deadlines for stalled file observations',
    (tester) async {
      final stalled = Completer<NotificationFailureHistory>();
      service = NotificationDiagnosticsService(
        permissions: NotificationPermissionService(backend: permission),
        backend: backend,
        readSystem: service.readSystem,
        readSchedule: service.readSchedule,
        readFailureHistory: () => stalled.future,
      );
      await show(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'self-check shows observations and says only submitted after a test',
    (tester) async {
      await show(tester);
      expect(find.text('System scheduled notifications: 0'), findsOneWidget);
      expect(find.text('Pending repair: 4'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(sendKey)).onPressed,
        isNotNull,
      );
      await tester.ensureVisible(find.byKey(sendKey));
      await tester.tap(find.byKey(sendKey));
      await tester.pumpAndSettle();
      expect(backend.events, ['cancel', 'schedule']);
      expect(find.text('Submitted to system'), findsOneWidget);
      expect(backend.requests.single.title, '[TEST] DontForget notification');
      expect(find.textContaining('Delivered'), findsNothing);
      await tester.tap(find.byKey(sendKey));
      await tester.pumpAndSettle();
      expect(backend.events, ['cancel', 'schedule', 'cancel', 'schedule']);
    },
  );

  testWidgets('permission rejection and scheduling failure remain distinct', (
    tester,
  ) async {
    permission.status = NotificationPermissionStatus.notEnabled;
    await show(tester);
    await tester.tap(find.byKey(sendKey));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Notifications are not enabled. Check system permission and try again.',
      ),
      findsOneWidget,
    );
    permission.status = NotificationPermissionStatus.granted;
    backend.failSchedule = true;
    await tester.tap(find.byKey(sendKey));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not submit the test notification. Check permission and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Submitted to system'), findsNothing);
  });

  testWidgets(
    'unavailable counts are explicit and unsupported platforms disclose runtime requirement',
    (tester) async {
      backend.supportsNativeScheduling = false;
      service = NotificationDiagnosticsService(
        permissions: NotificationPermissionService(backend: permission),
        backend: backend,
        readSystem: () async => SystemNotificationSnapshot(supported: false),
        readSchedule: () async => throw StateError('Unavailable'),
        readFailureHistory: () async => throw StateError('Unavailable'),
      );
      await show(tester);
      expect(
        find.text('System scheduled notifications: Temporarily unavailable'),
        findsOneWidget,
      );
      expect(
        find.text('Pending repair: Temporarily unavailable'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(sendKey)).onPressed,
        isNull,
      );
      expect(find.textContaining('Keep the app running'), findsOneWidget);
    },
  );

  for (final language in ['en', 'zh', 'ja']) {
    testWidgets('$language narrow screen and large text have no overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester, locale: Locale(language), scale: 2);
      expect(tester.takeException(), isNull);
      final l10n = AppLocalizations(Locale(language));
      expect(
        find.text(l10n.get('notificationDiagnosticsTitle')),
        findsOneWidget,
      );
      expect(
        l10n.get('notificationDiagnosticsTitle'),
        isNot('notificationDiagnosticsTitle'),
      );
    });
  }
}
