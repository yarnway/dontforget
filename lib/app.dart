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
import 'services/live_reminder_service.dart';
import 'models/notification_payload.dart';
import 'services/notification_service.dart';
import 'services/startup_trace.dart';
import 'services/mac_menu_commands.dart';
import 'services/recovery/runtime_gate.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/recovery_outcome_screen.dart';
import 'ui/screens/task_detail_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'l10n/app_localizations.dart';

typedef _MacInputToken = ({DataGeneration data, RuntimeRecoveryToken runtime});

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  late final NotificationService _notifications;
  late final RecoveryCoordinator _recovery;
  late final NotificationRouteService _notificationRoutes;
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
  String? _pendingLivePayload;
  String? _openLiveIdentity;
  bool _liveFramePending = false;

  bool get _supportsLiveActivities =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _notifications = ref.read(notificationServiceProvider);
    _recovery = ref.read(recoveryCoordinatorProvider);
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
      _syncLiveReminder();
      _syncMacMenu();
      StartupTrace.mark('notifications_ready');
      _scheduleNotificationRoutes();
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
      unawaited(
        navigator
            .push<void>(
              MaterialPageRoute<void>(
                settings: RouteSettings(name: '/live-reminder/${target.id}'),
                builder: (_) => TaskDetailScreen(task: target),
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
    if (state == AppLifecycleState.resumed) _syncLiveReminder();
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
      builder: (_) => const SettingsScreen(),
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
        StartupTrace.mark('routes_ready_frame');
      } catch (error) {
        debugPrint('Notification navigation unavailable: $error');
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool _openNotificationReminder(Reminder reminder) {
    final navigator = _navigatorKey.currentState;
    if (!mounted ||
        navigator == null ||
        _recovery.state.phase != RecoveryPhase.idle) {
      return false;
    }
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: '/notification/${reminder.id}'),
          builder: (_) => TaskDetailScreen(task: reminder),
        ),
      ),
    );
    if (_isDesktop) unawaited(_showNotificationWindow());
    return true;
  }

  Future<void> _showNotificationWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // Desktop activation can be unavailable while the Flutter route remains
      // usable (including widget tests and a host without a window manager).
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
      Menu menu = Menu(
        items: [
          MenuItem(key: 'show_window', label: '显示应用'),
          MenuItem.separator(),
          MenuItem(key: 'exit_app', label: '退出'),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (e) {
      debugPrint('Tray initialization error: $e');
    }
  }

  @override
  void dispose() {
    _macMenu?.dispose();
    if (_supportsLiveActivities) {
      ChannelLiveReminderBackend.channel.setMethodCallHandler(null);
    }
    _routeInitialization++;
    _recovery.removeListener(_onRecoveryChanged);
    unawaited(_notificationSubscription?.cancel());
    _notificationRoutes.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  // --- WindowListener Methods ---
  @override
  void onWindowClose() async {
    if (!_isDesktop) return;
    if (ref.read(recoveryCoordinatorProvider).state.working) return;
    try {
      // Hide window instead of closing
      bool isPreventClose = await windowManager.isPreventClose();
      if (isPreventClose) {
        windowManager.hide();
      }
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
        try {
          windowManager.destroy();
        } catch (_) {}
        exit(0);
      }
    } catch (_) {}
  }

  @override
  Future<bool> didPopRoute() async =>
      ref.read(recoveryCoordinatorProvider).state.phase != RecoveryPhase.idle;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
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
