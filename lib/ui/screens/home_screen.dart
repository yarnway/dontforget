import '../widgets/reminder_notice_panel.dart';
import '../../data/database_helper.dart';
import '../widgets/inline_feedback.dart';
import '../formatters/local_date_time.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../providers/home_controller.dart';
import '../../services/notification_service.dart';
import '../../services/notification_permission_service.dart';
import '../../services/notification_retry_coordinator.dart';
import '../../services/time_zone_change_coordinator.dart';
import '../../services/startup_trace.dart';
import '../../services/recovery/runtime_gate.dart';
import 'settings_screen.dart';
import 'dashboard_screen.dart';
import '../widgets/task_search_panel.dart';
import '../widgets/input_bottom_bar.dart';
import '../widgets/task_board.dart';
import '../widgets/command_palette_dialog.dart';
import '../widgets/spaced_repetition_sheet.dart';
import '../widgets/focus_mode_sheet.dart';
import '../widgets/context_digest_sheet.dart';
import '../../services/context_trigger_service.dart';
import '../../services/spaced_repetition_service.dart';
import 'knowledge_graph_screen.dart';
import '../../l10n/app_localizations.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final _audioPlayer = AudioPlayer();
  late final RuntimeRecoveryGate _runtime;
  late final RuntimeRecoveryToken? _birth;
  late final NotificationService _notifications;
  late final ContextTriggerService _contextTriggers;
  Future<void> _playbackOperations = Future<void>.value();
  bool _playbackStarted = false;

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
    _heartbeatTimer?.cancel();
    _searchDebounce?.cancel();
    await Future.wait([
      if (_timeZoneChanges != null) _timeZoneChanges!.stop(),
      if (_notificationRetries != null) _notificationRetries!.stop(),
      if (_dueSubscription != null) _dueSubscription!.cancel(),
      if (_catchUpDigestSubscription != null)
        _catchUpDigestSubscription!.cancel(),
      if (_suppressedSubscription != null) _suppressedSubscription!.cancel(),
      _serializePlayback(() async {
        if (_playbackStarted) {
          await _audioPlayer.stop();
          _playbackStarted = false;
        }
      }),
    ]);
    _promptedReminderIds.clear();
    _dueNotices.clear();
    _contextDigest = [];
  }

  Timer? _heartbeatTimer;
  NotificationRetryCoordinator? _notificationRetries;
  TimeZoneChangeCoordinator? _timeZoneChanges;
  StreamSubscription<Reminder>? _dueSubscription;
  StreamSubscription<List<Reminder>>? _catchUpDigestSubscription;
  StreamSubscription<List<Reminder>>? _suppressedSubscription;
  final Set<String> _promptedReminderIds = {};
  final Map<String, Reminder> _dueNotices = {};
  final Set<String> _noticeOperations = {};
  List<Reminder> _contextDigest = [];
  final _shortcutFocus = FocusNode(
    debugLabel: 'workspace-shortcuts',
    skipTraversal: true,
  );
  WorkspaceToolsCommand? _toolsCommand;
  late final bool Function() _nativeToolsHandler = _openCommandPalette;
  bool _isSearchOpen = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'task-search');
  String _searchQuery = '';
  Timer? _searchDebounce;
  final _noticeClock = ValueNotifier(DateTime.now());
  final _reviewQueue = ReviewQueueCache();

  @override
  void initState() {
    super.initState();
    _runtime = ref.read(runtimeRecoveryGateProvider);
    _birth = _runtime.paused ? null : _runtime.capture();
    _notifications = ref.read(notificationServiceProvider);
    _contextTriggers = ref.read(contextTriggerServiceProvider);
    if (_birth == null) return;
    _toolsCommand = ref.read(workspaceToolsCommandProvider);
    _toolsCommand!.open = _nativeToolsHandler;
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
      setState(() => _contextDigest = digestList);
    });

    // 监听拦截队列更新以便即时刷新情境徽标
    _suppressedSubscription = _contextTriggers.onSuppressedUpdated.listen((_) {
      if (mounted && _runtimeActive) setState(() {});
    });

    // 启动时触发 Wi-Fi 嗅探与情境感知
    _contextTriggers.detectCurrentWifiSsid();

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
          _dueNotices.removeWhere((key, _) => !currentKeys.contains(key));
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
    _runtime.unregister(this);
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _searchFocus.dispose();
    _searchDebounce?.cancel();
    _noticeClock.dispose();
    _shortcutFocus.dispose();
    _heartbeatTimer?.cancel();
    unawaited(_timeZoneChanges?.stop());
    unawaited(_notificationRetries?.stop());
    _dueSubscription?.cancel();
    _catchUpDigestSubscription?.cancel();
    _suppressedSubscription?.cancel();
    unawaited(
      _serializePlayback(
        () => _audioPlayer.dispose(),
      ).catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notificationRetries?.setForeground(state == AppLifecycleState.resumed);
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
    _noticeClock.value = DateTime.now();
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
      if (!r.isCompleted &&
          r.triggerTime != null &&
          r.noticeAcknowledgedAt == null) {
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

    // 情境感知触发器检测 (检测 Wi-Fi SSID 接入)
    _contextTriggers
        .detectCurrentWifiSsid()
        .then((ssid) {
          if (ssid != null &&
              _runtimeActive &&
              database.isCurrent(generation)) {
            final matched = _contextTriggers.evaluateContextTriggers(
              reminders,
              ssid: ssid,
            );
            for (final m in matched) {
              unawaited(
                database
                    .runOperation(generation, () async {
                      await ref
                          .read(notificationServiceProvider)
                          .showWindowsToast(
                            '📍 情境感知提醒 [已连接 $ssid]',
                            m.taskTitle,
                          );
                    })
                    .catchError((Object _) {}),
              );
            }
          }
        })
        .catchError((Object _) {});

    // 动态跃迁周期扫描
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
    setState(() => _dueNotices[key] = current.first);
  }

  List<Reminder> _visibleNotices(List<Reminder> reminders, DateTime now) {
    return reminders.where((r) {
      if (r.isCompleted ||
          r.triggerTime == null ||
          _notifications.isSuppressed(r)) {
        return false;
      }
      final key = reminderOccurrenceKey(r);
      final upcoming = r.triggerTime!.isAfter(now);
      if (r.noticeAcknowledgedAt != null ||
          (upcoming && r.upcomingDismissedAt != null)) {
        return false;
      }
      return upcoming
          ? r.triggerTime!.difference(now) <= const Duration(minutes: 5)
          : _dueNotices.containsKey(key) ||
                now.difference(r.triggerTime!) <= const Duration(minutes: 15);
    }).toList()..sort((a, b) => a.triggerTime!.compareTo(b.triggerTime!));
  }

  Future<void> _dismissNotice(Reminder reminder) async {
    final now = DateTime.now();
    await _performNoticeAction(
      reminder,
      () => ref
          .read(remindersProvider.notifier)
          .acknowledgeOccurrence(
            reminder,
            phase: reminder.triggerTime!.isAfter(now)
                ? ReminderNoticePhase.upcoming
                : ReminderNoticePhase.due,
            now: now,
          ),
    );
  }

  Future<void> _actOnNotice(Reminder reminder, {required bool snooze}) async {
    await _performNoticeAction(
      reminder,
      () => snooze
          ? ref.read(remindersProvider.notifier).snoozeOccurrence(reminder)
          : ref.read(remindersProvider.notifier).completeOccurrence(reminder),
      snooze: snooze,
    );
  }

  Future<void> _performNoticeAction(
    Reminder reminder,
    Future<ReminderActionResult> Function() action, {
    bool? snooze,
  }) async {
    if (!_runtimeActive || !_noticeOperations.add(reminder.id)) return;
    setState(() {});
    final l10n = AppLocalizations.of(context);
    try {
      final result = await action();
      if (!mounted || !_runtimeActive) return;
      if (result.disposition == ReminderActionDisposition.stale) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('reminderOccurrenceChanged'))),
        );
        return;
      }
      setState(() => _dueNotices.remove(reminderOccurrenceKey(reminder)));
      String? message;
      if (result.nativeSyncFailed) {
        message = l10n.get('reminderNativeSyncFailed');
      } else if (snooze != null) {
        final saved = result.reminder;
        message = snooze
            ? l10n.get('snoozeSuccess')
            : saved != null && !saved.isCompleted && saved.triggerTime != null
            ? '${l10n.get('periodicNext')}${formatLocalDateTime(saved.triggerTime!)}'
            : l10n.get('taskCompleted');
      }
      if (message != null) {
        InlineFeedback.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (mounted && _runtimeActive) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
        );
      }
    } finally {
      _noticeOperations.remove(reminder.id);
      if (_runtimeActive) setState(() {});
    }
  }

  void _confirmClearCompleted() {
    if (!mounted || !_runtimeActive) return;
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final completedCount = ref
        .read(remindersProvider)
        .where((r) => r.isCompleted)
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1,
          ),
        ),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        title: Row(
          children: [
            const Icon(
              Icons.cleaning_services_outlined,
              color: Colors.redAccent,
              size: 22,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.get('clearCompletedTitle'),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
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
              backgroundColor: Colors.redAccent,
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
    if (!_runtimeActive || _noticeOperations.isNotEmpty) return;
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final visible = _visibleNotices(ref.read(remindersProvider), now);
    setState(() => _noticeOperations.addAll(visible.map((r) => r.id)));
    try {
      final results = await ref
          .read(remindersProvider.notifier)
          .acknowledgeOccurrences(visible, now: now);
      if (!mounted || !_runtimeActive) return;
      ref.read(homeControllerProvider.notifier).clearError();
      setState(() {
        for (final reminder in visible) {
          _dueNotices.remove(reminderOccurrenceKey(reminder));
        }
        _contextDigest = [];
      });
      final message = results.any((r) => r.nativeSyncFailed)
          ? 'reminderNativeSyncFailed'
          : results.any((r) => r.disposition == ReminderActionDisposition.stale)
          ? 'reminderOccurrenceChanged'
          : 'noticesCleared';
      InlineFeedback.of(context).hideCurrentSnackBar();
      InlineFeedback.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.get(message))));
    } catch (_) {
      if (mounted && _runtimeActive) {
        InlineFeedback.of(context).showSnackBar(
          SnackBar(content: Text(l10n.get('reminderUpdateFailed'))),
        );
      }
    } finally {
      _noticeOperations.removeAll(visible.map((r) => r.id));
      if (_runtimeActive) setState(() {});
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
                  child: CircleAvatar(
                    backgroundColor: Colors.black54,
                    radius: 16,
                    child: IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 16,
                      ),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showFileDialog(String filePath) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fileName = filePath.split(Platform.pathSeparator).last;
    String preview = '';
    try {
      final f = File(filePath);
      if (f.existsSync() && f.lengthSync() < 300 * 1024) {
        preview = f.readAsStringSync();
      }
    } catch (_) {}

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 1,
          ),
        ),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        title: Row(
          children: [
            const Icon(
              Icons.description_outlined,
              color: Colors.amber,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${l10n.get('localPath')}: $filePath',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const Divider(height: 18),
              if (preview.isNotEmpty) ...[
                Text(
                  '${l10n.get('contentPreview')}:',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.2),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      preview,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ] else
                Text(
                  l10n.get('binaryFileNotice'),
                  style: const TextStyle(fontSize: 12),
                ),
            ],
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

  void _openVideo(String filePath) {
    final l10n = AppLocalizations.of(context);
    final fileName = filePath.split(Platform.pathSeparator).last;
    if (Platform.isWindows) {
      try {
        Process.run('cmd', ['/c', 'start', '', filePath]);
      } catch (_) {}
    }
    InlineFeedback.of(context).hideCurrentSnackBar();
    InlineFeedback.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text('${l10n.get('openedVideo')}: $fileName'),
      ),
    );
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
      InlineFeedback.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.get('mediaUnavailable'))));
      return;
    }

    if (media.type == 'audio') {
      try {
        await _serializePlayback(() async {
          if (!mounted || !_runtimeActive) return;
          _playbackStarted = true;
          await _audioPlayer.play(DeviceFileSource(media.contentOrPath));
        });
      } catch (_) {
        if (mounted && _runtimeActive) {
          InlineFeedback.of(context).showSnackBar(
            SnackBar(content: Text(l10n.get('audioPlaybackFailed'))),
          );
        }
        return;
      }
      if (mounted && _runtimeActive) {
        InlineFeedback.of(context).hideCurrentSnackBar();
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            content: Text(l10n.get('playingAudio')),
          ),
        );
      }
    } else if (media.type == 'image') {
      _showImageDialog(media.contentOrPath);
    } else if (media.type == 'file') {
      _showFileDialog(media.contentOrPath);
    } else if (media.type == 'video') {
      _openVideo(media.contentOrPath);
    }
  }

  void _openFocusMode() {
    if (!mounted || !_runtimeActive) return;
    FocusModeSheet.show(context);
  }

  void _openSpacedRepetitionSheet() {
    if (!mounted || !_runtimeActive) return;
    SpacedRepetitionSheet.show(context);
  }

  void _openContextDigest() {
    if (!mounted || !_runtimeActive) return;
    final active = ref.read(remindersProvider);
    final ids = {
      ..._contextDigest.map((r) => r.id),
      ..._contextTriggers.suppressedReminders.map((r) => r.id),
    };
    final suppressed = active
        .where((r) => ids.contains(r.id) && !r.isCompleted)
        .toList();
    if (suppressed.isEmpty) {
      InlineFeedback.of(context).hideCurrentSnackBar();
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).get('noSuppressedTasks')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(AppLocalizations.of(context).get('contextDigestTitle')),
          ),
          body: ContextDigestSheet(digestReminders: suppressed),
        ),
      ),
    );
  }

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
    if (!mounted || !_runtimeActive) return;
    final l10n = AppLocalizations.of(context);
    final reminders = ref.read(remindersProvider);
    final exportService = ref.read(dataExportServiceProvider);
    try {
      final file = await exportService.exportToFile(reminders);
      if (!mounted || !_runtimeActive) return;
      InlineFeedback.of(context).hideCurrentSnackBar();
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          content: Text('${l10n.get('exportSuccess')}${file.path}'),
          action: SnackBarAction(
            label: l10n.get('openExportFolder'),
            onPressed: () {
              if (Platform.isWindows) {
                Process.run('explorer.exe', ['/select,', file.path]);
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted || !_runtimeActive) return;
      InlineFeedback.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.get('exportFailed')}: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _showMultiAgentGoalDialog() {
    if (!mounted || !_runtimeActive) return;
    final l10n = AppLocalizations.of(context);
    final textController = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E2028) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.hub_outlined, color: Colors.indigoAccent),
            const SizedBox(width: 8),
            Text(
              l10n.get('multiAgentTitle'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.get('multiAgentDesc'),
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              autofocus: true,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: '输入您的复杂目标（例如：两周后备战高级技术面试，精通分布式与并发原理）...',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.get('cancel')),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.rocket_launch, size: 16),
            label: const Text('启动三智能体协同'),
            onPressed: () {
              if (!mounted || !_runtimeActive) return;
              final goal = textController.text.trim();
              if (goal.isNotEmpty) {
                Navigator.pop(ctx);
                unawaited(
                  ref
                      .read(homeControllerProvider.notifier)
                      .processWithMultiAgent(goal)
                      .then<void>(
                        (_) {},
                        onError: (Object _, StackTrace __) {
                          // Current-session failures are exposed by HomeState;
                          // canceled old sessions must not become unhandled errors.
                        },
                      ),
                );
                InlineFeedback.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.get('agentProcessing')),
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  bool _openCommandPalette() {
    if (!_runtimeActive || ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final l10n = AppLocalizations.of(context);
    final isImmersive = ref.read(immersiveModeProvider);

    CommandPaletteDialog.show(context, [
      CommandPaletteAction(
        id: 'graph',
        title: l10n.get('knowledgeGraphTitle'),
        subtitle: l10n.get('knowledgeGraphSubtitle'),
        icon: Icons.hub_outlined,
        shortcut: 'G',
        onExecute: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const KnowledgeGraphScreen()),
        ),
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
        onExecute: () async {
          if (!mounted || !_runtimeActive) return;
          try {
            final result = await ref
                .read(remindersProvider.notifier)
                .scanAndApplyDynamicUrgency();
            if (!mounted || !_runtimeActive) return;
            final message =
                '${l10n.get('dynamicPromotedCount')}: ${result.changed}'
                '${result.nativeSyncFailures > 0 ? '\n${l10n.get('reminderNativeSyncFailed')}' : ''}';
            InlineFeedback.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
          } catch (_) {
            if (!mounted || !_runtimeActive) return;
            InlineFeedback.of(context).showSnackBar(
              SnackBar(content: Text(l10n.get('dynamicScanFailed'))),
            );
          }
        },
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
        id: 'dashboard',
        title: l10n.get('dashboardTitle'),
        subtitle: l10n.get('taskCompletion'),
        icon: Icons.bar_chart_rounded,
        shortcut: 'B',
        onExecute: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const DashboardScreen()),
        ),
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
        onExecute: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        ),
      ),
    ]);
    return true;
  }

  void _handleGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final primaryFocus = FocusManager.instance.primaryFocus;
    final focusContext = primaryFocus?.context;
    final isTyping =
        focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null);

    final isCtrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

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

    if (isTyping || isCtrl || HardwareKeyboard.instance.isAltPressed) return;

    if (event.logicalKey == LogicalKeyboardKey.slash) {
      _openSearch();
    } else if (event.logicalKey == LogicalKeyboardKey.keyG) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const KnowledgeGraphScreen()),
      );
    } else if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _openContextDigest();
    } else if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _openFocusMode();
    } else if (event.logicalKey == LogicalKeyboardKey.keyR) {
      _openSpacedRepetitionSheet();
    } else if (event.logicalKey == LogicalKeyboardKey.keyE) {
      _exportCsvData();
    }
  }

  void _openSearch() {
    if (!mounted || !_runtimeActive) return;
    setState(() => _isSearchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isSearchOpen && _runtimeActive) {
        _searchFocus.requestFocus();
      }
    });
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
    final reminders = ref.watch(remindersProvider);
    final l10n = AppLocalizations.of(context);
    final homeState = ref.watch(homeControllerProvider);
    final spacedService = ref.watch(spacedRepetitionServiceProvider);
    final currentProfile = ref.watch(contextProfileProvider);
    final suppressedCount = _contextTriggers.suppressedReminders.length;

    ref.listen<HomeState>(homeControllerProvider, (previous, next) {
      if (_runtimeActive && next.error != null) {
        InlineFeedback.of(context).hideCurrentSnackBar();
        InlineFeedback.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            content: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    next.error!,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        );
        ref.read(homeControllerProvider.notifier).clearError();
      }
    });

    final isProcessing = homeState.isProcessingInBackground;
    final statusColor = isProcessing
        ? const Color(0xFF00E5FF)
        : const Color(0xFF00E676);

    return KeyboardListener(
      focusNode: _shortcutFocus,
      autofocus: true,
      onKeyEvent: _handleGlobalKeyEvent,
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
                    border: InputBorder.none,
                  ),
                  onChanged: _updateSearch,
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    const SizedBox(width: 8),
                    Tooltip(
                      message: isProcessing
                          ? l10n.get('statusBusy')
                          : l10n.get('statusReady'),
                      child: Icon(Icons.circle, size: 7, color: statusColor),
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
                  PopupMenuButton<ContextProfile>(
                    icon: Icon(
                      _getContextProfileIcon(currentProfile),
                      size: 20,
                      color:
                          (currentProfile == ContextProfile.deepWork ||
                              currentProfile == ContextProfile.office)
                          ? Colors.tealAccent
                          : null,
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
                        if (!mounted || !_runtimeActive || !context.mounted) {
                          return;
                        }
                        InlineFeedback.of(context).showSnackBar(
                          SnackBar(
                            content: Text(l10n.get('reminderUpdateFailed')),
                          ),
                        );
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: ContextProfile.general,
                        child: Row(
                          children: [
                            const Icon(Icons.tune_rounded, size: 18),
                            const SizedBox(width: 8),
                            Text(l10n.get('profileGeneral')),
                            if (currentProfile == ContextProfile.general) ...[
                              const Spacer(),
                              const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.teal,
                              ),
                            ],
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: ContextProfile.office,
                        child: Row(
                          children: [
                            const Icon(Icons.apartment_rounded, size: 18),
                            const SizedBox(width: 8),
                            Text(l10n.get('profileOffice')),
                            if (currentProfile == ContextProfile.office) ...[
                              const Spacer(),
                              const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.teal,
                              ),
                            ],
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: ContextProfile.deepWork,
                        child: Row(
                          children: [
                            const Icon(Icons.psychology_rounded, size: 18),
                            const SizedBox(width: 8),
                            Text(l10n.get('profileDeepWork')),
                            if (currentProfile == ContextProfile.deepWork) ...[
                              const Spacer(),
                              const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.teal,
                              ),
                            ],
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: ContextProfile.home,
                        child: Row(
                          children: [
                            const Icon(Icons.home_rounded, size: 18),
                            const SizedBox(width: 8),
                            Text(l10n.get('profileHome')),
                            if (currentProfile == ContextProfile.home) ...[
                              const Spacer(),
                              const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.teal,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
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
                    child: IconButton(
                      icon: Icon(
                        ref.watch(immersiveModeProvider)
                            ? Icons.shield_rounded
                            : Icons.more_horiz_rounded,
                      ),
                      tooltip: ref.watch(immersiveModeProvider)
                          ? '${l10n.get('moreTools')} / ${l10n.get('focusOn')}'
                          : l10n.get('moreTools'),
                      onPressed: _openCommandPalette,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: l10n.get('settings'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
        ),
        body: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                ValueListenableBuilder<DateTime>(
                  valueListenable: _noticeClock,
                  builder: (context, _, _) {
                    final now = DateTime.now();
                    return ReminderNoticePanel(
                      reminders: _visibleNotices(reminders, now),
                      now: now,
                      busyIds: _noticeOperations,
                      onDismiss: _dismissNotice,
                      onSnooze: (r) => _actOnNotice(r, snooze: true),
                      onComplete: (r) => _actOnNotice(r, snooze: false),
                    );
                  },
                ),
                if (_contextDigest.any(
                  (item) =>
                      reminders.any((r) => r.id == item.id && !r.isCompleted),
                ))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _openContextDigest,
                      icon: const Icon(Icons.summarize_outlined, size: 18),
                      label: Text(l10n.get('contextDigestTitle')),
                    ),
                  ),
                Expanded(
                  child: _isSearchOpen
                      ? TaskSearchPanel(
                          query: _searchQuery,
                          onClearQuery: _clearSearch,
                          onPlayMedia: _playMedia,
                        )
                      : TaskBoard(
                          reminders: reminders,
                          onPlayMedia: _playMedia,
                        ),
                ),
                const InputBottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
