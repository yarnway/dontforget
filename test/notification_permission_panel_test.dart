import 'dart:async';

import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/services/notification_permission_service.dart';
import 'package:dont_forget/ui/widgets/notification_permission_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements NotificationPermissionBackend {
  @override
  TargetPlatform platform = TargetPlatform.macOS;
  NotificationPermissionStatus status = NotificationPermissionStatus.notEnabled;
  NotificationPermissionStatus exact = NotificationPermissionStatus.notEnabled;
  int reads = 0;
  int requests = 0;
  int exactRequests = 0;
  Completer<void>? gate;
  bool failRead = false;

  @override
  Future<NotificationAuthorization> readAuthorization() async {
    reads++;
    await gate?.future;
    if (failRead) throw StateError('query failed');
    return NotificationAuthorization(status);
  }

  @override
  Future<NotificationPermissionStatus> readExactAlarms() async =>
      platform == TargetPlatform.android
      ? exact
      : NotificationPermissionStatus.unsupported;

  @override
  Future<void> requestNotifications() async {
    requests++;
    status = NotificationPermissionStatus.granted;
  }

  @override
  Future<void> requestExactAlarms() async {
    exactRequests++;
    exact = NotificationPermissionStatus.granted;
  }
}

void main() {
  final l10n = AppLocalizations(const Locale('en'));
  const requestKey = ValueKey('notification-permission-request');
  const refreshKey = ValueKey('notification-permission-refresh');
  const statusKey = ValueKey('notification-permission-status');

  Future<void> show(
    WidgetTester tester,
    _Backend backend, {
    Locale locale = const Locale('en'),
    bool settle = true,
    Future<({int attempted, int failed})> Function()? onRetryReminders,
    Future<NotificationScheduleStatus> Function()? onReadScheduleStatus,
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
          body: SingleChildScrollView(
            child: NotificationPermissionPanel(
              service: NotificationPermissionService(backend: backend),
              onRetryReminders: onRetryReminders,
              onReadScheduleStatus: onReadScheduleStatus,
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  String? status(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(statusKey)).data;

  testWidgets(
    'initial query and refresh never request, button re-reads new state',
    (tester) async {
      final backend = _Backend();
      await show(tester, backend);
      expect(status(tester), l10n.get('notificationPermissionNotEnabled'));
      await tester.tap(find.byKey(refreshKey));
      await tester.pumpAndSettle();
      expect(backend.reads, 2);
      expect(backend.requests, 0);
      await tester.tap(find.byKey(requestKey));
      await tester.pumpAndSettle();
      expect(backend.requests, 1);
      expect(status(tester), l10n.get('notificationPermissionGranted'));
      expect(find.byKey(requestKey), findsNothing);
    },
  );

  testWidgets('returning from settings refreshes without prompting', (
    tester,
  ) async {
    final backend = _Backend();
    await show(tester, backend);
    backend.status = NotificationPermissionStatus.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(status(tester), l10n.get('notificationPermissionGranted'));
    expect(backend.requests, 0);
  });

  testWidgets('query failure is unknown with a working refresh action', (
    tester,
  ) async {
    final backend = _Backend()..failRead = true;
    await show(tester, backend);
    expect(status(tester), l10n.get('notificationPermissionUnknown'));
    backend
      ..failRead = false
      ..status = NotificationPermissionStatus.granted;
    await tester.tap(find.byKey(refreshKey));
    await tester.pumpAndSettle();
    expect(status(tester), l10n.get('notificationPermissionGranted'));
    expect(backend.requests, 0);
  });

  testWidgets(
    'pending query disables repeated actions and safely survives removal',
    (tester) async {
      final backend = _Backend();
      await show(tester, backend);
      backend.gate = Completer<void>();
      await tester.tap(find.byKey(refreshKey));
      await tester.pump();
      expect(
        tester.widget<TextButton>(find.byKey(refreshKey)).onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(requestKey)).onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      backend.gate!.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resumed event during query is coalesced into one fresh read', (
    tester,
  ) async {
    final backend = _Backend();
    await show(tester, backend);
    backend.gate = Completer<void>();
    await tester.tap(find.byKey(refreshKey));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    backend.gate!.complete();
    await tester.pumpAndSettle();
    expect(backend.reads, 3);
    expect(backend.requests, 0);
  });

  testWidgets('notification request is keyboard accessible', (tester) async {
    final backend = _Backend();
    await show(tester, backend);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(backend.requests, 1);
  });

  for (final locale in const [Locale('en'), Locale('zh'), Locale('ja')]) {
    testWidgets(
      '${locale.languageCode} Android panel fits 320px with large text',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final backend = _Backend()..platform = TargetPlatform.android;
        await show(
          tester,
          backend,
          locale: locale,
          onRetryReminders: () async => (attempted: 0, failed: 0),
          onReadScheduleStatus: () async => const NotificationScheduleStatus(
            upcoming: 1234,
            submitted: 1000,
            needsAttention: 234,
            cancellations: 3,
            overdueUnconfirmed: 2,
          ),
        );
        expect(
          find.byKey(const ValueKey('notification-exact-alarm-status')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('unsupported desktop has no request action', (tester) async {
    final backend = _Backend()
      ..platform = TargetPlatform.windows
      ..status = NotificationPermissionStatus.unsupported;
    await show(tester, backend);
    expect(find.byKey(requestKey), findsNothing);
    expect(status(tester), l10n.get('notificationPermissionUnsupported'));
    expect(backend.requests, 0);
  });

  testWidgets('query, permission request and resume never retry schedules', (
    tester,
  ) async {
    final backend = _Backend();
    var retries = 0;
    await show(
      tester,
      backend,
      onRetryReminders: () async {
        retries++;
        return (attempted: 1, failed: 0);
      },
    );
    await tester.tap(find.byKey(refreshKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(requestKey));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(retries, 0);
    await tester.tap(
      find.byKey(const ValueKey('notification-reminders-retry')),
    );
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(
      find.text(
        l10n.get('notificationRetryFinished').replaceAll('{total}', '1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'partial retry is reported and a second explicit retry can succeed',
    (tester) async {
      final backend = _Backend();
      var retries = 0;
      await show(
        tester,
        backend,
        onRetryReminders: () async {
          return (attempted: 3, failed: ++retries == 1 ? 2 : 0);
        },
      );
      final retry = find.byKey(const ValueKey('notification-reminders-retry'));
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(
        find.text(
          l10n
              .get('notificationRetryPartial')
              .replaceAll('{total}', '3')
              .replaceAll('{failed}', '2'),
        ),
        findsOneWidget,
      );
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(retries, 2);
      expect(
        find.text(
          l10n.get('notificationRetryFinished').replaceAll('{total}', '3'),
        ),
        findsOneWidget,
      );
      expect(backend.requests, 0);
    },
  );

  testWidgets('recovery rejection is visible and controls become retryable', (
    tester,
  ) async {
    await show(
      tester,
      _Backend(),
      onRetryReminders: () async {
        throw StateError('recovery in progress');
      },
    );
    final retry = find.byKey(const ValueKey('notification-reminders-retry'));
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.text(l10n.get('notificationRetryFailed')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(retry).onPressed, isNotNull);
  });

  testWidgets('retry disables repeated actions and survives panel disposal', (
    tester,
  ) async {
    final pending = Completer<({int attempted, int failed})>();
    await show(tester, _Backend(), onRetryReminders: () => pending.future);
    final retry = find.byKey(const ValueKey('notification-reminders-retry'));
    await tester.tap(retry);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(retry).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(refreshKey)).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    pending.complete((attempted: 1, failed: 0));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'schedule summary refresh and explicit retry use fresh saved state',
    (tester) async {
      var reads = 0;
      var retries = 0;
      await show(
        tester,
        _Backend(),
        onReadScheduleStatus: () async {
          reads++;
          return NotificationScheduleStatus(
            upcoming: 4,
            submitted: retries == 0 ? 1 : 4,
            needsAttention: retries == 0 ? 3 : 0,
            cancellations: 0,
            overdueUnconfirmed: 2,
          );
        },
        onRetryReminders: () async {
          retries++;
          return (attempted: 3, failed: 0);
        },
      );
      final summary = find.byKey(
        const ValueKey('notification-schedule-status'),
      );
      String expected(int submitted, int attention) => l10n
          .get('notificationScheduleSummary')
          .replaceAll('{upcoming}', '4')
          .replaceAll('{submitted}', '$submitted')
          .replaceAll('{attention}', '$attention')
          .replaceAll('{cancellations}', '0');
      expect(tester.widget<Text>(summary).data, expected(1, 3));
      expect(
        find.text(
          l10n.get('notificationScheduleOverdue').replaceAll('{count}', '2'),
        ),
        findsOneWidget,
      );
      final refresh = find.byKey(refreshKey);
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(retries, 0);
      final retry = find.byKey(const ValueKey('notification-reminders-retry'));
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(reads, 3);
      expect(retries, 1);
      expect(tester.widget<Text>(summary).data, expected(4, 0));
    },
  );

  testWidgets(
    'schedule read failure is unavailable rather than an empty queue',
    (tester) async {
      await show(
        tester,
        _Backend(),
        onReadScheduleStatus: () async {
          throw StateError('synthetic unavailable');
        },
      );
      expect(
        find.text(l10n.get('notificationScheduleUnavailable')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unsupported platforms do not read a native schedule journal', (
    tester,
  ) async {
    var reads = 0;
    await show(
      tester,
      _Backend()..platform = TargetPlatform.windows,
      onReadScheduleStatus: () async {
        reads++;
        throw StateError('must not read');
      },
    );
    expect(reads, 0);
    expect(
      find.byKey(const ValueKey('notification-schedule-status')),
      findsNothing,
    );
  });

  testWidgets('pending schedule read is ignored after panel removal', (
    tester,
  ) async {
    final gate = Completer<NotificationScheduleStatus>();
    await show(
      tester,
      _Backend(),
      onReadScheduleStatus: () => gate.future,
      settle: false,
    );
    await tester.pumpWidget(const SizedBox());
    gate.complete(
      const NotificationScheduleStatus(
        upcoming: 0,
        submitted: 0,
        needsAttention: 0,
        cancellations: 0,
        overdueUnconfirmed: 0,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
