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
import '../../l10n/app_localizations.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _audioPlayer = AudioPlayer();
  Timer? _heartbeatTimer;
  StreamSubscription<Reminder>? _dueSubscription;
  final Set<String> _promptedReminderIds = {};

  @override
  void initState() {
    super.initState();

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

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.alarm_on_rounded, color: Theme.of(context).colorScheme.primary, size: 28),
            const SizedBox(width: 8),
            const Text('待办提醒到期', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reminder.taskTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (reminder.taskSummary != null && reminder.taskSummary!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                reminder.taskSummary!,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
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
                      : '现在',
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
                const SnackBar(
                  duration: Duration(seconds: 4),
                  behavior: SnackBarBehavior.floating,
                  content: Text('已推迟 5 分钟后再次提醒'),
                ),
              );
            },
            child: const Text('稍后 5 分钟提醒'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('我知道了'),
          ),
          FilledButton(
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
                      duration: const Duration(seconds: 4),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      content: Text('已完成本次周期任务，下一次已自动排期至: ${nextTime.toString().substring(0, 16)}'),
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
                const SnackBar(
                  duration: Duration(seconds: 4),
                  behavior: SnackBarBehavior.floating,
                  content: Text('事项已标为完成'),
                ),
              );
            },
            child: const Text('标为完成'),
          ),
        ],
      ),
    );
  }

  void _confirmClearCompleted() {
    final completedCount = ref.read(remindersProvider).where((r) => r.isCompleted).length;
    if (completedCount == 0) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          content: const Text('当前没有已完成的历史事项需要清理'),
          action: SnackBarAction(
            label: '✕',
            textColor: Colors.white,
            onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
          ),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.cleaning_services_outlined, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text('清理已完成事项'),
          ],
        ),
        content: Text('确定要清除所有已完成的 $completedCount 条历史待办事项吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final count = await ref.read(remindersProvider.notifier).clearCompletedReminders();
              if (mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 4),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    content: Text('已成功清除 $count 条已完成历史事项'),
                    action: SnackBarAction(
                      label: '✕',
                      textColor: Colors.white,
                      onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
                    ),
                  ),
                );
              }
            },
            child: const Text('确定清理'),
          ),
        ],
      ),
    );
  }

  void _showImageDialog(String filePath) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('无法载入图片'),
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: CircleAvatar(
                    backgroundColor: Colors.black54,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.description_outlined, color: Colors.amber, size: 26),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
              Text('本地路径: $filePath', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const Divider(height: 20),
              if (preview.isNotEmpty) ...[
                const Text('内容预览:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(preview, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                  ),
                ),
              ] else
                const Text('该文件为二进制文件，已作为附件关联至本任务。', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _openVideo(String filePath) {
    final fileName = filePath.split(Platform.pathSeparator).last;
    if (Platform.isWindows) {
      try {
        Process.run('cmd', ['/c', 'start', '', filePath]);
      } catch (_) {}
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        content: Text('已调用系统播放器打开视频: $fileName'),
        action: SnackBarAction(
          label: '✕',
          textColor: Colors.white,
          onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ),
    );
  }

  void _playMedia(String recordId) async {
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
            content: const Text('正在播放原声录音...'),
            action: SnackBarAction(
              label: '✕',
              textColor: Colors.white,
              onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
            ),
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

    ref.listen<HomeState>(homeControllerProvider, (previous, next) {
      if (next.error != null) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            content: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(next.error!)),
              ],
            ),
            action: SnackBarAction(
              label: '✕',
              textColor: Colors.white,
              onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
            ),
          ),
        );
        ref.read(homeControllerProvider.notifier).clearError();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.get('appTitle'), style: const TextStyle(fontWeight: FontWeight.w600)),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: '清理已完成事项',
            onPressed: _confirmClearCompleted,
          ),
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded),
            tooltip: '数据看板',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DashboardScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '系统设置',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surface.withOpacity(0.9),
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 6.0),
                  child: Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: QuadrantView(
                                level: 1,
                                titleIcon: Icon(Icons.local_fire_department_rounded, color: Colors.red.shade400, size: 26),
                                allReminders: reminders,
                                bgColor: const Color(0xFFFFEBEE),
                                onPlayMedia: _playMedia,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: QuadrantView(
                                level: 2,
                                titleIcon: Icon(Icons.star_rounded, color: Colors.orange.shade400, size: 26),
                                allReminders: reminders,
                                bgColor: const Color(0xFFFFF3E0),
                                onPlayMedia: _playMedia,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: QuadrantView(
                                level: 3,
                                titleIcon: Icon(Icons.bolt_rounded, color: Colors.blue.shade400, size: 26),
                                allReminders: reminders,
                                bgColor: const Color(0xFFE3F2FD),
                                onPlayMedia: _playMedia,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: QuadrantView(
                                level: 4,
                                titleIcon: Icon(Icons.coffee_rounded, color: Colors.green.shade400, size: 26),
                                allReminders: reminders,
                                bgColor: const Color(0xFFE8F5E9),
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
