import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../models/reminder.dart';
import '../../providers/providers.dart';
import '../../providers/home_controller.dart';
import '../../services/notification_service.dart';
import 'settings_screen.dart';
import 'dashboard_screen.dart';
import '../widgets/quadrant_view.dart';
import '../widgets/input_bottom_bar.dart';
import '../widgets/ai_background_effect.dart';
import '../../l10n/app_localizations.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with SingleTickerProviderStateMixin {
  final _audioPlayer = AudioPlayer();
  Timer? _heartbeatTimer;
  StreamSubscription<Reminder>? _dueSubscription;
  final Set<String> _promptedReminderIds = {};
  late AnimationController _indicatorAnimController;

  @override
  void initState() {
    super.initState();

    _indicatorAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    // Listen to notification service broadcast stream
    _dueSubscription = NotificationService().onReminderDue.listen((reminder) {
      _showDueReminderDialog(reminder);
    });

    // Periodic heartbeat check (every 10 seconds) to ensure reminders are never missed
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkDueReminders();
    });
  }

  @override
  void dispose() {
    _indicatorAnimController.dispose();
    _heartbeatTimer?.cancel();
    _dueSubscription?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _checkDueReminders() {
    final reminders = ref.read(remindersProvider);
    final now = DateTime.now();

    for (final r in reminders) {
      if (!r.isCompleted && r.triggerTime != null) {
        // If due and within the last 15 minutes and not yet prompted
        if (r.triggerTime!.isBefore(now) &&
            r.triggerTime!.isAfter(now.subtract(const Duration(minutes: 15))) &&
            !_promptedReminderIds.contains(r.id)) {
          _promptedReminderIds.add(r.id);
          NotificationService().fireReminderNow(r);
        }
      }
    }
  }

  void _showDueReminderDialog(Reminder reminder) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
        ),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        title: Row(
          children: [
            Icon(Icons.alarm_on_rounded, color: Theme.of(context).colorScheme.primary, size: 24),
            const SizedBox(width: 8),
            Text(
              l10n.get('dueReminder'),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reminder.taskTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            if (reminder.taskSummary != null && reminder.taskSummary!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                reminder.taskSummary!,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.access_time, size: 14, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text(
                  reminder.triggerTime != null
                      ? reminder.triggerTime.toString().substring(0, 16)
                      : l10n.get('now'),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              // Snooze 5 minutes
              final snoozed = reminder.copyWith(
                triggerTime: DateTime.now().add(const Duration(minutes: 5)),
              );
              ref.read(remindersProvider.notifier).updateReminder(snoozed);
              NotificationService().scheduleReminder(snoozed);
              _promptedReminderIds.remove(reminder.id);
              Navigator.of(dialogCtx).pop();

              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 3),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  content: Text(l10n.get('snoozeSuccess')),
                ),
              );
            },
            child: Text(l10n.get('snooze5Min'), style: const TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(l10n.get('iKnow'), style: const TextStyle(fontSize: 13)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              if (reminder.isRecurring) {
                final nextTime = reminder.getNextOccurrence();
                if (nextTime != null) {
                  final nextTask = reminder.copyWith(triggerTime: nextTime, isCompleted: false);
                  ref.read(remindersProvider.notifier).updateReminder(nextTask);
                  NotificationService().scheduleReminder(nextTask);
                  _promptedReminderIds.remove(reminder.id);

                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(seconds: 3),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      content: Text('${l10n.get('periodicNext')}${nextTime.toString().substring(0, 16)}'),
                    ),
                  );
                  return;
                }
              }

              final completed = reminder.copyWith(isCompleted: true);
              ref.read(remindersProvider.notifier).updateReminder(completed);
              NotificationService().cancelReminder(reminder.id);

              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 3),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  content: Text(l10n.get('taskCompleted')),
                ),
              );
            },
            child: Text(l10n.get('markDone'), style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  void _confirmClearCompleted() {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final completedCount = ref.read(remindersProvider).where((r) => r.isCompleted).length;
    if (completedCount == 0) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
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
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
        ),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        title: Row(
          children: [
            const Icon(Icons.cleaning_services_outlined, color: Colors.redAccent, size: 22),
            const SizedBox(width: 8),
            Text(l10n.get('clearCompletedTitle'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ],
        ),
        content: Text(
          '${l10n.get('clearCompletedConfirm')} ($completedCount)',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.get('cancel'), style: const TextStyle(fontSize: 13)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final count = await ref.read(remindersProvider.notifier).clearCompletedReminders();
              if (mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 3),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    content: Text('${l10n.get('clearedCompletedSuccess')} ($count)'),
                  ),
                );
              }
            },
            child: Text(l10n.get('confirm'), style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  void _clearAllNotices() {
    final l10n = AppLocalizations.of(context);
    ref.read(homeControllerProvider.notifier).clearError();
    _promptedReminderIds.clear();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text(l10n.get('noticesCleared')),
      ),
    );
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
                      icon: const Icon(Icons.close, color: Colors.white, size: 16),
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
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
        ),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        title: Row(
          children: [
            const Icon(Icons.description_outlined, color: Colors.amber, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileName,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
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
              Text('${l10n.get('localPath')}: $filePath', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const Divider(height: 18),
              if (preview.isNotEmpty) ...[
                Text('${l10n.get('contentPreview')}:', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                  ),
                  child: SingleChildScrollView(
                    child: Text(preview, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                  ),
                ),
              ] else
                Text(l10n.get('binaryFileNotice'), style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.get('close'), style: const TextStyle(fontSize: 13)),
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
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text('${l10n.get('openedVideo')}: $fileName'),
      ),
    );
  }

  void _playMedia(String recordId) async {
    final l10n = AppLocalizations.of(context);
    final records = ref.read(mediaRecordsProvider);
    final media = records.where((m) => m.id == recordId).firstOrNull;
    if (media == null) return;

    if (media.type == 'audio') {
      await _audioPlayer.play(DeviceFileSource(media.contentOrPath));
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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

  @override
  Widget build(BuildContext context) {
    final reminders = ref.watch(remindersProvider);
    final l10n = AppLocalizations.of(context);
    final homeState = ref.watch(homeControllerProvider);

    ref.listen<HomeState>(homeControllerProvider, (previous, next) {
      if (next.error != null) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            content: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(next.error!, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ),
        );
        ref.read(homeControllerProvider.notifier).clearError();
      }
    });

    final isProcessing = homeState.isProcessingInBackground;
    final statusColor = isProcessing ? const Color(0xFF00E5FF) : const Color(0xFF00E676);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.get('appTitle'),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17, letterSpacing: 0.5),
            ),
            const SizedBox(width: 8),
            // Micro Status Indicator Light with Breathing Animation
            AnimatedBuilder(
              animation: _indicatorAnimController,
              builder: (context, child) {
                final glow = _indicatorAnimController.value;
                return Tooltip(
                  message: isProcessing ? l10n.get('statusBusy') : l10n.get('statusReady'),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusColor,
                      boxShadow: [
                        BoxShadow(
                          color: statusColor.withValues(alpha: 0.5 + 0.4 * glow),
                          blurRadius: 4 + 4 * glow,
                          spreadRadius: 1 + 1 * glow,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_off_outlined, size: 20),
            tooltip: l10n.get('clearAllNotices'),
            splashRadius: 18,
            onPressed: _clearAllNotices,
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined, size: 20),
            tooltip: l10n.get('clearCompleted'),
            splashRadius: 18,
            onPressed: _confirmClearCompleted,
          ),
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded, size: 20),
            tooltip: l10n.get('dashboardTitle'),
            splashRadius: 18,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DashboardScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: l10n.get('settings'),
            splashRadius: 18,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: AiBackgroundEffect(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
                  child: Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: QuadrantView(
                                level: 1,
                                titleIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.local_fire_department_rounded, color: Colors.red.shade400, size: 18),
                                    const SizedBox(width: 4),
                                    Text(
                                      l10n.get('q1'),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.red.shade400,
                                      ),
                                    ),
                                  ],
                                ),
                                allReminders: reminders,
                                bgColor: Colors.red.shade400,
                                onPlayMedia: _playMedia,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: QuadrantView(
                                level: 2,
                                titleIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.star_rounded, color: Colors.orange.shade400, size: 18),
                                    const SizedBox(width: 4),
                                    Text(
                                      l10n.get('q2'),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.orange.shade400,
                                      ),
                                    ),
                                  ],
                                ),
                                allReminders: reminders,
                                bgColor: Colors.orange.shade400,
                                onPlayMedia: _playMedia,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: QuadrantView(
                                level: 3,
                                titleIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.bolt_rounded, color: Colors.blue.shade400, size: 18),
                                    const SizedBox(width: 4),
                                    Text(
                                      l10n.get('q3'),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.blue.shade400,
                                      ),
                                    ),
                                  ],
                                ),
                                allReminders: reminders,
                                bgColor: Colors.blue.shade400,
                                onPlayMedia: _playMedia,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: QuadrantView(
                                level: 4,
                                titleIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.coffee_rounded, color: Colors.green.shade400, size: 18),
                                    const SizedBox(width: 4),
                                    Text(
                                      l10n.get('q4'),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.green.shade400,
                                      ),
                                    ),
                                  ],
                                ),
                                allReminders: reminders,
                                bgColor: Colors.green.shade400,
                                onPlayMedia: _playMedia,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const InputBottomBar(),
            ],
          ),
        ),
      ),
    );
  }
}
