import 'ui/widgets/inline_feedback.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/editor_keyboard_actions.dart';
import 'ui/widgets/focused_text_commands.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'providers/providers.dart';
import 'providers/home_controller.dart';
import 'providers/recovery_coordinator.dart';
import 'data/database_helper.dart';
import 'models/reminder.dart';
import 'services/notification_route_service.dart';
import 'services/pending_notification_actions.dart';
import 'services/live_reminder_service.dart';
import 'models/notification_payload.dart';
import 'services/notification_service.dart';
import 'services/desktop_shutdown.dart';
import 'services/desktop_window_service.dart';
import 'services/startup_trace.dart';
import 'services/mac_menu_commands.dart';
import 'services/recovery/runtime_gate.dart';
import 'services/windows_protocol_service.dart';
import 'services/android_protocol_service.dart';
import 'services/android_share_service.dart';
import 'services/shared_text_inbox.dart';
import 'providers/shared_text_provider.dart';
import 'providers/workspace_drafts_provider.dart';
import 'l10n/shared_text_strings.dart';
import 'ui/screens/shared_text_inbox_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/recovery_outcome_screen.dart';
import 'ui/screens/task_detail_screen.dart';
import 'ui/screens/preferences_screen.dart';
import 'l10n/app_localizations.dart';

typedef _MacInputToken = ({DataGeneration data, RuntimeRecoveryToken runtime});

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key, this.initialProtocolRoute});

  final ProtocolRoute? initialProtocolRoute;

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  late final NotificationService _notifications;
  late final RecoveryCoordinator _recovery;
  late final RuntimeRecoveryGate _actionRuntimeGate;
  late final NotificationRouteService _notificationRoutes;
  late final NotificationActionRouteService _notificationActions;
  StreamSubscription<void>? _notificationActionSubscription;
  StreamSubscription<String>? _notificationSubscription;
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  DataGeneration? _routeDataGeneration;
  RemindersNotifier? _routeReminders;
  int _routeInitialization = 0;
  int _navigationEpoch = 0;
  RecoveryPhase _lastRecoveryPhase = RecoveryPhase.idle;
  bool _routeDataReady = false;
  bool _routeFramePending = false;
  MacMenuCommands<_MacInputToken>? _macMenu;
  Route<void>? _nativeSettingsRoute;
  ProtocolRoute? _pendingProtocolRoute;
  bool _protocolFramePending = false;
  final _androidProtocol = AndroidProtocolService();
  final _androidShares = AndroidShareService();
  bool _sharesAvailable = false,
      _shareFramePending = false,
      _shareAgain = false;
  int _shareEpoch = 0;
  Object? _shareDrain;
  Route<void>? _sharedInboxRoute;
  bool _sharedInboxWanted = false, _sharedInboxFramePending = false;
  late final bool Function() _openSharedCommand;
  late final SharedTextInboxCommand _sharedCommand;
  String? _openProtocolTaskId;
  String? _pendingLivePayload;
  String? _openLiveIdentity;
  bool _liveFramePending = false;

  bool get _supportsLiveActivities =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _supportsAndroidProtocol =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _supportsProtocol =>
      !kIsWeb && (Platform.isWindows || _supportsAndroidProtocol);

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _notifications = ref.read(notificationServiceProvider);
    _notifications.attachNotificationActionReceiver();
    _recovery = ref.read(recoveryCoordinatorProvider);
    _actionRuntimeGate = ref.read(runtimeRecoveryGateProvider);
    _openSharedCommand = _openSharedInbox;
    _sharedCommand = ref.read(sharedTextInboxCommandProvider);
    _sharedCommand.open = _openSharedCommand;
    _navigationEpoch = _recovery.navigationEpoch;
    _lastRecoveryPhase = _recovery.state.phase;
    if (Platform.isMacOS) {
      _macMenu = MacMenuCommands<_MacInputToken>(
        beginInput: _beginNativeInput,
        isCurrent: _isNativeInputCurrent,
        submitInput: (text) =>
            ref.read(homeControllerProvider.notifier).processText(text),
        openSettings: _openNativeSettings,
        openTools: () =>
            _nativeCommandsReady &&
            (ref.read(workspaceToolsCommandProvider).open?.call() ?? false),
        openSearch: () =>
            _nativeCommandsReady &&
            (ref.read(workspaceToolsCommandProvider).search?.call() ?? false),
        saveEditor: () =>
            _nativeCommandsReady && EditorKeyboardActions.saveFocusedEditor(),
        editText: (command, isCurrent) => FocusedTextCommands.run(
          command,
          isCurrent: () => isCurrent() && _nativeCommandsReady,
        ),
      )..start();
    }
    _notificationRoutes = NotificationRouteService(
      readSnapshot: _notificationSnapshot,
      openReminder: _openNotificationReminder,
    );
    _notificationActions = NotificationActionRouteService(
      readQueue: _notifications.pendingNotificationActions,
      readSnapshot: _notificationSnapshot,
      apply: _applyNotificationAction,
      onResult: _notificationActionFeedback,
    );
    _actionRuntimeGate.register(
      _notificationActions,
      () => _notificationActions.setReady(false),
    );
    _notificationActionSubscription = _notifications.onNotificationAction
        .listen((_) => _drainNotificationActions());
    _notificationSubscription = _notifications.onNotificationPayload.listen(
      _receiveNotificationPayload,
    );
    if (_supportsLiveActivities) {
      ChannelLiveReminderBackend.channel.setMethodCallHandler((call) async {
        if (call.method == 'openReminder' && call.arguments is String) {
          _receiveLivePayload(call.arguments as String);
        }
      });
      unawaited(
        ChannelLiveReminderBackend.channel
            .invokeMethod<String>('initialize')
            .then((payload) {
              if (payload != null && mounted) _receiveLivePayload(payload);
            })
            .catchError((Object _) {}),
      );
    }
    for (final payload in _notifications.takePendingNotificationPayloads()) {
      _receiveNotificationPayload(payload);
    }
    if (widget.initialProtocolRoute != null) {
      _pendingProtocolRoute = widget.initialProtocolRoute;
    }
    if (_supportsAndroidProtocol) {
      unawaited(_androidProtocol.initialize(onRoute: _receiveProtocolRoute));
    } else if (_supportsProtocol) {
      WindowsProtocolService.initialize(onRoute: _receiveProtocolRoute);
    }
    _recovery.addListener(_onRecoveryChanged);
    _prepareNotificationRoutes();
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }
  }

  void _receiveNotificationPayload(String payload) {
    if (!mounted) return;
    try {
      _notificationRoutes.receive(payload);
    } catch (error) {
      // A temporarily unavailable navigator keeps the click queued for the
      // next readiness signal. It must never turn a click into a data write.
      debugPrint('Notification route deferred: $error');
    }
    _scheduleNotificationRoutes();
  }

  void _onRecoveryChanged() {
    final phase = _recovery.state.phase;
    final enteringRecovery =
        _lastRecoveryPhase == RecoveryPhase.idle && phase != RecoveryPhase.idle;
    if (enteringRecovery) _macMenu?.invalidate();
    if (enteringRecovery) {
      _pendingProtocolRoute = null;
      _openProtocolTaskId = null;
      _androidProtocol.invalidatePendingInitialization();
      _shareEpoch++;
      _sharesAvailable = false;
      _shareDrain = null;
      _sharedInboxRoute = null;
      _sharedInboxWanted = false;
      if (_supportsAndroidProtocol) {
        unawaited(_androidShares.resetForRecovery().catchError((Object _) {}));
      }
    }
    if (enteringRecovery && _supportsLiveActivities) {
      _pendingLivePayload = null;
      _openLiveIdentity = null;
      unawaited(
        ref.read(liveReminderServiceProvider).stop().catchError((Object _) {}),
      );
    }
    _lastRecoveryPhase = phase;
    _routeInitialization++;
    _routeDataReady = false;
    _routeDataGeneration = null;
    _syncMacMenu();
    _routeReminders = null;
    _notificationRoutes.setReady(
      false,
      // Only discard clicks from before recovery. Notifications rebuilt with
      // the new epoch may be clicked while providers or navigation are loading;
      // keep them queued and reject any old epoch at the final readiness check.
      discardPending: enteringRecovery,
    );
    unawaited(_notificationActions.setReady(false));
    if (_navigationEpoch != _recovery.navigationEpoch) {
      _navigationEpoch = _recovery.navigationEpoch;
      // Reusing this GlobalKey would reparent the previous Navigator and retain
      // stale editors even though MaterialApp has a new recovery epoch key.
      _navigatorKey = GlobalKey<NavigatorState>();
    }
    if (phase == RecoveryPhase.idle) {
      _prepareNotificationRoutes();
    }
  }

  Future<void> _prepareNotificationRoutes() async {
    if (_recovery.state.phase != RecoveryPhase.idle) return;
    final initialization = ++_routeInitialization;
    final database = ref.read(databaseHelperProvider);
    try {
      final generation = database.captureGeneration();
      final reminders = ref.read(remindersProvider.notifier);
      await Future.wait([reminders.ready, _notifications.init()]);
      if (!mounted ||
          initialization != _routeInitialization ||
          _recovery.state.phase != RecoveryPhase.idle ||
          !database.isCurrent(generation) ||
          !identical(reminders, ref.read(remindersProvider.notifier))) {
        return;
      }
      _routeDataGeneration = generation;
      _routeReminders = reminders;
      _routeDataReady = true;
      unawaited(_syncNotificationLanguage());
      _drainNotificationActions();
      _syncLiveReminder();
      _syncMacMenu();
      StartupTrace.mark('notifications_ready');
      _scheduleNotificationRoutes();
      if (_supportsAndroidProtocol) unawaited(_initializeSharedTexts());
      if (_pendingProtocolRoute != null) {
        _scheduleProtocolRoute();
      }
    } catch (error) {
      // Recovery/read errors are handled by their owning screens. A route is
      // never allowed to bypass a failed load by treating an empty list as data.
      debugPrint('Notification routes unavailable: $error');
      StartupTrace.fail('notification_routes');
    }
  }

  bool get _nativeCommandsReady =>
      mounted &&
      _routeDataReady &&
      _recovery.state.phase == RecoveryPhase.idle &&
      !ref.read(runtimeRecoveryGateProvider).paused;

  Future<void> _initializeSharedTexts() async {
    final epoch = ++_shareEpoch;
    final dataset = _notifications.datasetEpoch;
    if (dataset == null) return;
    final available = await _androidShares.initialize(
      datasetEpoch: dataset,
      onPending: _scheduleSharedTexts,
    );
    if (!mounted || epoch != _shareEpoch || !_nativeCommandsReady) return;
    _sharesAvailable = available;
    _scheduleSharedTexts();
  }

  void _scheduleSharedTexts() {
    if (!_sharesAvailable ||
        !_nativeCommandsReady ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (_shareDrain != null) {
      _shareAgain = true;
      return;
    }
    if (_shareFramePending) return;
    _shareFramePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _shareFramePending = false;
      if (mounted && _sharesAvailable && _nativeCommandsReady) {
        unawaited(_drainSharedTexts());
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _drainSharedTexts() async {
    if (_shareDrain != null) {
      _shareAgain = true;
      return;
    }
    final owner = Object();
    _shareDrain = owner;
    _shareAgain = false;
    final epoch = _shareEpoch;
    bool current() => mounted && epoch == _shareEpoch && _nativeCommandsReady;
    try {
      final pending = await _androidShares.pending();
      if (!current() || pending.isEmpty) return;
      final inbox = ref.read(sharedTextInboxProvider);
      for (final item in pending) {
        if (!current()) return;
        final accepted = await inbox.accept(item);
        if (!current()) return;
        if (!accepted) {
          _sharedFeedback('full');
          break;
        }
        await _androidShares.acknowledge(item.id);
      }
      if (current() &&
          SharedTextInbox.count(ref.read(workspaceDraftsProvider)) > 0) {
        _openSharedInbox();
      }
    } catch (_) {
      if (current()) _sharedFeedback('failed');
    } finally {
      if (identical(owner, _shareDrain)) {
        _shareDrain = null;
        if (_shareAgain) _scheduleSharedTexts();
      }
    }
  }

  void _sharedFeedback(String key) {
    final context = _navigatorKey.currentContext;
    if (context == null || !mounted) return;
    context.findAncestorStateOfType<InlineFeedbackState>()?.showSnackBar(
      SnackBar(
        content: Text(
          sharedTextLabel(ref.read(settingsProvider).language, key),
        ),
      ),
    );
  }

  bool _openSharedInbox() {
    if (!_nativeCommandsReady) return false;
    if (_sharedInboxRoute != null) {
      _sharedInboxWanted = false;
      return true;
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      _sharedInboxWanted = true;
      return false;
    }
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/shared-drafts'),
      builder: (_) => const SharedTextInboxScreen(),
    );
    _sharedInboxRoute = route;
    _sharedInboxWanted = false;
    unawaited(
      navigator.push<void>(route).whenComplete(() {
        if (identical(_sharedInboxRoute, route)) _sharedInboxRoute = null;
      }),
    );
    return true;
  }

  Future<void> _syncNotificationLanguage() async {
    final settings = ref.read(settingsProvider.notifier);
    try {
      await settings.ready;
      if (!mounted ||
          !_nativeCommandsReady ||
          !identical(settings, ref.read(settingsProvider.notifier))) {
        return;
      }
      await _notifications.setNotificationLanguage(
        ref.read(settingsProvider).language,
      );
      if (_isDesktop) unawaited(_updateTrayMenu());
    } catch (_) {
      // Existing journal/repair readback reports any failed native reschedule.
    }
  }

  Future<NotificationActionOutcome> _applyNotificationAction(
    Reminder reminder,
    NotificationActionRequest request,
  ) async {
    if (!_nativeCommandsReady) return NotificationActionOutcome.rejected;
    final gate = ref.read(runtimeRecoveryGateProvider);
    final token = gate.capture();
    gate.check(token);
    final result = await ref
        .read(remindersProvider.notifier)
        .performNotificationAction(
          reminder,
          payload: request.payload,
          actionId: request.actionId,
          occurredAt: request.occurredAt,
        );
    if (!result.accepted) return NotificationActionOutcome.rejected;
    return result.nativeSyncFailed
        ? NotificationActionOutcome.repair
        : NotificationActionOutcome.applied;
  }

  void _notificationActionFeedback(NotificationActionOutcome outcome) {
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final feedback = context.findAncestorStateOfType<InlineFeedbackState>();
    feedback?.showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context).get(
            outcome == NotificationActionOutcome.repair
                ? 'notificationActionRepair'
                : 'notificationActionApplied',
          ),
        ),
      ),
    );
  }

  void _drainNotificationActions() {
    if (!_nativeCommandsReady) return;
    unawaited(
      _notificationActions.setReady(true).catchError((Object _) {
        if (!mounted) return;
        final feedbackContext = _navigatorKey.currentContext;
        if (feedbackContext == null || !feedbackContext.mounted) return;
        feedbackContext
            .findAncestorStateOfType<InlineFeedbackState>()
            ?.showSnackBar(
              SnackBar(
                content: Text(
                  AppLocalizations.of(
                    feedbackContext,
                  ).get('notificationActionFailed'),
                ),
              ),
            );
      }),
    );
  }

  void _receiveLivePayload(String encoded) {
    final payload = NotificationPayload.tryParse(encoded);
    if (!mounted || payload == null || payload.identity == _openLiveIdentity) {
      return;
    }
    _pendingLivePayload = encoded;
    _scheduleLiveRoute();
  }

  void _scheduleLiveRoute() {
    if (!_supportsLiveActivities ||
        _liveFramePending ||
        _pendingLivePayload == null ||
        !_routeDataReady) {
      return;
    }
    _liveFramePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _liveFramePending = false;
      if (!mounted) return;
      final snapshot = _notificationSnapshot();
      final navigator = _navigatorKey.currentState;
      if (snapshot == null || navigator == null) return;
      final payload = NotificationPayload.tryParse(_pendingLivePayload);
      _pendingLivePayload = null;
      if (payload == null || _openLiveIdentity != null) return;
      final target = snapshot.reminders
          .where(
            (task) => payload.matches(
              task,
              currentDatasetEpoch: snapshot.datasetEpoch,
            ),
          )
          .firstOrNull;
      if (target == null) return;
      _openLiveIdentity = payload.identity;
      final navigationEpoch = _navigationEpoch;
      unawaited(
        navigator
            .push<void>(
              MaterialPageRoute<void>(
                settings: RouteSettings(name: '/live-reminder/${target.id}'),
                builder: (_) => _nativeTaskDetail(target, navigationEpoch),
              ),
            )
            .whenComplete(() {
              if (_openLiveIdentity == payload.identity) {
                _openLiveIdentity = null;
              }
            }),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _syncLiveReminder() {
    if (!_supportsLiveActivities || !_nativeCommandsReady) return;
    final epoch = _notifications.datasetEpoch;
    if (epoch == null) return;
    unawaited(
      ref
          .read(liveReminderServiceProvider)
          .synchronize(
            ref.read(remindersProvider),
            epoch,
            ref.read(settingsProvider).language,
          )
          .catchError((Object _) {}),
    );
    _scheduleLiveRoute();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleSharedTexts();
      _syncLiveReminder();
      _drainNotificationActions();
      unawaited(_syncNotificationLanguage());
      if (_pendingProtocolRoute != null) {
        _scheduleProtocolRoute();
      }
    }
  }

  Future<_MacInputToken?> _beginNativeInput() async {
    if (!_nativeCommandsReady) return null;
    final token = (
      data: ref.read(databaseHelperProvider).captureGeneration(),
      runtime: ref.read(runtimeRecoveryGateProvider).capture(),
    );
    await Future.wait([
      ref.read(settingsProvider.notifier).ready,
      ref.read(remindersProvider.notifier).ready,
      ref.read(mediaRecordsProvider.notifier).ready,
    ]);
    return _isNativeInputCurrent(token) ? token : null;
  }

  bool _isNativeInputCurrent(_MacInputToken token) =>
      _nativeCommandsReady &&
      ref.read(databaseHelperProvider).isCurrent(token.data) &&
      ref.read(runtimeRecoveryGateProvider).isCurrent(token.runtime);

  bool _openNativeSettings() {
    final navigator = _navigatorKey.currentState;
    if (!_nativeCommandsReady ||
        navigator == null ||
        _nativeSettingsRoute != null) {
      return false;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => const PreferencesScreen(),
    );
    _nativeSettingsRoute = route;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (identical(_nativeSettingsRoute, route)) _nativeSettingsRoute = null;
      }),
    );
    return true;
  }

  void _syncMacMenu() {
    final menu = _macMenu;
    if (menu == null || !mounted) return;
    final l10n = AppLocalizations(Locale(ref.read(settingsProvider).language));
    unawaited(
      menu.configure({
        for (final key in [
          'quickEntry',
          'quickEntryTitle',
          'quickEntryHint',
          'quickEntryContent',
          'moreTools',
          'settings',
          'send',
          'cancel',
          'saveChanges',
        ])
          key: l10n.get(key),
      }, enabled: _nativeCommandsReady),
    );
  }

  NotificationRouteSnapshot? _notificationSnapshot() {
    if (!mounted ||
        !_routeDataReady ||
        _recovery.state.phase != RecoveryPhase.idle ||
        _notifications.isPausedForMaintenance) {
      return null;
    }
    if (ref.read(runtimeRecoveryGateProvider).paused) return null;
    final generation = _routeDataGeneration;
    final epoch = _notifications.datasetEpoch;
    if (generation == null ||
        epoch == null ||
        !ref.read(databaseHelperProvider).isCurrent(generation) ||
        !identical(_routeReminders, ref.read(remindersProvider.notifier))) {
      return null;
    }
    return NotificationRouteSnapshot(
      datasetEpoch: epoch,
      reminders: ref.read(remindersProvider),
    );
  }

  void _scheduleNotificationRoutes() {
    if (!mounted || !_routeDataReady || _routeFramePending) return;
    _routeFramePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeFramePending = false;
      if (!mounted ||
          !_routeDataReady ||
          _recovery.state.phase != RecoveryPhase.idle ||
          _navigatorKey.currentState == null) {
        return;
      }
      try {
        _notificationRoutes.setReady(true);
        _drainNotificationActions();
        StartupTrace.mark('routes_ready_frame');
      } catch (error) {
        debugPrint('Notification navigation unavailable: $error');
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool _openNotificationReminder(
    Reminder reminder, {
    bool fromProtocol = false,
  }) {
    final navigator = _navigatorKey.currentState;
    if (!mounted ||
        navigator == null ||
        _recovery.state.phase != RecoveryPhase.idle) {
      return false;
    }
    if (fromProtocol && _openProtocolTaskId == reminder.id) return true;
    final navigationEpoch = _navigationEpoch;
    if (fromProtocol) _openProtocolTaskId = reminder.id;
    unawaited(
      navigator
          .push<void>(
            MaterialPageRoute<void>(
              settings: RouteSettings(name: '/notification/${reminder.id}'),
              builder: (_) => _nativeTaskDetail(reminder, navigationEpoch),
            ),
          )
          .whenComplete(() {
            if (fromProtocol &&
                navigationEpoch == _navigationEpoch &&
                _openProtocolTaskId == reminder.id) {
              _openProtocolTaskId = null;
            }
          }),
    );
    if (_isDesktop) unawaited(_showNotificationWindow());
    return true;
  }

  Widget _nativeTaskDetail(Reminder task, int navigationEpoch) =>
      TaskDetailScreen(
        task: task,
        onPlayMedia: task.recordId == null
            ? null
            : () {
                if (!mounted ||
                    navigationEpoch != _navigationEpoch ||
                    !_nativeCommandsReady) {
                  return;
                }
                ref
                    .read(workspaceToolsCommandProvider)
                    .playMedia
                    ?.call(task.recordId!);
              },
      );

  Future<void> _showNotificationWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // Desktop activation can be unavailable while the Flutter route remains
      // usable (including widget tests and a host without a window manager).
    }
  }

  void _receiveProtocolRoute(ProtocolRoute route) {
    if (!mounted ||
        _recovery.state.phase != RecoveryPhase.idle ||
        ref.read(runtimeRecoveryGateProvider).paused) {
      return;
    }
    _pendingProtocolRoute = route;
    if (_routeDataReady) {
      _scheduleProtocolRoute();
    }
  }

  void _scheduleProtocolRoute() {
    if (!_supportsProtocol ||
        !_routeDataReady ||
        _protocolFramePending ||
        _pendingProtocolRoute == null) {
      return;
    }
    _protocolFramePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _protocolFramePending = false;
      if (!mounted || !_routeDataReady || !_nativeCommandsReady) {
        return;
      }
      final route = _pendingProtocolRoute;
      _pendingProtocolRoute = null;
      if (route == null) return;
      _dispatchProtocolRoute(route);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _dispatchProtocolRoute(ProtocolRoute route) {
    if (!_nativeCommandsReady) return;
    final snapshot = _notificationSnapshot();
    if (snapshot == null) return;
    final target = snapshot.reminders
        .where((r) => r.id == route.taskId && r.isVisible)
        .firstOrNull;
    if (target == null) {
      if (_isDesktop) unawaited(_showNotificationWindow());
      return;
    }

    switch (route.action) {
      case ProtocolAction.viewTask:
        _openNotificationReminder(target, fromProtocol: true);
      case ProtocolAction.completeTask || ProtocolAction.snoozeTask:
        unawaited(_applyProtocolAction(route, target));
        if (_isDesktop) unawaited(_showNotificationWindow());
    }
  }

  Future<void> _applyProtocolAction(
    ProtocolRoute route,
    Reminder target,
  ) async {
    if (!_nativeCommandsReady) return;
    final notifier = ref.read(remindersProvider.notifier);
    try {
      final payload = route.payload;
      final ReminderActionResult result;
      if (payload != null) {
        result = await notifier.performNotificationAction(
          target,
          payload: payload,
          actionId: route.action == ProtocolAction.completeTask
              ? 'complete'
              : route.snoozeMinutes == 60
              ? 'snooze_60'
              : 'snooze_15',
          occurredAt: DateTime.now(),
        );
      } else {
        // Keep existing Windows links compatible; Android never mutates from
        // an ID-only URL, including a directly injected initial route.
        if (_supportsAndroidProtocol) return;
        result = route.action == ProtocolAction.completeTask
            ? await notifier.completeOccurrence(target)
            : await notifier.snoozeOccurrence(
                target,
                duration: Duration(minutes: route.snoozeMinutes ?? 15),
              );
      }
      if (result.accepted) {
        _notificationActionFeedback(
          result.nativeSyncFailed
              ? NotificationActionOutcome.repair
              : NotificationActionOutcome.applied,
        );
      }
    } catch (_) {
      if (!mounted) return;
      final feedbackContext = _navigatorKey.currentContext;
      if (feedbackContext == null || !feedbackContext.mounted) return;
      feedbackContext
          .findAncestorStateOfType<InlineFeedbackState>()
          ?.showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(
                  feedbackContext,
                ).get('notificationActionFailed'),
              ),
            ),
          );
    }
  }

  Future<void> _initTray() async {
    if (!_isDesktop) return;
    try {
      // Note: Windows icon must be .ico format and bundled in assets
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/app_icon.ico'
            : 'assets/app_icon.png', // Fallback for macOS and Linux
      );
      // The Linux tray backend does not implement tooltips.
      if (!Platform.isLinux) await trayManager.setToolTip("DontForget");
      await _updateTrayMenu();
    } catch (e) {
      debugPrint('Tray initialization error: $e');
    }
  }

  Future<void> _updateTrayMenu() async {
    if (!_isDesktop) return;
    try {
      final language = ref.read(settingsProvider).language;
      final l10n = AppLocalizations(Locale(language));
      final menu = Menu(
        items: [
          MenuItem(key: 'show_window', label: l10n.get('trayShowWindow')),
          MenuItem.separator(),
          MenuItem(key: 'exit_app', label: l10n.get('trayExitApp')),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (e) {
      debugPrint('Tray menu update error: $e');
    }
  }

  @override
  void dispose() {
    _shareEpoch++;
    _androidShares.dispose();
    if (identical(_sharedCommand.open, _openSharedCommand)) {
      _sharedCommand.open = null;
    }
    _macMenu?.dispose();
    if (_supportsLiveActivities) {
      ChannelLiveReminderBackend.channel.setMethodCallHandler(null);
    }
    if (_supportsAndroidProtocol) {
      _androidProtocol.dispose();
    } else if (_supportsProtocol) {
      WindowsProtocolService.dispose();
    }
    _routeInitialization++;
    _recovery.removeListener(_onRecoveryChanged);
    unawaited(_notificationSubscription?.cancel());
    unawaited(_notificationActionSubscription?.cancel());
    _actionRuntimeGate.unregister(_notificationActions);
    _notificationActions.dispose();
    _notifications.detachNotificationActionReceiver();
    _notificationRoutes.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      unawaited(DesktopWindowService.flush(DatabaseHelper.instance));
    }
    super.dispose();
  }

  // --- WindowListener Methods ---
  @override
  void onWindowClose() async {
    if (!_isDesktop) return;
    if (ref.read(recoveryCoordinatorProvider).state.working) return;
    try {
      await DesktopWindowService.flush(DatabaseHelper.instance);
      // Hide window instead of closing
      bool isPreventClose = await windowManager.isPreventClose();
      if (isPreventClose) {
        windowManager.hide();
      }
    } catch (_) {}
  }

  @override
  void onWindowMoved() {
    if (!_isDesktop) return;
    _handleWindowBoundsChanged();
  }

  @override
  void onWindowResized() {
    if (!_isDesktop) return;
    _handleWindowBoundsChanged();
  }

  @override
  void onWindowMaximize() {
    if (!_isDesktop) return;
    _handleWindowMaximizeChanged(true);
  }

  @override
  void onWindowUnmaximize() {
    if (!_isDesktop) return;
    _handleWindowMaximizeChanged(false);
  }

  void _handleWindowBoundsChanged() {
    try {
      windowManager
          .isMaximized()
          .then((isMax) {
            if (!isMax) {
              windowManager
                  .getBounds()
                  .then((bounds) {
                    DesktopWindowService.recordBoundsChanged(
                      dbHelper: DatabaseHelper.instance,
                      bounds: bounds,
                    );
                  })
                  .catchError((Object _) {});
            }
          })
          .catchError((Object _) {});
    } catch (_) {}
  }

  void _handleWindowMaximizeChanged(bool isMaximized) {
    try {
      DesktopWindowService.recordMaximizeChanged(
        dbHelper: DatabaseHelper.instance,
        isMaximized: isMaximized,
      );
    } catch (_) {}
  }

  // --- TrayListener Methods ---
  @override
  void onTrayIconMouseDown() {
    if (!_isDesktop) return;
    try {
      // Bring to front on single click
      windowManager.show();
      windowManager.focus();
    } catch (_) {}
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!_isDesktop) return;
    try {
      trayManager.popUpContextMenu();
    } catch (_) {}
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (!_isDesktop) return;
    try {
      if (menuItem.key == 'show_window') {
        windowManager.show();
        windowManager.focus();
      } else if (menuItem.key == 'exit_app') {
        if (ref.read(recoveryCoordinatorProvider).state.working) {
          windowManager.show();
          windowManager.focus();
          return;
        }
        try {
          trayManager.destroy();
        } catch (_) {}
        unawaited(_closeStorageAndExit());
      }
    } catch (_) {}
  }

  /// The tray exit is the normal desktop shutdown path. Closing the database
  /// first flushes the mirror backup and the notification journal, so a tray
  /// exit cannot leave a half-written store behind (the previous `exit(0)`
  /// skipped this).
  Future<void> _closeStorageAndExit() => shutdownDesktopApp(
    saveState: () => DesktopWindowService.flush(DatabaseHelper.instance),
    closeStorage: () => DatabaseHelper.instance.close(),
    destroyWindow: () => windowManager.destroy(),
    exitProcess: exit,
    onError: (error, _) => debugPrint('Shutdown step failed: $error'),
  );

  @override
  Future<bool> didPopRoute() async =>
      ref.read(recoveryCoordinatorProvider).state.phase != RecoveryPhase.idle;

  @override
  Widget build(BuildContext context) {
    ref.listen(
      workspaceDraftsProvider.select(SharedTextInbox.count),
      (_, _) => _scheduleSharedTexts(),
    );
    final settings = ref.watch(settingsProvider);
    ref.listen(settingsProvider.select((settings) => settings.language), (
      _,
      _,
    ) {
      unawaited(_syncNotificationLanguage());
    });
    if (_supportsLiveActivities) {
      ref.listen(remindersProvider, (_, _) => _syncLiveReminder());
      ref.listen(
        settingsProvider.select((settings) => settings.language),
        (_, _) => _syncLiveReminder(),
      );
    }
    _syncMacMenu();
    final recovery = ref.watch(recoveryCoordinatorProvider);
    final recoveryState = recovery.state;

    return MaterialApp(
      // Discard old editors, pending Undo, draft settings and navigation state
      // only after the data decision and provider reload have completed.
      key: ValueKey(recovery.navigationEpoch),
      navigatorKey: _navigatorKey,
      title: "DontForget",
      debugShowCheckedModeBanner: false,
      locale: Locale(settings.language),
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', ''),
        Locale('zh', ''),
        Locale('ja', ''),
      ],
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: AppTheme.mode(settings.appearance),
      builder: (context, child) {
        // MaterialApp can finish replacing its Navigator a frame after the
        // provider future becomes ready. Retry from this subtree's build so a
        // queued click is not stranded by an earlier null currentState check.
        _scheduleNotificationRoutes();
        _scheduleLiveRoute();
        if (_sharedInboxWanted && !_sharedInboxFramePending) {
          _sharedInboxFramePending = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _sharedInboxFramePending = false;
            if (mounted && _sharedInboxWanted) _openSharedInbox();
          });
        }
        return InlineFeedback(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeSemantics(
                excluding: recoveryState.working,
                child: ExcludeFocus(
                  excluding: recoveryState.working,
                  child: IgnorePointer(
                    ignoring: recoveryState.working,
                    child: child!,
                  ),
                ),
              ),
              if (recoveryState.working)
                RecoveryOutcomeScreen(
                  phase: recoveryState.phase,
                  rollbackDirectory: null,
                  onContinue: () {},
                  onExit: () {},
                ),
            ],
          ),
        );
      },
      home: recoveryState.terminal
          ? RecoveryOutcomeScreen(
              phase: recoveryState.phase,
              rollbackDirectory: recoveryState.rollbackDirectory,
              onContinue: recovery.acknowledge,
              onExit: () => exit(1),
            )
          : const HomeScreen(),
    );
  }
}
