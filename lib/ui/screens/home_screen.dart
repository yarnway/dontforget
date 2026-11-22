import '../widgets/reminder_notice_panel.dart';
import '../../data/database_helper.dart';
import '../widgets/inline_feedback.dart';
import '../formatters/local_date_time.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../providers/global_capture_provider.dart';
import '../../providers/home_controller.dart';
import '../../services/notification_service.dart';
import '../../services/notification_permission_service.dart';
import '../../services/notification_retry_coordinator.dart';
import '../../services/time_zone_change_coordinator.dart';
import '../../services/startup_trace.dart';
import '../../services/local_media_store.dart';
import '../../services/recovery/runtime_gate.dart';
import '../../services/shared_text_inbox.dart';
import 'preferences_screen.dart';
import 'dashboard_screen.dart';
import 'shared_text_inbox_screen.dart';
import '../../l10n/shared_text_strings.dart';
import '../widgets/task_search_panel.dart';
import '../widgets/input_bottom_bar.dart';
import '../widgets/command_palette_dialog.dart';
import '../widgets/spaced_repetition_sheet.dart';
import '../widgets/focus_mode_sheet.dart';
import '../widgets/context_digest_sheet.dart';
import '../widgets/missed_reminders_bar.dart';
import '../widgets/task_workspace_overview.dart';
import '../widgets/learning_queue_panel.dart';
import '../widgets/planning_panel.dart';
import '../../l10n/planning_strings.dart';
import 'notification_repair_screen.dart';
import '../../providers/workspace_drafts_provider.dart';
import '../widgets/data_export_sheet.dart';
import '../widgets/workspace_tool_panel.dart';
import '../widgets/agent_goal_panel.dart';
import '../widgets/study_plan_panel.dart';
import '../../services/context_trigger_service.dart';
import '../../services/spaced_repetition_service.dart';
import 'knowledge_graph_screen.dart';
import 'task_detail_screen.dart';
import '../../l10n/app_localizations.dart';

enum _NoticeActionKind { dismiss, snooze, complete, skip }

enum _WorkspaceTool {
  focus,
  export,
  review,
  digest,
  graph,
  dashboard,
  agent,
  study,
  learning,
  planning,
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  AudioPlayer? _audioPlayer;
  final _mediaStore = LocalMediaStore();

  AudioPlayer _ensureAudioPlayer() {
    final existing = _audioPlayer;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _playerCompleteSubscription = player.onPlayerComplete.listen((_) {
      _playbackStarted = false;
      _playingRecordId = null;
    });
    return _audioPlayer = player;
  }
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken? _birth;
  late final NotificationService _notifications;
  late final ContextTriggerService _contextTriggers;
  WorkspaceDrafts? _workspaceDrafts;
  Future<void> _playbackOperations = Future<void>.value();
  bool _playbackStarted = false;
  String? _playingRecordId;
  StreamSubscription<void>? _playerCompleteSubscription;

  bool get _runtimeActive => mounted && _runtime.isCurrent(_birth);

  Future<void> _serializePlayback(Future<void> Function() operation) {
    final result = _playbackOperations.then((_) => operation());
    _playbackOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _quiesce() async {
    final command = ref.read(workspaceToolsCommandProvider);
    if (identical(command.open, _nativeToolsHandler)) command.open = null;
    if (identical(command.search, _nativeSearchHandler)) command.search = null;
    if (identical(command.playMedia, _nativeMediaHandler)) {
      command.playMedia = null;
    }
    _heartbeatTimer?.cancel();
    _searchDebounce?.cancel();
    _studyDraft.request?.cancel('Workspace paused for recovery');
    await Future.wait([
      if (_timeZoneChanges != null) _timeZoneChanges!.stop(),
      if (_notificationRetries != null) _notificationRetries!.stop(),
      if (_departureMaintenance != null) _departureMaintenance!.stop(),
      if (_dueSubscription != null) _dueSubscription!.cancel(),
      if (_catchUpDigestSubscription != null)
        _catchUpDigestSubscription!.cancel(),
      if (_suppressedSubscription != null) _suppressedSubscription!.cancel(),
      if (_playerCompleteSubscription != null)
        _playerCompleteSubscription!.cancel(),
      _serializePlayback(() async {
        if (_playbackStarted) {
          await _audioPlayer?.stop();
          _playbackStarted = false;
          _playingRecordId = null;
        }
      }),
    ]);
    _promptedReminderIds.clear();
    _dueNoticeKeys.clear();
    _dueNoticesVersion++;
    _cachedNoticeSnapshot = null;
    _noticeOperations.value = const {};
    _acknowledgingMissed.value = false;
    _contextDigest = [];
  }

  Timer? _heartbeatTimer;
  NotificationRetryCoordinator? _notificationRetries;
  NotificationRetryCoordinator? _departureMaintenance;
  TimeZoneChangeCoordinator? _timeZoneChanges;
  StreamSubscription<Reminder>? _dueSubscription;
  StreamSubscription<List<Reminder>>? _catchUpDigestSubscription;
  StreamSubscription<List<Reminder>>? _suppressedSubscription;
  final Set<String> _promptedReminderIds = {};
  final Set<String> _dueNoticeKeys = {};
  int _dueNoticesVersion = 0;
  final ValueNotifier<Set<String>> _noticeOperations = ValueNotifier(const {});
  final ValueNotifier<bool> _acknowledgingMissed = ValueNotifier(false);
  String? _workspaceView;
  late final DateTime _launchTime = DateTime.now();
  List<Reminder> _contextDigest = [];
  final _shortcutFocus = FocusNode(
    debugLabel: 'workspace-shortcuts',
    skipTraversal: true,
  );
  WorkspaceToolsCommand? _toolsCommand;
  late final bool Function() _nativeToolsHandler = _openNativeTools;
  late final bool Function() _nativeSearchHandler = _openNativeSearch;
  late final void Function(String) _nativeMediaHandler = _playMedia;
  bool _openNativeTools() => !_hasComposingText && _openCommandPalette();
  bool _openNativeSearch() => !_hasComposingText && _openSearch();

  bool get _hasComposingText {
    final context = FocusManager.instance.primaryFocus?.context;
    final editable = context?.widget is EditableText
        ? context!.widget as EditableText
        : context?.findAncestorWidgetOfExactType<EditableText>();
    final composing = editable?.controller.value.composing;
    return composing != null && composing.isValid && !composing.isCollapsed;
  }

  _WorkspaceTool? _activeTool;
  bool _exportBusy = false;
  bool _toolBusy = false;
  bool _agentBusy = false;
  bool _discardDialogOpen = false;
  final _agentGoal = TextEditingController();
  final _studyDraft = StudyPlanDraft();
  bool _restoringTools = false, _toolsEdited = false;

  Future<void> _restoreWorkspaceDrafts() async {
    try {
      final store = ref.read(workspaceDraftsProvider.notifier);
      if (!store.loaded) await store.ready;
      if (!_runtimeActive || _toolsEdited) return;
      _restoringTools = true;
      final drafts = ref.read(workspaceDraftsProvider);
      if (drafts['goal'] is String) _agentGoal.text = drafts['goal'] as String;
      if (drafts['study'] is Map) {
        _studyDraft.restore(
          drafts['study'] as Map,
          ref.read(databaseHelperProvider).captureGeneration(),
        );
      }
    } catch (_) {
      if (mounted && _runtimeActive) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).get('draftSaveFailed')),
          ),
        );
      }
    } finally {
      _restoringTools = false;
    }
  }

  void _persistAgentGoalDraft() => _persistWorkspaceDraftKey(
    'goal',
    _agentGoal.text.isEmpty ? null : _agentGoal.text,
  );

  void _persistStudyDraft() =>
      _persistWorkspaceDraftKey('study', _studyDraft.toJson());

  void _persistWorkspaceDraftKey(String key, Object? value) {
    if (_restoringTools || !_runtimeActive) return;
    _toolsEdited = true;
    final store = ref.read(workspaceDraftsProvider.notifier);
    unawaited(
      store
          .putDebounced(key, value)
          .then<void>(
            (_) {},
            onError: (Object _) {
              if (mounted && _runtimeActive) {
                InlineFeedback.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      AppLocalizations.of(context).get('draftSaveFailed'),
                    ),
                  ),
                );
              }
            },
          ),
    );
  }

  bool get _toolBlocked => _exportBusy || _toolBusy;

  bool _isSearchOpen = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'task-search');
  String _searchQuery = '';
  Timer? _searchDebounce;
  final _noticeClock = ValueNotifier(DateTime.now());
  final _reviewQueue = ReviewQueueCache();
  String? _preferredReviewId;

  @override
  void initState() {
    super.initState();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.paused ? null : _runtime.capture();
    _notifications = ref.read(notificationServiceProvider);
    _contextTriggers = ref.read(contextTriggerServiceProvider);
    if (_birth == null) return;
    _workspaceDrafts = ref.read(workspaceDraftsProvider.notifier);
    _agentGoal.addListener(_persistAgentGoalDraft);
    _studyDraft.addListener(_persistStudyDraft);
    unawaited(_restoreWorkspaceDrafts());
    _toolsCommand = ref.read(workspaceToolsCommandProvider);
    _toolsCommand!.open = _nativeToolsHandler;
    _toolsCommand!.search = _nativeSearchHandler;
    _toolsCommand!.playMedia = _nativeMediaHandler;
    _runtime.register(this, _quiesce);
    WidgetsBinding.instance.addObserver(this);

    // Listen to notification service broadcast stream
    _dueSubscription = _notifications.onReminderDue.listen((reminder) {
      _queueDueReminder(reminder);
    });

    // 聚合情境摘要为页面入口，由用户选择何时查看。
    _catchUpDigestSubscription = _contextTriggers.onCatchUpDigestReady.listen((
      digestList,
    ) {
      if (!mounted || !_runtimeActive || digestList.isEmpty) return;
      setState(
        () => _contextDigest = {
          for (final r in _contextDigest) r.id: r,
          for (final r in digestList) r.id: r,
        }.values.toList(),
      );
    });

    // 监听拦截队列更新以便即时刷新情境徽标
    _suppressedSubscription = _contextTriggers.onSuppressedUpdated.listen((_) {
      if (mounted && _runtimeActive) setState(() {});
    });

    // 启动时仅在存在未触发的 Wi-Fi 情境触发器时执行嗅探，避免空闲时拉起系统网络进程
    if (_contextTriggers.hasPendingWifiTrigger(ref.read(remindersProvider))) {
      unawaited(_contextTriggers.detectCurrentWifiSsid());
    }

    _departureMaintenance = NotificationRetryCoordinator(
      run: (isActive) async {
        bool active() => _runtimeActive && isActive();
        if (!active()) return;
        final notifier = ref.read(remindersProvider.notifier);
        await notifier.refreshOrdinarySchedules();
        if (!active()) return;
        final hasDepartures = ref
            .read(remindersProvider)
            .any((r) => r.details.kind == 'departure');
        if (!hasDepartures) return;
        await notifier.refreshDepartureSchedules();
        if (!active()) return;
        await notifier.refreshDepartureWeather(
          ref.read(departureWeatherProvider),
          isActive: active,
          isBackground: () =>
              WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed,
        );
      },
    )..setForeground(true);

    _notificationRetries = NotificationRetryCoordinator(
      run: (isActive) async {
        if (!_runtimeActive || !isActive()) return;
        // This is a read-only query: a late answer can be discarded safely.
        // Do not let a stuck platform read hold up runtime recovery draining.
        final permission = await NotificationPermissionService()
            .refresh()
            .timeout(const Duration(seconds: 5));
        if (!_runtimeActive ||
            !isActive() ||
            !permission.canRequestNotifications) {
          return;
        }
        final allowed =
            permission.authorization.status ==
                NotificationPermissionStatus.granted ||
            permission.authorization.status ==
                NotificationPermissionStatus.provisional;
        final exactAllowed =
            !permission.supportsExactAlarms ||
            permission.exactAlarms == NotificationPermissionStatus.granted;
        if (StartupTrace.retryEnabled) {
          StartupTrace.notificationEvent('foreground_retry_started', {
            'authorization': permission.authorization.status.name,
            'can_schedule': allowed && exactAllowed,
          });
        }
        final result = await ref
            .read(remindersProvider.notifier)
            .retryFailedNotificationDelivery(
              canSchedule: allowed && exactAllowed,
              isActive: () => _runtimeActive && isActive(),
            );
        if (StartupTrace.retryEnabled) {
          final snapshot = await ref
              .read(databaseHelperProvider)
              .withNotificationJournal((journal) => journal.read());
          StartupTrace.notificationEvent('foreground_retry_completed', {
            'attempted': result.attempted,
            'failed': result.failed,
            'entries_total': snapshot?.entries.length,
            'entries': snapshot?.entries.values
                .take(16)
                .map((e) => e.toJson())
                .toList(),
          });
        }
      },
    );
    _notificationRetries!.setForeground(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );

    _timeZoneChanges = TimeZoneChangeCoordinator(
      reload: () async {
        if (!_runtimeActive) throw StateError('Runtime is no longer active.');
        await ref.read(remindersProvider.notifier).refreshForTimeZoneChange();
        if (!_runtimeActive) return;
        final currentKeys = ref
            .read(remindersProvider)
            .map(reminderOccurrenceKey)
            .toSet();
        setState(() {
          _promptedReminderIds.retainAll(currentKeys);
          _dueNoticeKeys.retainAll(currentKeys);
          _dueNoticesVersion++;
          _contextDigest = [];
        });
        StartupTrace.notificationEvent('time_zone_reconciled', {});
      },
    );
    unawaited(_timeZoneChanges!.tick());

    // Refresh app-visible reminders and retry a bounded batch while foreground.
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_refreshClockAndReminders());
    });
  }

  @override
  void dispose() {
    if (identical(_toolsCommand?.open, _nativeToolsHandler)) {
      _toolsCommand?.open = null;
    }
    if (identical(_toolsCommand?.search, _nativeSearchHandler)) {
      _toolsCommand?.search = null;
    }
    if (identical(_toolsCommand?.playMedia, _nativeMediaHandler)) {
      _toolsCommand?.playMedia = null;
    }
    _runtime.unregister(this);
    _workspaceDrafts?.flushPending();
    WidgetsBinding.instance.removeObserver(this);
    _agentGoal.dispose();
    _studyDraft.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _searchDebounce?.cancel();
    _noticeClock.dispose();
    _noticeOperations.dispose();
    _acknowledgingMissed.dispose();
    _shortcutFocus.dispose();
    _heartbeatTimer?.cancel();
    unawaited(_timeZoneChanges?.stop());
    unawaited(_notificationRetries?.stop());
    unawaited(_departureMaintenance?.stop());
    _dueSubscription?.cancel();
    _catchUpDigestSubscription?.cancel();
    _suppressedSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _playingRecordId = null;
    final player = _audioPlayer;
    if (player != null) {
      unawaited(
        _serializePlayback(() => player.dispose()).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notificationRetries?.setForeground(state == AppLifecycleState.resumed);
    final backgroundAllowed = ref
        .read(remindersProvider)
        .any(
          (r) =>
              r.details.kind == 'departure' &&
              r.details.planId == null &&
              r.isVisible &&
              !r.details.paused &&
              r.details.data['weather_background'] == true &&
              r.details.data['weather_enabled'] == true,
        );
    _departureMaintenance?.setForeground(
      state == AppLifecycleState.resumed || backgroundAllowed,
    );
    if (state == AppLifecycleState.resumed && _runtimeActive) {
      // Desktop/mobile timers can pause while hidden or asleep. Reconcile from
      // current task state instead of waiting for another timer/broadcast.
      unawaited(_refreshClockAndReminders());
    }
  }

  Future<void> _refreshClockAndReminders() async {
    if (!_runtimeActive) return;
    await _timeZoneChanges?.tick();
    if (!_runtimeActive) return;
    _checkDueReminders();
    unawaited(_notificationRetries?.tick());
    unawaited(_departureMaintenance?.tick());
    _noticeClock.value = DateTime.now();
  }

  static bool _needsDynamicUrgencyPromotion(
    List<Reminder> reminders,
    DateTime now,
  ) {
    const threshold = Duration(hours: 24);
    for (final reminder in reminders) {
      if (reminder.quadrantLevel != 2 ||
          !reminder.canNotify ||
          reminder.spacedRepetitionLevel > 0 ||
          reminder.noticeAcknowledgedAt != null ||
          reminder.triggerTime == null) {
        continue;
      }
      final diff = reminder.triggerTime!.difference(now);
      if (diff.inSeconds > 0 && diff <= threshold) return true;
    }
    return false;
  }

  void _checkDueReminders() {
    if (!mounted || !_runtimeActive) return;
    final database = ref.read(databaseHelperProvider);
    final DataGeneration generation;
    try {
      generation = database.captureGeneration();
    } on DatabaseAccessException {
      return;
    }
    final reminders = ref.read(remindersProvider);
    final now = DateTime.now();

    for (final r in reminders) {
      if (r.canNotify &&
          r.triggerTime != null &&
          r.noticeAcknowledgedAt == null) {
        // Reminders already overdue before app launch are aggregated into "missed reminders"
        // without firing noisy individual toasts on startup.
        if (r.triggerTime!.isBefore(_launchTime)) {
          continue;
        }
        // If due and within the last 15 minutes and not yet prompted
        if (r.triggerTime!.isBefore(now) &&
            r.triggerTime!.isAfter(now.subtract(const Duration(minutes: 15))) &&
            !_promptedReminderIds.contains(reminderOccurrenceKey(r))) {
          _promptedReminderIds.add(reminderOccurrenceKey(r));
          unawaited(
            database
                .runOperation(generation, () async {
                  await ref
                      .read(notificationServiceProvider)
                      .fireReminderNow(r);
                })
                .catchError((Object _) {}),
          );
        }
      }
    }

    // 情境感知触发器检测：仅当存在未暂停且本轮未触发的 Wi-Fi 触发器时才执行嗅探
    if (_contextTriggers.hasPendingWifiTrigger(reminders)) {
      final wifiToastTemplate = AppLocalizations.of(
        context,
      ).get('contextWifiConnectedToast');
      _contextTriggers
          .detectCurrentWifiSsid()
          .then((ssid) {
            if (ssid != null &&
                mounted &&
                _runtimeActive &&
                database.isCurrent(generation)) {
              // Re-read current reminders after async SSID probe so completed
              // or deleted tasks never trigger a stale toast.
              final latestReminders = ref.read(remindersProvider);
              final matched = _contextTriggers.evaluateContextTriggers(
                latestReminders,
                ssid: ssid,
              );
              for (final m in matched) {
                unawaited(
                  database
                      .runOperation(generation, () async {
                        await ref
                            .read(notificationServiceProvider)
                            .showWindowsToast(
                              wifiToastTemplate.replaceAll('{ssid}', ssid),
                              m.taskTitle,
                            );
                      })
                      .catchError((Object _) {}),
                );
              }
            }
          })
          .catchError((Object _) {});
    }

    // 动态跃迁周期扫描：仅当存在满足 24h 阈值的 Q2 事项时才发起写入扫描
    if (_needsDynamicUrgencyPromotion(reminders, now)) {
      ref
          .read(remindersProvider.notifier)
          .scanAndApplyDynamicUrgency()
          .then((result) {
            if (mounted && _runtimeActive && result.nativeSyncFailures > 0) {
              InlineFeedback.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    AppLocalizations.of(context).get('reminderNativeSyncFailed'),
                  ),
                ),
              );
            }
          })
          .catchError((Object _) {
            // The next heartbeat can retry. Failed persistence must not become an
            // unhandled asynchronous error or interrupt foreground due notices.
          });
    }
  }

  void _queueDueReminder(Reminder reminder) {
    if (!mounted || !_runtimeActive) return;
    final key = reminderOccurrenceKey(reminder);
    final current = ref
        .read(remindersProvider)
        .where(
          (r) =>
              r.id == reminder.id &&
              !r.isCompleted &&
              r.noticeAcknowledgedAt == null &&
              reminderOccurrenceKey(r) == key,
        );
    if (current.isEmpty) return;
    _promptedReminderIds.add(key);
    if (_dueNoticeKeys.add(key)) {
      _dueNoticesVersion++;
      _noticeClock.value = DateTime.now();
    }
  }

  List<Reminder> _visibleNotices(List<Reminder> reminders, DateTime now) {
    final activeKeys = _dueNoticeKeys.isEmpty ? null : <String>{};
    final visible = <Reminder>[];
    for (final r in reminders) {
      if (!r.canNotify ||
          r.triggerTime == null ||
          _notifications.isSuppressed(r)) {
        continue;
      }
      final key = reminderOccurrenceKey(r);
      final upcoming = r.triggerTime!.isAfter(now);
      if (r.noticeAcknowledgedAt != null ||
          (upcoming && r.upcomingDismissedAt != null)) {
        continue;
      }
      activeKeys?.add(key);
      final show = upcoming
          ? r.triggerTime!.difference(now) <= const Duration(minutes: 5)
          : _dueNoticeKeys.contains(key) ||
                now.difference(r.triggerTime!) <= const Duration(minutes: 15);
      if (show) visible.add(r);
    }
    if (activeKeys != null) {
      _dueNoticeKeys.retainAll(activeKeys);
    }
    visible.sort((a, b) => a.triggerTime!.compareTo(b.triggerTime!));
    return visible;
  }

  List<Reminder>? _cachedNoticeReminders;
  DateTime? _cachedNoticeTick;
  int _cachedNoticeDueVersion = -1;
  ({List<Reminder> visible, List<Reminder> missed, DateTime now})?
  _cachedNoticeSnapshot;

  ({List<Reminder> visible, List<Reminder> missed, DateTime now})
  _noticeSnapshot(List<Reminder> reminders, DateTime tick) {
    final previous = _cachedNoticeSnapshot;
    if (identical(_cachedNoticeReminders, reminders) &&
        _cachedNoticeTick == tick &&
        _cachedNoticeDueVersion == _dueNoticesVersion &&
        previous != null) {
      return previous;
    }
    final now = DateTime.now();
    final computedVisible = _visibleNotices(reminders, now);
    final computedMissed = selectMissedReminders(
      reminders,
      now,
      visibleNoticeOccurrences: computedVisible.map(reminderOccurrenceKey),
    );
    // Preserve previous List instances when membership is unchanged so
    // downstream identical() caches in TaskWorkspaceOverview stay warm.
    final visible = previous != null && listEquals(previous.visible, computedVisible)
        ? previous.visible
        : computedVisible;
    final missed = previous != null && listEquals(previous.missed, computedMissed)
        ? previous.missed
        : computedMissed;
    _cachedNoticeReminders = reminders;
    _cachedNoticeTick = tick;
    _cachedNoticeDueVersion = _dueNoticesVersion;
    return _cachedNoticeSnapshot = (visible: visible, missed: missed, now: now);
  }

  void _openMissedFilter() {
    setState(() => _workspaceView = 'missed');
  }

  void _switchWorkspaceView(String view) {
    setState(() => _workspaceView = view);
    unawaited(
      ref
          .read(workspaceDraftsProvider.notifier)
          .put('homeView', view)
          .catchError((Object _) {}),
    );
  }

  Widget _buildWorkspaceOverview(List<Reminder> reminders) {
    List<Reminder>? previousMissed;
    TaskWorkspaceOverview? overview;
    return ValueListenableBuilder<DateTime>(
      valueListenable: _noticeClock,
      builder: (context, tick, _) {
        final missed = _noticeSnapshot(reminders, tick).missed;
        // Keep the board intact on idle heartbeats; rebuild only when this
        // clock actually changes missed-list membership. Task edits rebuild
        // Home and create a fresh builder with the current task data.
        if (overview == null || !listEquals(previousMissed, missed)) {
          previousMissed = missed;
          overview = TaskWorkspaceOverview(
            reminders: reminders,
            missedReminders: missed,
            activeView: _workspaceView,
            onViewChanged: (view) => _workspaceView = view,
            onPlayMedia: _playMedia,
            onOpenLearning: () => _selectTool(_WorkspaceTool.learning),
          );
        }
        return overview!;
      },
    );
  }

  Future<void> _acknowledgeAllMissed(List<Reminder> missed) async {
    if (missed.isEmpty || !_runtimeActive || _acknowledgingMissed.value) return;
    _acknowledgingMissed.value = true;
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    try {
      final results = await ref
          .read(remindersProvider.notifier)
          .acknowledgeOccurrences(missed, now: now);
      if (mounted && _runtimeActive) {
        if (_workspaceView == 'missed') {
          setState(() => _workspaceView = 'today');
        }
        if (results.any((r) => r.nativeSyncFailed)) {
          InlineFeedback.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.get('reminderNativeSyncFailed')),
              action: notificationRepairAction(context),
            ),
            tone: FeedbackTone.warning,
          );
        }
      }
    } catch (_) {
      if (mounted && _runtimeActive) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
          tone: FeedbackTone.error,
        );
      }
    } finally {
      _acknowledgingMissed.value = false;
    }
  }

  Future<void> _dismissNotice(Reminder reminder, {bool? upcoming}) async {
    final now = DateTime.now();
    final isUpcoming = upcoming ?? (reminder.triggerTime?.isAfter(now) ?? false);
    await _performNoticeAction(
      reminder,
      () => ref
          .read(remindersProvider.notifier)
          .acknowledgeOccurrence(
            reminder,
            phase: isUpcoming
                ? ReminderNoticePhase.upcoming
                : ReminderNoticePhase.due,
            now: now,
          ),
      kind: _NoticeActionKind.dismiss,
    );
  }

  Future<void> _actOnNotice(Reminder reminder, {required bool snooze}) async {
    await _performNoticeAction(
      reminder,
      () => snooze
          ? ref.read(remindersProvider.notifier).snoozeOccurrence(reminder)
          : ref.read(remindersProvider.notifier).completeOccurrence(reminder),
      kind: snooze ? _NoticeActionKind.snooze : _NoticeActionKind.complete,
    );
  }

  Future<void> _performNoticeAction(
    Reminder reminder,
    Future<ReminderActionResult> Function() action, {
    required _NoticeActionKind kind,
  }) async {
    if (!_runtimeActive || _noticeOperations.value.contains(reminder.id)) return;
    _noticeOperations.value = {..._noticeOperations.value, reminder.id};
    final l10n = AppLocalizations.of(context);
    try {
      final result = await action();
      if (!mounted || !_runtimeActive) return;
      if (result.disposition == ReminderActionDisposition.stale) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('reminderOccurrenceChanged'))),
          tone: FeedbackTone.warning,
        );
        return;
      }
      if (_dueNoticeKeys.remove(reminderOccurrenceKey(reminder))) {
        _dueNoticesVersion++;
        _noticeClock.value = DateTime.now();
      }
      String? message;
      FeedbackTone tone = FeedbackTone.info;
      SnackBarAction? snackAction;
      final saved = result.reminder;
      if (result.nativeSyncFailed) {
        message = l10n.get('reminderNativeSyncFailed');
        tone = FeedbackTone.warning;
        snackAction = notificationRepairAction(context);
      } else {
        switch (kind) {
          case _NoticeActionKind.dismiss:
            break;
          case _NoticeActionKind.snooze:
            message =
                '${l10n.get('reminderDelayedTo')} ${saved?.triggerTime == null ? '' : formatLocalDateTime(saved!.triggerTime!)}';
            tone = FeedbackTone.success;
          case _NoticeActionKind.skip:
            message = saved != null && !saved.isCompleted && saved.triggerTime != null
                ? '${planningText(context, 'skipped')} · ${formatLocalDateTime(saved.triggerTime!)}'
                : planningText(context, 'skipped');
            tone = FeedbackTone.info;
          case _NoticeActionKind.complete:
            if (saved != null && !saved.isCompleted && saved.triggerTime != null) {
              message =
                  '${l10n.get('periodicNext')}${formatLocalDateTime(saved.triggerTime!)}';
            } else {
              message = l10n.get('taskCompleted');
              if (saved != null && saved.isCompleted) {
                final completedRow = saved;
                snackAction = SnackBarAction(
                  label: l10n.get('undo'),
                  onPressed: () {
                    if (!mounted || !_runtimeActive) return;
                    unawaited(
                      ref
                          .read(remindersProvider.notifier)
                          .updateReminder(
                            completedRow.copyWith(isCompleted: false),
                            baseline: completedRow,
                          )
                          .catchError((Object _) => const ReminderActionResult(
                            ReminderActionDisposition.stale,
                          )),
                    );
                  },
                );
              }
            }
            tone = FeedbackTone.success;
        }
      }
      if (message != null) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(message), action: snackAction),
          tone: tone,
        );
      }
    } catch (_) {
      if (mounted && _runtimeActive) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
          tone: FeedbackTone.error,
        );
      }
    } finally {
      final updated = Set<String>.of(_noticeOperations.value)..remove(reminder.id);
      _noticeOperations.value = updated;
    }
  }

  void _confirmClearCompleted() {
    if (!mounted || !_runtimeActive) return;
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final completedCount = ref
        .read(remindersProvider)
        .where(
          (r) => r.isCompleted && r.details.data['learning_archive'] != true,
        )
        .length;
    if (completedCount == 0) {
      InlineFeedback.of(context).hideCurrentSnackBar();
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          content: Text(l10n.get('noCompletedToClear')),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.cleaning_services_outlined,
              color: colors.error,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.get('clearCompletedTitle'),
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Text(
          '${l10n.get('clearCompletedConfirm')} ($completedCount)',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              l10n.get('cancel'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            onPressed: () async {
              if (!mounted || !_runtimeActive) return;
              Navigator.of(ctx).pop();
              try {
                final database = ref.read(databaseHelperProvider);
                final generation = database.captureGeneration();
                final result = await database.runOperation(
                  generation,
                  () async {
                    return ref
                        .read(remindersProvider.notifier)
                        .clearCompletedReminders();
                  },
                );
                database.checkGeneration(generation);
                if (mounted && _runtimeActive) {
                  InlineFeedback.of(context).hideCurrentSnackBar();
                  InlineFeedback.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(seconds: 3),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      content: Text(
                        result.nativeSyncFailures > 0
                            ? l10n.get('reminderNativeDeleteFailed')
                            : '${l10n.get('clearedCompletedSuccess')} (${result.changed})',
                      ),
                    ),
                  );
                }
              } catch (_) {
                if (mounted && _runtimeActive) {
                  InlineFeedback.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.get('taskDeleteFailed'))),
                  );
                }
              }
            },
            child: Text(
              l10n.get('confirm'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _clearAllNotices() async {
    if (!_runtimeActive || _noticeOperations.value.isNotEmpty) return;
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final visible = _visibleNotices(ref.read(remindersProvider), now);
    if (visible.isEmpty) {
      ref.read(homeControllerProvider.notifier).clearError();
      if (_contextDigest.isNotEmpty) {
        setState(() => _contextDigest = []);
      }
      InlineFeedback.of(context).hideCurrentSnackBar();
      InlineFeedback.of(context).showSnackBar(
        SnackBar(content: Text(l10n.get('noticesCleared'))),
        tone: FeedbackTone.success,
      );
      return;
    }
    final ids = visible.map((r) => r.id).toSet();
    _noticeOperations.value = {..._noticeOperations.value, ...ids};
    try {
      final results = await ref
          .read(remindersProvider.notifier)
          .acknowledgeOccurrences(visible, now: now);
      if (!mounted || !_runtimeActive) return;
      ref.read(homeControllerProvider.notifier).clearError();
      for (final reminder in visible) {
        _dueNoticeKeys.remove(reminderOccurrenceKey(reminder));
      }
      _dueNoticesVersion++;
      _noticeClock.value = DateTime.now();
      if (_contextDigest.isNotEmpty) {
        setState(() => _contextDigest = []);
      }
      final nativeFailed = results.any((r) => r.nativeSyncFailed);
      final stale = results.any(
        (r) => r.disposition == ReminderActionDisposition.stale,
      );
      final message = nativeFailed
          ? 'reminderNativeSyncFailed'
          : stale
          ? 'reminderOccurrenceChanged'
          : 'noticesCleared';
      InlineFeedback.of(context).hideCurrentSnackBar();
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.get(message)),
          action: nativeFailed ? notificationRepairAction(context) : null,
        ),
        tone: nativeFailed || stale
            ? FeedbackTone.warning
            : FeedbackTone.success,
      );
    } catch (_) {
      if (mounted && _runtimeActive) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
          tone: FeedbackTone.error,
        );
      }
    } finally {
      final updated = Set<String>.of(_noticeOperations.value)..removeAll(ids);
      _noticeOperations.value = updated;
    }
  }

  void _showImageDialog(String filePath) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                InteractiveViewer(
                  maxScale: 4.0,
                  child: Image.file(
                    File(filePath),
                    cacheWidth: 2048,
                    semanticLabel: p.basename(filePath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(l10n.get('cannotLoadImage')),
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: IconButton(
                    tooltip: l10n.get('close'),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const _filePreviewMaxBytes = 128 * 1024;

  Future<({String text, bool truncated})?> _readBoundedTextPreview(
    String filePath,
  ) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final raf = await file.open();
      final Uint8List raw;
      try {
        raw = await raf.read(_filePreviewMaxBytes + 1);
      } finally {
        await raf.close();
      }
      if (raw.isEmpty) return null;
      final truncated = raw.length > _filePreviewMaxBytes;
      final slice = truncated ? raw.sublist(0, _filePreviewMaxBytes) : raw;
      if (slice.contains(0)) return null;
      final decoded = utf8.decode(slice, allowMalformed: truncated);
      if (decoded.trim().isEmpty) return null;
      return (text: decoded, truncated: truncated);
    } catch (_) {
      return null;
    }
  }

  void _showFileDialog(String filePath) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final fileName = p.basename(filePath);
    final previewFuture = _readBoundedTextPreview(filePath);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant, width: 1),
        ),
        title: Row(
          children: [
            Icon(
              Icons.description_outlined,
              color: colors.primary,
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileName,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: FutureBuilder<({String text, bool truncated})?>(
            future: previewFuture,
            builder: (context, snapshot) {
              final preview = snapshot.data;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${l10n.get('localPath')}: $filePath',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const Divider(height: 18),
                  if (snapshot.connectionState != ConnectionState.done)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Text(l10n.get('loading')),
                        ],
                      ),
                    )
                  else if (preview != null) ...[
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          '${l10n.get('contentPreview')}:',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('home-file-preview-copy'),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: preview.text),
                            );
                            if (mounted && _runtimeActive) {
                              InlineFeedback.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.get('taskAttachmentTextCopied'),
                                  ),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy_rounded, size: 15),
                          label: Text(l10n.get('taskAttachmentCopyText')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 240),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest.withValues(
                          alpha: 0.45,
                        ),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: colors.outlineVariant),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          preview.text,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                    if (preview.truncated) ...[
                      const SizedBox(height: 6),
                      Text(
                        l10n.get('taskAttachmentTextTruncated'),
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ] else
                    Text(
                      l10n.get('binaryFileNotice'),
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              l10n.get('close'),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openVideo(String filePath) async {
    final l10n = AppLocalizations.of(context);
    final fileName = p.basename(filePath);
    var launched = false;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        launched = await launchUrl(
          Uri.file(filePath),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      launched = false;
    }
    if (!mounted || !_runtimeActive) return;
    InlineFeedback.of(context).hideCurrentSnackBar();
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text(
          launched
              ? '${l10n.get('openedVideo')}: $fileName'
              : l10n.get('videoOpenFailed'),
        ),
      ),
      tone: launched ? FeedbackTone.info : FeedbackTone.error,
    );
  }

  Future<void> _stopAudioPlayback({bool showFeedback = true}) async {
    try {
      await _serializePlayback(() async {
        if (_playbackStarted) {
          await _audioPlayer?.stop();
          _playbackStarted = false;
          _playingRecordId = null;
        }
      });
    } catch (_) {}
    if (showFeedback && mounted && _runtimeActive) {
      final l10n = AppLocalizations.of(context);
      InlineFeedback.of(context).hideCurrentSnackBar();
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          content: Text(l10n.get('playbackStopped')),
        ),
      );
    }
  }

  void _playMedia(String recordId) async {
    if (!mounted || !_runtimeActive) return;
    final l10n = AppLocalizations.of(context);
    try {
      await ref.read(mediaRecordsProvider.notifier).ready;
    } catch (_) {
      return;
    }
    if (!mounted || !_runtimeActive) return;
    final records = ref.read(mediaRecordsProvider);
    final media = records.where((m) => m.id == recordId).firstOrNull;
    if (media == null) {
      InlineFeedback.of(context).showSnackBar(
        SnackBar(content: Text(l10n.get('mediaUnavailable'))),
        tone: FeedbackTone.warning,
      );
      return;
    }

    final mediaPath = await _mediaStore.resolvePath(media.contentOrPath);
    if (!mounted || !_runtimeActive) return;
    if (media.type == 'audio') {
      if (_playbackStarted && _playingRecordId == recordId) {
        await _stopAudioPlayback();
        return;
      }
      var playFailed = false;
      await _serializePlayback(() async {
        if (!mounted || !_runtimeActive) return;
        _playbackStarted = true;
        _playingRecordId = recordId;
        try {
          await _ensureAudioPlayer().play(DeviceFileSource(mediaPath));
        } catch (_) {
          if (_playingRecordId == recordId) {
            _playbackStarted = false;
            _playingRecordId = null;
          }
          playFailed = true;
        }
      });
      if (playFailed) {
        if (mounted && _runtimeActive) {
          InlineFeedback.of(context).showSnackBar(
            SnackBar(content: Text(l10n.get('audioPlaybackFailed'))),
            tone: FeedbackTone.error,
          );
        }
        return;
      }
      if (mounted && _runtimeActive) {
        InlineFeedback.of(context).hideCurrentSnackBar();
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            content: Text(l10n.get('playingAudio')),
            action: SnackBarAction(
              label: l10n.get('stopPlayback'),
              onPressed: () => unawaited(_stopAudioPlayback()),
            ),
          ),
        );
      }
    } else if (media.type == 'image') {
      _showImageDialog(mediaPath);
    } else if (media.type == 'file') {
      _showFileDialog(mediaPath);
    } else if (media.type == 'video') {
      unawaited(_openVideo(mediaPath));
    }
  }

  void _selectTool(_WorkspaceTool tool) {
    if (!mounted || !_runtimeActive || _toolBlocked) return;
    setState(() => _activeTool = tool);
  }

  void _openFocusMode() => _selectTool(_WorkspaceTool.focus);
  void _openSpacedRepetitionSheet() {
    if (_toolBlocked) return;
    _preferredReviewId = null;
    _selectTool(_WorkspaceTool.review);
  }

  void _openNoticeReview(Reminder reminder) {
    if (!mounted || !_runtimeActive || _toolBlocked) return;
    final current = ref
        .read(remindersProvider)
        .where((item) => item.id == reminder.id)
        .firstOrNull;
    if (current == null ||
        !current.reviewNotificationsEnabled ||
        !ref.read(spacedRepetitionServiceProvider).isDue(current)) {
      return;
    }
    _preferredReviewId = current.id;
    _selectTool(_WorkspaceTool.review);
  }

  void _openContextDigest() => _selectTool(_WorkspaceTool.digest);

  IconData _getContextProfileIcon(ContextProfile profile) {
    switch (profile) {
      case ContextProfile.office:
        return Icons.apartment_rounded;
      case ContextProfile.deepWork:
        return Icons.psychology_rounded;
      case ContextProfile.home:
        return Icons.home_rounded;
      case ContextProfile.commute:
        return Icons.directions_subway_rounded;
      case ContextProfile.general:
        return Icons.tune_rounded;
    }
  }

  Future<void> _exportCsvData() async {
    _selectTool(_WorkspaceTool.export);
  }

  void _closeWorkspaceTool() {
    if (!mounted || _toolBlocked) return;
    setState(() => _activeTool = null);
  }

  void _setExportBusy(bool value) {
    if (mounted) setState(() => _exportBusy = value);
  }

  void _showMultiAgentGoalDialog() => _selectTool(_WorkspaceTool.agent);

  Future<void> _discardAgentDraft() async {
    if (_agentBusy || _discardDialogOpen || !_runtimeActive) return;
    _discardDialogOpen = true;
    final loc = AppLocalizations.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.get('unsavedChangesTitle')),
        content: Text(loc.get('agentDiscardMessage')),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.get('keepEditing')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.get('discardChanges')),
          ),
        ],
      ),
    );
    _discardDialogOpen = false;
    if (discard == true && _runtimeActive) _agentGoal.clear();
  }

  Future<void> _submitAgentGoal() async {
    if (_agentBusy || !_runtimeActive || _agentGoal.text.trim().isEmpty) return;
    final submitted = _agentGoal.text;
    setState(() => _agentBusy = true);
    try {
      await ref
          .read(homeControllerProvider.notifier)
          .processWithMultiAgent(submitted.trim());
      if (_runtimeActive && _agentGoal.text == submitted) _agentGoal.clear();
    } catch (_) {
      // HomeState exposes the current-session failure; preserve the retry draft.
    } finally {
      if (mounted) setState(() => _agentBusy = false);
    }
  }

  Future<void> _runDynamicUrgencyScan() async {
    if (!mounted || !_runtimeActive) return;
    final l10n = AppLocalizations.of(context);
    try {
      final result = await ref
          .read(remindersProvider.notifier)
          .scanAndApplyDynamicUrgency();
      if (!mounted || !_runtimeActive) return;
      final message =
          '${l10n.get('dynamicPromotedCount')}: ${result.changed}'
          '${result.nativeSyncFailures > 0 ? '\n${l10n.get('reminderNativeSyncFailed')}' : ''}';
      InlineFeedback.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted || !_runtimeActive) return;
      InlineFeedback.of(context).showSnackBar(
        SnackBar(content: Text(l10n.get('dynamicScanFailed'))),
      );
    }
  }

  void _openSettings() {
    if (!mounted || !_runtimeActive || _toolBlocked) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PreferencesScreen()),
    );
  }

  bool _openCommandPalette() {
    if (!_runtimeActive ||
        _toolBlocked ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final l10n = AppLocalizations.of(context);
    final isImmersive = ref.read(immersiveModeProvider);
    final pendingSharedCount = SharedTextInbox.count(
      ref.read(workspaceDraftsProvider),
    );
    final lang = l10n.locale.languageCode;

    CommandPaletteDialog.show(context, [
      CommandPaletteAction(
        id: 'study',
        title: l10n.get('studyTitle'),
        subtitle: l10n.get('studyIntro'),
        icon: Icons.auto_stories_outlined,
        shortcut: '/study',
        onExecute: () => _selectTool(_WorkspaceTool.study),
      ),
      CommandPaletteAction(
        id: 'graph',
        title: l10n.get('knowledgeGraphTitle'),
        subtitle: l10n.get('knowledgeGraphSubtitle'),
        icon: Icons.hub_outlined,
        shortcut: 'G',
        onExecute: () => _selectTool(_WorkspaceTool.graph),
      ),
      CommandPaletteAction(
        id: 'agent',
        title: l10n.get('multiAgentTitle'),
        subtitle: l10n.get('multiAgentDesc'),
        icon: Icons.auto_awesome,
        shortcut: '/agent',
        onExecute: _showMultiAgentGoalDialog,
      ),
      CommandPaletteAction(
        id: 'learning-queue',
        title: l10n.get('learningQueueTitle'),
        subtitle: l10n.get('learningBudgetHint'),
        icon: Icons.auto_stories_outlined,
        onExecute: () => _selectTool(_WorkspaceTool.learning),
      ),
      CommandPaletteAction(
        id: 'digest',
        title: l10n.get('contextDigestTitle'),
        subtitle: l10n.get('contextDigestDesc'),
        icon: Icons.summarize_outlined,
        shortcut: 'C',
        onExecute: _openContextDigest,
      ),
      CommandPaletteAction(
        id: 'scan_urgency',
        title: l10n.get('scanDynamicUrgency'),
        subtitle: l10n.get('scanDynamicUrgencyDesc'),
        icon: Icons.bolt,
        shortcut: 'U',
        onExecute: () => unawaited(_runDynamicUrgencyScan()),
      ),
      CommandPaletteAction(
        id: 'focus',
        title: l10n.get('focusTitle'),
        subtitle: l10n.get(isImmersive ? 'focusOn' : 'focusOff'),
        icon: isImmersive ? Icons.shield : Icons.shield_outlined,
        shortcut: 'F',
        onExecute: _openFocusMode,
      ),
      CommandPaletteAction(
        id: 'cards',
        title: l10n.get('spacedRepetitionTitle'),
        subtitle: l10n.get('spacedRepetitionSubtitle'),
        icon: Icons.school_outlined,
        shortcut: 'R',
        onExecute: _openSpacedRepetitionSheet,
      ),
      CommandPaletteAction(
        id: 'export',
        title: l10n.get('exportExcel'),
        subtitle: l10n.get('exportExcelDesc'),
        icon: Icons.table_chart_outlined,
        shortcut: 'E',
        onExecute: _exportCsvData,
      ),
      CommandPaletteAction(
        id: 'search',
        title: l10n.get('searchResults'),
        subtitle: l10n.get('searchHint'),
        icon: Icons.search_rounded,
        shortcut: '/',
        onExecute: _openSearch,
      ),
      CommandPaletteAction(
        id: 'quick_capture',
        title: l10n.get('quickCaptureAction'),
        subtitle: l10n.get('addFirstTask'),
        icon: Icons.add_task_rounded,
        shortcut: 'N',
        onExecute: () => ref.read(captureInputCommandProvider).focus?.call(),
      ),
      CommandPaletteAction(
        id: 'shared_drafts',
        title: sharedTextLabel(lang, 'title'),
        subtitle: pendingSharedCount > 0
            ? l10n
                  .get('pendingSharedDrafts')
                  .replaceAll('{count}', '$pendingSharedCount')
            : sharedTextLabel(lang, 'hint'),
        icon: Icons.inbox_outlined,
        onExecute: () => openSharedTextInbox(context, ref),
      ),
      CommandPaletteAction(
        id: 'dashboard',
        title: l10n.get('dashboardTitle'),
        subtitle: l10n.get('taskCompletion'),
        icon: Icons.bar_chart_rounded,
        shortcut: 'B',
        onExecute: () => _selectTool(_WorkspaceTool.dashboard),
      ),
      CommandPaletteAction(
        id: 'clear_notices',
        title: l10n.get('clearAllNotices'),
        subtitle: l10n.get('noticesCleared'),
        icon: Icons.notifications_off_outlined,
        onExecute: _clearAllNotices,
      ),
      CommandPaletteAction(
        id: 'clear_completed',
        title: l10n.get('clearCompletedTitle'),
        subtitle: l10n.get('clearCompleted'),
        icon: Icons.cleaning_services_outlined,
        onExecute: _confirmClearCompleted,
      ),
      CommandPaletteAction(
        id: 'settings',
        title: l10n.get('settings'),
        subtitle: l10n.get('lanSyncTitle'),
        icon: Icons.settings_outlined,
        shortcut: ',',
        onExecute: _openSettings,
      ),
      CommandPaletteAction(
        id: 'planning',
        title: planningText(context, 'planning'),
        subtitle: planningText(context, 'planningHint'),
        icon: Icons.event_repeat,
        shortcut: '/plans',
        onExecute: () => _selectTool(_WorkspaceTool.planning),
      ),
    ]);
    return true;
  }

  void _handleGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        !_runtimeActive ||
        _toolBlocked ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }

    final primaryFocus = FocusManager.instance.primaryFocus;
    final focusContext = primaryFocus?.context;
    final isTyping =
        focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null);

    final editable = focusContext?.widget is EditableText
        ? focusContext!.widget as EditableText
        : focusContext?.findAncestorWidgetOfExactType<EditableText>();
    final composing = editable?.controller.value.composing;
    if (composing != null && composing.isValid && !composing.isCollapsed) {
      return;
    }

    final isCtrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    if (event.logicalKey == LogicalKeyboardKey.escape &&
        _activeTool != null &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      _closeWorkspaceTool();
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape && _isSearchOpen) {
      _closeSearch();
      return;
    }
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyF) {
      _openSearch();
      return;
    }

    // Ctrl+K -> Command Palette
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyK) {
      _openCommandPalette();
      return;
    }
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyN) {
      ref.read(captureInputCommandProvider).focus?.call();
      return;
    }

    if (isTyping || isCtrl || HardwareKeyboard.instance.isAltPressed) return;

    if (event.logicalKey == LogicalKeyboardKey.slash) {
      _openSearch();
    } else if (event.logicalKey == LogicalKeyboardKey.keyN) {
      ref.read(captureInputCommandProvider).focus?.call();
    } else if (!_isSearchOpen &&
        _activeTool == null &&
        event.logicalKey == LogicalKeyboardKey.digit1) {
      _switchWorkspaceView('today');
    } else if (!_isSearchOpen &&
        _activeTool == null &&
        event.logicalKey == LogicalKeyboardKey.digit2) {
      _switchWorkspaceView('future');
    } else if (!_isSearchOpen &&
        _activeTool == null &&
        event.logicalKey == LogicalKeyboardKey.digit3) {
      _switchWorkspaceView('all');
    } else if (!_isSearchOpen &&
        _activeTool == null &&
        event.logicalKey == LogicalKeyboardKey.digit4) {
      _switchWorkspaceView('board');
    } else if (event.logicalKey == LogicalKeyboardKey.keyG) {
      _selectTool(_WorkspaceTool.graph);
    } else if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _openContextDigest();
    } else if (event.logicalKey == LogicalKeyboardKey.keyU) {
      unawaited(_runDynamicUrgencyScan());
    } else if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _openFocusMode();
    } else if (event.logicalKey == LogicalKeyboardKey.keyR) {
      _openSpacedRepetitionSheet();
    } else if (event.logicalKey == LogicalKeyboardKey.keyB) {
      _selectTool(_WorkspaceTool.dashboard);
    } else if (event.logicalKey == LogicalKeyboardKey.keyE) {
      _exportCsvData();
    } else if (event.logicalKey == LogicalKeyboardKey.comma) {
      _openSettings();
    }
  }

  bool _openSearch() {
    if (!mounted ||
        !_runtimeActive ||
        _toolBlocked ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    setState(() {
      _activeTool = null;
      _isSearchOpen = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _isSearchOpen &&
          _runtimeActive &&
          ModalRoute.of(context)?.isCurrent == true) {
        _searchFocus.requestFocus();
      }
    });
    return true;
  }

  void _clearSearch() {
    _searchController.clear();
    _updateSearch('');
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    if (!mounted || !_runtimeActive) return;
    _searchDebounce?.cancel();
    setState(() {
      _isSearchOpen = false;
      _searchController.clear();
      _searchQuery = '';
    });
  }

  void _updateSearch(String query) {
    if (!mounted || !_runtimeActive) return;
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchQuery = '');
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted && _runtimeActive) setState(() => _searchQuery = query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reminders = ref.watch(workspaceRemindersProvider);
    final l10n = AppLocalizations.of(context);
    final spacedService = ref.watch(spacedRepetitionServiceProvider);
    final pendingSharedCount = ref.watch(
      workspaceDraftsProvider.select(SharedTextInbox.count),
    );
    final digest = _contextTriggers.activeDigest(
      reminders,
      previous: _contextDigest,
    );
    final suppressedCount = digest.length;

    ref.listen<String?>(homeControllerProvider.select((s) => s.error), (
      previous,
      nextError,
    ) {
      if (_runtimeActive && nextError != null) {
        InlineFeedback.of(context).hideCurrentSnackBar();
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            action: nextError == l10n.get('reminderNativeSyncFailed')
                ? notificationRepairAction(context)
                : null,
            content: Text(
              nextError == l10n.get('reminderNativeSyncFailed')
                  ? l10n.get('reminderNativeSyncFailedCompact')
                  : nextError,
            ),
          ),
          tone: nextError == l10n.get('reminderNativeSyncFailed')
              ? FeedbackTone.warning
              : FeedbackTone.error,
        );
        ref.read(homeControllerProvider.notifier).clearError();
      }
    });

    return KeyboardListener(
      focusNode: _shortcutFocus,
      autofocus: true,
      onKeyEvent: _handleGlobalKeyEvent,
      child: PopScope(
        canPop: _activeTool == null && !_isSearchOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_activeTool != null) {
            _closeWorkspaceTool();
          } else if (_isSearchOpen) {
            _closeSearch();
          }
        },
        child: Scaffold(
          extendBodyBehindAppBar: false,
          appBar: AppBar(
            centerTitle: false,
            leading: _isSearchOpen
                ? IconButton(
                    icon: const Icon(Icons.arrow_back, size: 20),
                    tooltip: l10n.get('close'),
                    onPressed: _closeSearch,
                  )
                : null,
            title: _isSearchOpen
                ? TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    key: const ValueKey('task-search-field'),
                    autofocus: true,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: l10n.get('searchHint'),
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainer,
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                    onChanged: _updateSearch,
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Image(
                        image: ResizeImage(
                          AssetImage('assets/app_icon.png'),
                          width: 78,
                          height: 78,
                        ),
                        width: 26,
                        height: 26,
                        excludeFromSemantics: true,
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          l10n.get('appTitle'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      Consumer(
                        builder: (context, ref, _) {
                          final isProcessing = ref.watch(
                            homeControllerProvider.select(
                              (state) => state.isProcessingInBackground,
                            ),
                          );
                          if (!isProcessing) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Semantics(
                              liveRegion: true,
                              child: Icon(
                                Icons.circle,
                                size: 7,
                                color: Theme.of(context).colorScheme.primary,
                                semanticLabel: l10n.get('statusBusy'),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
            elevation: 0,
            backgroundColor: Colors.transparent,
            actions: _isSearchOpen
                ? [
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _searchController,
                      builder: (context, value, _) => value.text.isEmpty
                          ? const SizedBox.shrink()
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              tooltip: l10n.get('clearSearch'),
                              onPressed: _clearSearch,
                            ),
                    ),
                    const SizedBox(width: 6),
                  ]
                : [
                    IconButton(
                      icon: const Icon(Icons.search_rounded),
                      tooltip: l10n.get('searchHint'),
                      onPressed: _openSearch,
                    ),
                    Consumer(
                      builder: (context, ref, _) {
                        final currentProfile = ref.watch(
                          contextProfileProvider,
                        );
                        return PopupMenuButton<ContextProfile>(
                          icon: Icon(
                            _getContextProfileIcon(currentProfile),
                            size: 20,
                            color: currentProfile == ContextProfile.general
                                ? null
                                : Theme.of(context).colorScheme.primary,
                          ),
                          tooltip: l10n.get('contextProfileSwitch'),
                          splashRadius: 18,
                          onSelected: (profile) async {
                            if (!mounted || !_runtimeActive) return;
                            try {
                              await ref
                                  .read(contextProfileProvider.notifier)
                                  .setProfile(profile);
                            } catch (_) {
                              if (!mounted ||
                                  !_runtimeActive ||
                                  !context.mounted) {
                                return;
                              }
                              InlineFeedback.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.get('reminderUpdateFailed'),
                                  ),
                                ),
                              );
                            }
                          },
                          itemBuilder: (context) {
                            return [
                              for (final entry
                                  in <(ContextProfile, IconData, String)>[
                                    (
                                      ContextProfile.general,
                                      Icons.tune_rounded,
                                      'profileGeneral',
                                    ),
                                    (
                                      ContextProfile.office,
                                      Icons.apartment_rounded,
                                      'profileOffice',
                                    ),
                                    (
                                      ContextProfile.deepWork,
                                      Icons.psychology_rounded,
                                      'profileDeepWork',
                                    ),
                                    (
                                      ContextProfile.home,
                                      Icons.home_rounded,
                                      'profileHome',
                                    ),
                                    (
                                      ContextProfile.commute,
                                      Icons.directions_subway_rounded,
                                      'profileCommute',
                                    ),
                                  ])
                                CheckedPopupMenuItem<ContextProfile>(
                                  value: entry.$1,
                                  checked: currentProfile == entry.$1,
                                  child: Row(
                                    children: [
                                      Icon(entry.$2, size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(l10n.get(entry.$3))),
                                    ],
                                  ),
                                ),
                            ];
                          },
                        );
                      },
                    ),
                    ValueListenableBuilder<DateTime>(
                      valueListenable: _noticeClock,
                      builder: (context, _, child) {
                        final count =
                            _reviewQueue
                                .read(
                                  reminders,
                                  spacedService,
                                  now: _noticeClock.value,
                                )
                                .due
                                .length +
                            suppressedCount;
                        return Badge(
                          isLabelVisible: count > 0,
                          label: Text('$count'),
                          child: child,
                        );
                      },
                      child: Consumer(
                        builder: (context, ref, _) {
                          final isImmersive = ref.watch(immersiveModeProvider);
                          return IconButton(
                            icon: Icon(
                              isImmersive
                                  ? Icons.shield_rounded
                                  : Icons.more_horiz_rounded,
                            ),
                            tooltip: isImmersive
                                ? '${l10n.get('moreTools')} / ${l10n.get('focusOn')}'
                                : l10n.get('moreTools'),
                            onPressed: _openCommandPalette,
                          );
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: l10n.get('settings'),
                      onPressed: _openSettings,
                    ),
                    const SizedBox(width: 8),
                  ],
          ),
          body: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              bottom: false,
              child: Center(
                child: ConstrainedBox(
                  key: const ValueKey('home-content-frame'),
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: Column(
                    children: [
                      ValueListenableBuilder<DateTime>(
                        valueListenable: _noticeClock,
                        builder: (context, tick, _) {
                          final snapshot = _noticeSnapshot(reminders, tick);
                          final visible = snapshot.visible;
                          final missed = snapshot.missed;
                          if (visible.isEmpty && missed.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ValueListenableBuilder<Set<String>>(
                                valueListenable: _noticeOperations,
                                builder: (context, busyIds, _) =>
                                    ReminderNoticePanel(
                                      reminders: visible,
                                      now: snapshot.now,
                                      busyIds: busyIds,
                                      onDismiss: _dismissNotice,
                                      onDismissPhase: (r, {required upcoming}) =>
                                          _dismissNotice(r, upcoming: upcoming),
                                      onOpen: (r) => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              TaskDetailScreen(task: r),
                                        ),
                                      ),
                                      onSnooze: (r) =>
                                          _actOnNotice(r, snooze: true),
                                      onSnoozeUntil: (r, until) {
                                        final at = DateTime.now();
                                        if (!until.isAfter(at)) return;
                                        _performNoticeAction(
                                          r,
                                          () => ref
                                              .read(remindersProvider.notifier)
                                              .snoozeOccurrence(
                                                r,
                                                now: at,
                                                duration: until.difference(at),
                                              ),
                                          kind: _NoticeActionKind.snooze,
                                        );
                                      },
                                      onSkip: (r) => _performNoticeAction(
                                        r,
                                        () => ref
                                            .read(remindersProvider.notifier)
                                            .skipOccurrence(r),
                                        kind: _NoticeActionKind.skip,
                                      ),
                                      onComplete: (r) =>
                                          _actOnNotice(r, snooze: false),
                                      onReview: _toolBlocked
                                          ? null
                                          : _openNoticeReview,
                                    ),
                              ),
                              ValueListenableBuilder<bool>(
                                valueListenable: _acknowledgingMissed,
                                builder: (context, ackBusy, _) =>
                                    MissedRemindersBar(
                                      reminders: missed,
                                      busy: ackBusy,
                                      onOpenMissed: _openMissedFilter,
                                      onAcknowledgeAll: () =>
                                          _acknowledgeAllMissed(missed),
                                    ),
                              ),
                            ],
                          );
                        },
                      ),
                      if (digest.isNotEmpty || pendingSharedCount > 0)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                if (digest.isNotEmpty)
                                  TextButton.icon(
                                    onPressed: _openContextDigest,
                                    icon: const Icon(
                                      Icons.summarize_outlined,
                                      size: 18,
                                    ),
                                    label: Text(l10n.get('contextDigestTitle')),
                                  ),
                                if (pendingSharedCount > 0)
                                  TextButton.icon(
                                    key: const ValueKey(
                                      'pending-shared-drafts-bar',
                                    ),
                                    onPressed: () =>
                                        openSharedTextInbox(context, ref),
                                    icon: const Icon(
                                      Icons.inbox_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      l10n
                                          .get('pendingSharedDrafts')
                                          .replaceAll(
                                            '{count}',
                                            '$pendingSharedCount',
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: WorkspaceToolArea(
                          tool: switch (_activeTool) {
                            _WorkspaceTool.focus => FocusModeSheet(
                              key: const ValueKey('focus-tool'),
                              embedded: true,
                              onClose: _closeWorkspaceTool,
                            ),
                            _WorkspaceTool.export => DataExportSheet(
                              key: const ValueKey('export-tool'),
                              embedded: true,
                              onClose: _closeWorkspaceTool,
                              onBusyChanged: _setExportBusy,
                            ),
                            _WorkspaceTool.review => SpacedRepetitionSheet(
                              key: const ValueKey('review-tool'),
                              embedded: true,
                              initialReminderId: _preferredReviewId,
                              onClose: _closeWorkspaceTool,
                              onCreateStudyPlan: () =>
                                  _selectTool(_WorkspaceTool.study),
                              onBusyChanged: (value) =>
                                  setState(() => _toolBusy = value),
                            ),
                            _WorkspaceTool.digest => ContextDigestSheet(
                              key: const ValueKey('digest-tool'),
                              embedded: true,
                              onClose: _closeWorkspaceTool,
                              digestReminders: digest,
                            ),
                            _WorkspaceTool.graph => KnowledgeGraphScreen(
                              key: const ValueKey('graph-tool'),
                              embedded: true,
                              onClose: _closeWorkspaceTool,
                            ),
                            _WorkspaceTool.dashboard => DashboardScreen(
                              key: const ValueKey('dashboard-tool'),
                              embedded: true,
                              onClose: _closeWorkspaceTool,
                              onBusyChanged: (value) =>
                                  setState(() => _toolBusy = value),
                            ),
                            _WorkspaceTool.agent => AgentGoalPanel(
                              key: const ValueKey('agent-tool'),
                              controller: _agentGoal,
                              busy: _agentBusy,
                              onClose: _closeWorkspaceTool,
                              onSubmit: _submitAgentGoal,
                              onDiscard: _discardAgentDraft,
                            ),
                            _WorkspaceTool.study => StudyPlanPanel(
                              key: const ValueKey('study-tool'),
                              draft: _studyDraft,
                              onClose: _closeWorkspaceTool,
                              onReview: _openSpacedRepetitionSheet,
                              onBusyChanged: (value) =>
                                  setState(() => _toolBusy = value),
                            ),
                            _WorkspaceTool.learning => LearningQueuePanel(
                              onClose: _closeWorkspaceTool,
                            ),
                            _WorkspaceTool.planning => PlanningPanel(
                              onClose: _closeWorkspaceTool,
                            ),
                            null => null,
                          },
                          child: _isSearchOpen
                              ? TaskSearchPanel(
                                  query: _searchQuery,
                                  onClearQuery: _clearSearch,
                                  onPlayMedia: _playMedia,
                                )
                              : _buildWorkspaceOverview(reminders),
                        ),
                      ),
                      const InputBottomBar(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
