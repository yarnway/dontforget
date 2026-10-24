import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/notification_schedule_status.dart';
import 'package:dont_forget/services/notification_permission_service.dart';
import 'package:dont_forget/services/system_notification_reader.dart';
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
    Future<SystemNotificationSnapshot> Function()? onReadSystemNotifications,
    NotificationPermissionService? service,
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
              service:
                  service ?? NotificationPermissionService(backend: backend),
              onRetryReminders: onRetryReminders,
              onReadScheduleStatus: onReadScheduleStatus,
              onReadSystemNotifications: onReadSystemNotifications,
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
    'OS results show unavailable separately from zero and disclose only three titles',
    (tester) async {
      final backend = _Backend();
      await show(
        tester,
        backend,
        onReadSystemNotifications: () async => SystemNotificationSnapshot(
          supported: true,
          pending: [],
          retained: [
            for (var i = 0; i < 5; i++)
              SystemNotificationEntry(id: i, title: 'Retained $i'),
          ],
        ),
      );
      expect(find.text('System pending 0 · Retained 5'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('notification-system-retained')),
      );
      await tester.tap(
        find.byKey(const ValueKey('notification-system-retained')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retained 2'), findsOneWidget);
      expect(find.text('Retained 3'), findsNothing);
      expect(backend.requests, 0);
      await show(
        tester,
        backend,
        onReadSystemNotifications: () async =>
            SystemNotificationSnapshot(supported: true, pending: []),
      );
      expect(find.text('System pending 0 · Retained —'), findsOneWidget);
    },
  );

  testWidgets('replaced OS reader cannot publish an old delayed observation', (
    tester,
  ) async {
    final backend = _Backend();
    final service = NotificationPermissionService(backend: backend);
    final old = Completer<SystemNotificationSnapshot>();
    await show(
      tester,
      backend,
      service: service,
      settle: false,
      onReadSystemNotifications: () => old.future,
    );
    await show(
      tester,
      backend,
      service: service,
      onReadSystemNotifications: () async => SystemNotificationSnapshot(
        supported: true,
        pending: [],
        retained: [],
      ),
    );
    old.complete(
      SystemNotificationSnapshot(
        supported: true,
        pending: [],
        retained: [const SystemNotificationEntry(id: 1, title: 'Obsolete')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('System pending 0 · Retained 0'), findsOneWidget);
    expect(find.text('Obsolete'), findsNothing);
  });

  testWidgets('retained titles expand and collapse through accessibility', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await show(
        tester,
        _Backend(),
        onReadSystemNotifications: () async => SystemNotificationSnapshot(
          supported: true,
          pending: [],
          retained: [const SystemNotificationEntry(id: 1, title: 'OS title')],
        ),
      );
      final header = find.text('Retained notifications (up to 3)');
      await tester.ensureVisible(header);
      await tester.pumpAndSettle();
      final collapsed = tester.getSemantics(header);
      final data = collapsed.getSemanticsData();
      // On macOS the surrounding Card previously acquired the disclosure's
      // tap action, making all explanatory text part of the button label.
      final panel = tester.getSemantics(
        find.byKey(const ValueKey('notification-permission-panel')),
      );
      expect(panel.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      expect(data.label, 'Retained notifications (up to 3)');
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      collapsed.owner!.performAction(collapsed.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.text('OS title'), findsOneWidget);
      final expanded = tester.getSemantics(header);
      expect(expanded.getSemanticsData().flagsCollection.isButton, isTrue);
      expanded.owner!.performAction(expanded.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.text('OS title'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('stalled observations release refresh and ignore late results', (
    tester,
  ) async {
    final schedule = Completer<NotificationScheduleStatus>();
    final system = Completer<SystemNotificationSnapshot>();
    var first = true;
    await show(
      tester,
      _Backend(),
      settle: false,
      onReadScheduleStatus: () => first
          ? schedule.future
          : Future.value(
              const NotificationScheduleStatus(
                upcoming: 2,
                submitted: 1,
                needsAttention: 1,
                cancellations: 0,
                overdueUnconfirmed: 0,
              ),
            ),
      onReadSystemNotifications: () => first
          ? system.future
          : Future.value(
              SystemNotificationSnapshot(
                supported: true,
                pending: [],
                retained: [],
              ),
            ),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('System pending — · Retained —'), findsOneWidget);
    expect(
      find.text(l10n.get('notificationScheduleUnavailable')),
      findsOneWidget,
    );
    final refresh = find.byKey(refreshKey);
    expect(tester.widget<TextButton>(refresh).onPressed, isNotNull);
    first = false;
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(find.text('System pending 0 · Retained 0'), findsOneWidget);
    expect(find.textContaining('Upcoming 2 · Submitted 1'), findsOneWidget);
    schedule.complete(
      const NotificationScheduleStatus(
        upcoming: 99,
        submitted: 99,
        needsAttention: 0,
        cancellations: 0,
        overdueUnconfirmed: 0,
      ),
    );
    system.complete(
      SystemNotificationSnapshot(
        supported: true,
        retained: [const SystemNotificationEntry(id: 9, title: 'Late')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('System pending 0 · Retained 0'), findsOneWidget);
    expect(find.textContaining('Upcoming 99'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

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

  for (final throws in [false, true]) {
    testWidgets('refresh replaces old manual retry feedback (throws=$throws)', (
      tester,
    ) async {
      var unavailable = false;
      var retries = 0;
      final backend = _Backend();
      await show(
        tester,
        backend,
        onRetryReminders: () async {
          retries++;
          if (throws) throw StateError('temporary failure');
          return (attempted: 4, failed: 4);
        },
        onReadScheduleStatus: () async {
          if (unavailable) throw StateError('status unavailable');
          return const NotificationScheduleStatus(
            upcoming: 4,
            submitted: 4,
            needsAttention: 0,
            cancellations: 0,
            overdueUnconfirmed: 0,
          );
        },
      );
      final retry = find.byKey(const ValueKey('notification-reminders-retry'));
      final feedback = find.byKey(const ValueKey('notification-retry-result'));
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      // A durable summary alone cannot erase a failure before journal writing.
      expect(feedback, findsOneWidget);
      final refresh = find.byKey(refreshKey);
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(feedback, findsNothing);
      expect(retries, 1);

      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(feedback, findsOneWidget);
      unavailable = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(feedback, findsNothing);
      expect(
        find.text(l10n.get('notificationScheduleUnavailable')),
        findsOneWidget,
      );
      expect(retries, 2);
      expect(backend.requests, 0);
    });
  }

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
