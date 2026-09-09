import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:window_manager/window_manager.dart';
import '../models/reminder.dart';
import 'context_trigger_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final Map<String, Timer> _activeTimers = {};
  final StreamController<Reminder> _reminderDueController =
      StreamController<Reminder>.broadcast();

  /// 沉浸备战专注模式开关（开启后底层静音拦截 Q3 和 Q4 通知）
  bool isImmersiveModeActive = false;

  Stream<Reminder> get onReminderDue => _reminderDueController.stream;

  Future<void> init() async {
    try {
      tz.initializeTimeZones();

      if (!Platform.isWindows && !Platform.isLinux) {
        const AndroidInitializationSettings initializationSettingsAndroid =
            AndroidInitializationSettings('@mipmap/ic_launcher');

        const DarwinInitializationSettings initializationSettingsDarwin =
            DarwinInitializationSettings(
          requestSoundPermission: true,
          requestBadgePermission: true,
          requestAlertPermission: true,
        );

        const InitializationSettings initializationSettings = InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsDarwin,
          macOS: initializationSettingsDarwin,
        );

        await flutterLocalNotificationsPlugin.initialize(
          initializationSettings,
          onDidReceiveNotificationResponse: (details) {
            // Handle notification tap
          },
        );
      }
    } catch (e) {
      debugPrint('Notification init error: $e');
    }
  }

  Future<void> scheduleReminder(Reminder reminder) async {
    // Cancel existing timer for this reminder if any
    cancelReminder(reminder.id);

    if (reminder.triggerTime == null || reminder.isCompleted) return;

    final now = DateTime.now();
    final difference = reminder.triggerTime!.difference(now);

    // If already overdue
    if (difference.isNegative) {
      // If it passed within the last 30 seconds, fire it immediately
      if (difference.inSeconds > -30) {
        fireReminderNow(reminder);
      }
      return;
    }

    // In-process timer for all platforms (vital on Windows)
    _activeTimers[reminder.id] = Timer(difference, () {
      fireReminderNow(reminder);
    });

    // Native mobile/Darwin scheduling if supported
    if (!Platform.isWindows && !Platform.isLinux) {
      try {
        String channelId;
        String channelName;
        String channelDescription;
        Priority priority;
        Importance importance;
        bool enableVibration = false;
        bool playSound = false;

        if (reminder.quadrantLevel == 1) {
          channelId = 'q1_channel';
          channelName = 'Urgent & Important';
          channelDescription = 'High priority alerts with sound and vibration';
          priority = Priority.high;
          importance = Importance.max;
          enableVibration = true;
          playSound = true;
        } else if (reminder.quadrantLevel == 2) {
          channelId = 'q2_channel';
          channelName = 'Important';
          channelDescription = 'Standard priority alerts';
          priority = Priority.defaultPriority;
          importance = Importance.defaultImportance;
          enableVibration = true;
          playSound = true;
        } else {
          channelId = 'q34_channel';
          channelName = 'General Reminders';
          channelDescription = 'Low priority silent alerts';
          priority = Priority.low;
          importance = Importance.low;
          enableVibration = false;
          playSound = false;
        }

        final androidPlatformChannelSpecifics = AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: importance,
          priority: priority,
          enableVibration: enableVibration,
          playSound: playSound,
          fullScreenIntent: reminder.quadrantLevel == 1,
        );

        final platformChannelSpecifics = NotificationDetails(
          android: androidPlatformChannelSpecifics,
          iOS: DarwinNotificationDetails(
            presentSound: playSound,
            presentAlert: true,
            presentBadge: true,
            interruptionLevel: reminder.quadrantLevel == 1
                ? InterruptionLevel.timeSensitive
                : InterruptionLevel.active,
          ),
          macOS: const DarwinNotificationDetails(),
        );

        await flutterLocalNotificationsPlugin.zonedSchedule(
          reminder.id.hashCode,
          reminder.taskTitle,
          reminder.taskSummary ?? 'You have a scheduled task',
          tz.TZDateTime.from(reminder.triggerTime!, tz.local),
          platformChannelSpecifics,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      } catch (e) {
        debugPrint('Mobile zonedSchedule error: $e');
      }
    }
  }

  Future<void> cancelReminder(String id) async {
    _activeTimers[id]?.cancel();
    _activeTimers.remove(id);

    if (!Platform.isWindows && !Platform.isLinux) {
      try {
        await flutterLocalNotificationsPlugin.cancel(id.hashCode);
      } catch (_) {}
    }
  }

  Future<void> fireReminderNow(Reminder reminder) async {
    _activeTimers.remove(reminder.id);

    // 高压场景专注模式：拦截并静音所有“紧急不重要 (Q3)”和“不重要不紧急 (Q4)”的通知
    if (isImmersiveModeActive && (reminder.quadrantLevel == 3 || reminder.quadrantLevel == 4)) {
      debugPrint('[沉浸模式拦截] 已静音跳过低优先级提醒: [Q${reminder.quadrantLevel}] ${reminder.taskTitle}');
      _reminderDueController.add(reminder);
      return;
    }

    // 情境感知模式拦截：办公与深度专注情境下静音拦截次要通知并入队待生成事后摘要
    if (ContextTriggerService().shouldInterceptNotification(reminder)) {
      debugPrint('[情境感知拦截] 处于办公/专注情境，拦截并记录次要提醒: [Q${reminder.quadrantLevel}] ${reminder.taskTitle}');
      _reminderDueController.add(reminder);
      return;
    }

    // Notify UI / Stream listeners
    _reminderDueController.add(reminder);

    // Play in-app alert sound
    try {
      SystemSound.play(SystemSoundType.alert);
    } catch (_) {}

    // On Windows, trigger native Toast and bring window to front
    if (Platform.isWindows) {
      final summary = reminder.taskSummary != null && reminder.taskSummary!.isNotEmpty
          ? reminder.taskSummary!
          : '您设置的待办事项时间已到，请及时处理！';

      await showWindowsToast(reminder.taskTitle, summary);

      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
  }

  Future<void> showWindowsToast(String title, String body) async {
    try {
      final safeTitle = title
          .replaceAll("'", "''")
          .replaceAll('`', '``')
          .replaceAll(r'$', r'`$')
          .replaceAll('\r', '')
          .replaceAll('\n', ' ');
      final safeBody = body
          .replaceAll("'", "''")
          .replaceAll('`', '``')
          .replaceAll(r'$', r'`$')
          .replaceAll('\r', '')
          .replaceAll('\n', ' ');

      final script = '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null
\$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
\$textNodes = \$template.GetElementsByTagName('text')
\$textNodes.Item(0).AppendChild(\$template.CreateTextNode('$safeTitle')) > \$null
\$textNodes.Item(1).AppendChild(\$template.CreateTextNode('$safeBody')) > \$null
\$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Don't Forget")
\$notification = [Windows.UI.Notifications.ToastNotification]::new(\$template)
\$notifier.Show(\$notification)
[System.Media.SystemSounds]::Exclamation.Play()
''';

      await Process.run('powershell', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        script,
      ]);
    } catch (e) {
      debugPrint('Windows Toast Error: $e');
    }
  }
}
