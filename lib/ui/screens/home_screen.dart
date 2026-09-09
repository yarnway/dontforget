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
import 'settings_screen.dart';
import 'dashboard_screen.dart';
import '../widgets/quadrant_view.dart';
import '../widgets/task_card.dart';
import '../widgets/input_bottom_bar.dart';
import '../widgets/ai_background_effect.dart';
import '../widgets/command_palette_dialog.dart';
import '../widgets/spaced_repetition_sheet.dart';
import '../widgets/context_digest_sheet.dart';
import '../../services/context_trigger_service.dart';
import 'knowledge_graph_screen.dart';
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
  StreamSubscription<List<Reminder>>? _catchUpDigestSubscription;
  StreamSubscription<List<Reminder>>? _suppressedSubscription;
  final Set<String> _promptedReminderIds = {};
  late AnimationController _indicatorAnimController;
  bool _isSearchOpen = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';

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

    // 监听情境事后摘要通知并弹出聚合抽屉
    _catchUpDigestSubscription =
        ContextTriggerService().onCatchUpDigestReady.listen((digestList) {
      if (!mounted || digestList.isEmpty) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ContextDigestSheet(digestReminders: digestList),
      );
      if (Platform.isWindows) {
        NotificationService().showWindowsToast(
          '情境专注时段已结束',
          '已为您自动聚合 ${digestList.length} 项次要事务待处理',
        );
      }
    });

    // 监听拦截队列更新以便即时刷新情境徽标
    _suppressedSubscription =
        ContextTriggerService().onSuppressedUpdated.listen((_) {
      if (mounted) setState(() {});
    });

    // 启动时触发 Wi-Fi 嗅探与情境感知
    ContextTriggerService().detectCurrentWifiSsid();

    // Periodic heartbeat check (every 10 seconds) to ensure reminders are never missed
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkDueReminders();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _indicatorAnimController.dispose();
    _heartbeatTimer?.cancel();
    _dueSubscription?.cancel();
    _catchUpDigestSubscription?.cancel();
    _suppressedSubscription?.cancel();
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

    // 情境感知触发器检测 (检测 Wi-Fi SSID 接入)
    ContextTriggerService().detectCurrentWifiSsid().then((ssid) {
      if (ssid != null && mounted) {
        final matched = ContextTriggerService().evaluateContextTriggers(reminders, ssid: ssid);
        for (final m in matched) {
          NotificationService().showWindowsToast('📍 情境感知提醒 [已连接 $ssid]', m.taskTitle);
        }
      }
    });

    // 动态跃迁周期扫描
    ref.read(remindersProvider.notifier).scanAndApplyDynamicUrgency();
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

  void _toggleImmersiveMode() {
    final notifier = ref.read(immersiveModeProvider.notifier);
    notifier.toggle();
    final isActive = ref.read(immersiveModeProvider);
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Row(
          children: [
            Icon(
              isActive ? Icons.shield : Icons.shield_outlined,
              color: isActive ? Colors.amberAccent : Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isActive
                    ? l10n.get('immersiveActive')
                    : l10n.get('immersiveDisabled'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSpacedRepetitionSheet() {
    SpacedRepetitionSheet.show(context);
  }

  void _openContextDigest() {
    final suppressed = ContextTriggerService().suppressedReminders;
    if (suppressed.isEmpty) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).get('noSuppressedTasks')),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContextDigestSheet(digestReminders: suppressed),
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
    final l10n = AppLocalizations.of(context);
    final reminders = ref.read(remindersProvider);
    final exportService = ref.read(dataExportServiceProvider);
    try {
      final file = await exportService.exportToFile(reminders);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.get('exportFailed')}: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _showMultiAgentGoalDialog() {
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
            Text(l10n.get('multiAgentTitle'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.get('multiAgentDesc'),
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              autofocus: true,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: '输入您的复杂目标（例如：两周后备战高级技术面试，精通分布式与并发原理）...',
                hintStyle: TextStyle(fontSize: 13, color: isDark ? Colors.white38 : Colors.black38),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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
              final goal = textController.text.trim();
              if (goal.isNotEmpty) {
                Navigator.pop(ctx);
                ref.read(homeControllerProvider.notifier).processWithMultiAgent(goal);
                ScaffoldMessenger.of(context).showSnackBar(
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

  void _openCommandPalette() {
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
          final count = await ref.read(remindersProvider.notifier).scanAndApplyDynamicUrgency();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${l10n.get('dynamicPromotedCount')}: $count'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        },
      ),
      CommandPaletteAction(
        id: 'focus',
        title: isImmersive ? l10n.get('immersiveDisabled') : l10n.get('immersiveActive'),
        subtitle: l10n.get('immersiveModeDesc'),
        icon: isImmersive ? Icons.shield : Icons.shield_outlined,
        shortcut: 'F',
        onExecute: _toggleImmersiveMode,
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
        onExecute: () => setState(() => _isSearchOpen = true),
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
  }

  void _handleGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final primaryFocus = FocusManager.instance.primaryFocus;
    final isTyping = primaryFocus != null && primaryFocus.context?.widget is EditableText;

    final isCtrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

    // Ctrl+K -> Command Palette
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyK) {
      _openCommandPalette();
      return;
    }

    if (isTyping) return;

    if (event.logicalKey == LogicalKeyboardKey.slash) {
      setState(() => _isSearchOpen = true);
    } else if (event.logicalKey == LogicalKeyboardKey.keyG) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const KnowledgeGraphScreen()),
      );
    } else if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _openContextDigest();
    } else if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _toggleImmersiveMode();
    } else if (event.logicalKey == LogicalKeyboardKey.keyR) {
      _openSpacedRepetitionSheet();
    } else if (event.logicalKey == LogicalKeyboardKey.keyE) {
      _exportCsvData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reminders = ref.watch(remindersProvider);
    final l10n = AppLocalizations.of(context);
    final homeState = ref.watch(homeControllerProvider);
    final isImmersiveActive = ref.watch(immersiveModeProvider);
    final spacedService = ref.watch(spacedRepetitionServiceProvider);
    final dueCardsCount = spacedService.getDueCards(reminders).length;
    final currentProfile = ref.watch(contextProfileProvider);
    final suppressedCount = ContextTriggerService().suppressedReminders.length;

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

    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: _handleGlobalKeyEvent,
      child: Scaffold(
        extendBodyBehindAppBar: true,
      appBar: AppBar(
        leading: _isSearchOpen
            ? IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: () => setState(() {
                  _isSearchOpen = false;
                  _searchController.clear();
                  _searchQuery = '';
                }),
              )
            : null,
        title: _isSearchOpen
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: l10n.get('searchHint'),
                  hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                  border: InputBorder.none,
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              )
            : Row(
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
        actions: _isSearchOpen
            ? [
                if (_searchQuery.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => setState(() {
                      _searchController.clear();
                      _searchQuery = '';
                    }),
                  ),
                const SizedBox(width: 6),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.terminal, size: 20),
                  tooltip: '${l10n.get('commandPalette')} (Ctrl+K)',
                  splashRadius: 18,
                  onPressed: _openCommandPalette,
                ),
                IconButton(
                  icon: Icon(
                    isImmersiveActive ? Icons.shield : Icons.shield_outlined,
                    size: 20,
                    color: isImmersiveActive ? Colors.amberAccent : null,
                  ),
                  tooltip: isImmersiveActive
                      ? l10n.get('immersiveActive')
                      : l10n.get('immersiveMode'),
                  splashRadius: 18,
                  onPressed: _toggleImmersiveMode,
                ),
                IconButton(
                  icon: const Icon(Icons.hub_outlined, size: 20),
                  tooltip: '${l10n.get('knowledgeGraphTitle')} (G)',
                  splashRadius: 18,
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const KnowledgeGraphScreen()),
                    );
                  },
                ),
                PopupMenuButton<ContextProfile>(
                  icon: Icon(
                    _getContextProfileIcon(currentProfile),
                    size: 20,
                    color: (currentProfile == ContextProfile.deepWork || currentProfile == ContextProfile.office)
                        ? Colors.tealAccent
                        : null,
                  ),
                  tooltip: l10n.get('contextProfileSwitch'),
                  splashRadius: 18,
                  onSelected: (profile) {
                    ref.read(contextProfileProvider.notifier).setProfile(profile);
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
                            const Icon(Icons.check, size: 16, color: Colors.teal),
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
                            const Icon(Icons.check, size: 16, color: Colors.teal),
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
                            const Icon(Icons.check, size: 16, color: Colors.teal),
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
                            const Icon(Icons.check, size: 16, color: Colors.teal),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                Badge(
                  isLabelVisible: suppressedCount > 0,
                  label: Text(
                    suppressedCount.toString(),
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  backgroundColor: Colors.tealAccent.shade700,
                  textColor: Colors.white,
                  offset: const Offset(-4, 4),
                  child: IconButton(
                    icon: const Icon(Icons.mark_chat_unread_outlined, size: 20),
                    tooltip: '${l10n.get('contextDigestTitle')} ($suppressedCount) (C)',
                    splashRadius: 18,
                    onPressed: _openContextDigest,
                  ),
                ),
                Badge(
                  isLabelVisible: dueCardsCount > 0,
                  label: Text(
                    dueCardsCount.toString(),
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                  backgroundColor: Colors.amber,
                  textColor: Colors.black87,
                  offset: const Offset(-4, 4),
                  child: IconButton(
                    icon: const Icon(Icons.school_outlined, size: 20),
                    tooltip: '${l10n.get('spacedRepetitionTitle')} ($dueCardsCount)',
                    splashRadius: 18,
                    onPressed: _openSpacedRepetitionSheet,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.table_chart_outlined, size: 20),
                  tooltip: l10n.get('exportExcel'),
                  splashRadius: 18,
                  onPressed: _exportCsvData,
                ),
                IconButton(
                  icon: const Icon(Icons.search_rounded, size: 20),
                  tooltip: l10n.get('searchHint'),
                  splashRadius: 18,
                  onPressed: () => setState(() => _isSearchOpen = true),
                ),
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
                child: _isSearchOpen && _searchQuery.trim().isNotEmpty
                    ? Builder(
                        builder: (context) {
                          final q = _searchQuery.trim().toLowerCase();
                          final searchResults = reminders.where((r) {
                            if (r.taskTitle.toLowerCase().contains(q)) return true;
                            if ((r.taskSummary ?? '').toLowerCase().contains(q)) return true;
                            if (r.getSubTasksList().any((sub) => sub.toLowerCase().contains(q))) return true;
                            return false;
                          }).toList();

                          if (searchResults.isEmpty) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.search_off_rounded, size: 48, color: Colors.grey.shade400),
                                  const SizedBox(height: 12),
                                  Text(
                                    l10n.get('noSearchResult'),
                                    style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                                  ),
                                ],
                              ),
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                child: Text(
                                  '${l10n.get('searchResults')} (${searchResults.length})',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigoAccent),
                                ),
                              ),
                              Expanded(
                                child: ListView.builder(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  itemCount: searchResults.length,
                                  itemBuilder: (context, index) {
                                    final task = searchResults[index];
                                    return TaskCard(
                                      task: task,
                                      onPlayMedia: () {
                                        if (task.recordId != null) _playMedia(task.recordId!);
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
                        child: Column(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: QuadrantView(
                                      level: 1,
                                      titleIcon: Icon(Icons.local_fire_department_rounded, color: Colors.red.shade400, size: 20),
                                      allReminders: reminders,
                                      bgColor: Colors.red.shade400,
                                      onPlayMedia: _playMedia,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: QuadrantView(
                                      level: 2,
                                      titleIcon: Icon(Icons.star_rounded, color: Colors.orange.shade400, size: 20),
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
                                      titleIcon: Icon(Icons.bolt_rounded, color: Colors.blue.shade400, size: 20),
                                      allReminders: reminders,
                                      bgColor: Colors.blue.shade400,
                                      onPlayMedia: _playMedia,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: QuadrantView(
                                      level: 4,
                                      titleIcon: Icon(Icons.coffee_rounded, color: Colors.green.shade400, size: 20),
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
    ));
  }
}
