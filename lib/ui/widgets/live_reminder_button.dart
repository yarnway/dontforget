import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/notification_payload.dart';
import '../../providers/providers.dart';
import '../../services/live_reminder_service.dart';

class LiveReminderCopy {
  static String text(String language, String key) {
    const values = {
      'zh': {
        'start': '在灵动岛显示',
        'stop': '结束实时活动',
        'hint': '显示未来 8 小时内的提醒倒计时；普通系统通知继续保留。',
        'save': '先保存修改，再更新实时活动。',
        'disabled': '系统已关闭实时活动，可在 iOS 设置中为本应用开启。',
        'unsupported': '需要 iOS 16.2 或更新版本。支持的设备显示灵动岛，其他设备显示锁屏卡片。',
        'unavailable': '暂时无法读取实时活动状态，请重试。',
        'failed': '系统未能更新实时活动，原提醒仍保留。',
        'retry': '重试',
        'active': '已在实时活动中显示',
      },
      'ja': {
        'start': 'ライブアクティビティを表示',
        'stop': '表示を終了',
        'hint': '8時間以内の予定を表示します。通常の通知は継続します。',
        'save': '変更を保存してから表示を更新してください。',
        'disabled': 'ライブアクティビティは無効です。iOS設定で有効にできます。',
        'unsupported':
            'iOS 16.2以降が必要です。対応機種ではDynamic Island、それ以外ではロック画面に表示します。',
        'unavailable': '表示状態を取得できません。再試行してください。',
        'failed': '更新できませんでした。通常のリマインダーは保持されています。',
        'retry': '再試行',
        'active': 'ライブアクティビティに表示中',
      },
      'en': {
        'start': 'Show Live Activity',
        'stop': 'End Live Activity',
        'hint':
            'Count down to a reminder within 8 hours. Regular notifications stay enabled.',
        'save': 'Save your edits before updating the Live Activity.',
        'disabled':
            'Live Activities are disabled for this app in iOS Settings.',
        'unsupported':
            'Requires iOS 16.2 or later. Uses Dynamic Island on supported devices and the Lock Screen on others.',
        'unavailable': 'Live Activity status is unavailable. Please retry.',
        'failed':
            'The system could not update the Live Activity. Your reminder is unchanged.',
        'retry': 'Retry',
        'active': 'Showing in Live Activity',
      },
    };
    return (values[language] ?? values['en']!)[key]!;
  }
}

class LiveReminderButton extends ConsumerStatefulWidget {
  const LiveReminderButton({
    super.key,
    required this.taskId,
    required this.hasUnsavedChanges,
  });
  final String taskId;
  final bool hasUnsavedChanges;
  @override
  ConsumerState<LiveReminderButton> createState() => _LiveReminderButtonState();
}

class _LiveReminderButtonState extends ConsumerState<LiveReminderButton> {
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      Future.microtask(() {
        if (mounted) ref.read(liveReminderServiceProvider).refresh();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return const SizedBox.shrink();
    }
    final service = ref.watch(liveReminderServiceProvider);
    final reminders = ref.watch(remindersProvider);
    final task = reminders
        .where((task) => task.id == widget.taskId)
        .firstOrNull;
    final epoch = ref.read(notificationServiceProvider).datasetEpoch;
    final language = Localizations.localeOf(context).languageCode;
    String copy(String key) => LiveReminderCopy.text(language, key);
    final payload = NotificationPayload.tryParse(service.status.payload);
    final active =
        task != null &&
        epoch != null &&
        payload?.matches(task, currentDatasetEpoch: epoch) == true;
    final eligible =
        task != null &&
        epoch != null &&
        LiveReminderService.eligible(task, DateTime.now());
    if (!eligible && !active) return const SizedBox.shrink();
    final availability = service.status.availability;
    final message = _failed
        ? copy('failed')
        : widget.hasUnsavedChanges
        ? copy('save')
        : switch (availability) {
            LiveReminderAvailability.available => copy(
              active ? 'active' : 'hint',
            ),
            LiveReminderAvailability.disabled => copy('disabled'),
            LiveReminderAvailability.unsupported => copy('unsupported'),
            LiveReminderAvailability.unavailable => copy('unavailable'),
          };
    Future<void> act(Future<void> Function() operation) async {
      setState(() {
        _busy = true;
        _failed = false;
      });
      try {
        await operation();
      } catch (_) {
        if (mounted) setState(() => _failed = true);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              if (availability == LiveReminderAvailability.available)
                OutlinedButton.icon(
                  onPressed: _busy || (widget.hasUnsavedChanges && !active)
                      ? null
                      : () => act(
                          () => active
                              ? service.stop()
                              : service.start(task, epoch, language),
                        ),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          active
                              ? Icons.stop_circle_outlined
                              : Icons.notifications_active_outlined,
                        ),
                  label: Text(copy(active ? 'stop' : 'start')),
                )
              else
                TextButton(
                  onPressed: _busy ? null : () => act(service.refresh),
                  child: Text(copy('retry')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
