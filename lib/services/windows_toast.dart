import 'dart:io';

import 'package:flutter/foundation.dart';

/// Windows toast delivery for reminders.
///
/// The desktop build has no scheduled OS notification channel, so due
/// occurrences are delivered from the running app through the Windows toast
/// API. The script is kept as a pure function so escaping and template
/// selection can be regression-tested without touching the operating system.
class WindowsToast {
  /// Must match the AppUserModelID of the installed Start Menu shortcut
  /// (`windows_installer/installer.iss`) and the runner entry point
  /// (`windows/runner/main.cpp`).
  static const appUserModelId = 'DontForget';

  /// Longest body accepted by the toast template before wrapping degrades.
  static const maxBodyLength = 240;

  static String _escape(String value) => value
      .replaceAll("'", "''")
      .replaceAll('`', '``')
      .replaceAll(r'$', r'`$')
      .replaceAll('\r', '')
      .replaceAll('\n', ' ');

  /// Whether the body would repeat the title instead of adding context.
  static bool bodyDuplicatesTitle(String title, String body) =>
      body.trim().isEmpty || body.trim() == title.trim();

  /// Builds the PowerShell script that shows one toast.
  ///
  /// A toast whose body repeats the title uses the single-line template, so
  /// the bubble does not show the same sentence twice. The audio element is
  /// only silent for low-priority reminders. Protocol activation and action
  /// buttons allow clicking the notification or interactive buttons to launch
  /// or focus the application without requiring COM server registration.
  static String script({
    required String title,
    String body = '',
    bool playSound = true,
    String? launchUri,
    String? completeActionTitle,
    String? completeActionUri,
    String? snoozeActionTitle,
    String? snoozeActionUri,
  }) {
    final safeTitle = _escape(title.trim());
    final safeBody = _escape(body.trim());
    final singleLine = bodyDuplicatesTitle(title, body);
    final template = singleLine ? 'ToastText01' : 'ToastText02';
    final trimmedBody = safeBody.length > maxBodyLength
        ? '${safeBody.substring(0, maxBodyLength)}…'
        : safeBody;

    final buffer = StringBuffer()
      ..writeln(
        '[Windows.UI.Notifications.ToastNotificationManager, '
        'Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null',
      )
      ..writeln(
        '\$template = [Windows.UI.Notifications.ToastNotificationManager]'
        '::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]'
        '::$template)',
      );

    if (launchUri != null && launchUri.isNotEmpty) {
      final safeLaunch = _escape(launchUri);
      buffer
        ..writeln(
          "\$template.DocumentElement.SetAttribute('activationType', 'protocol')",
        )
        ..writeln(
          "\$template.DocumentElement.SetAttribute('launch', '$safeLaunch')",
        );
    }

    buffer
      ..writeln('\$textNodes = \$template.GetElementsByTagName(\'text\')')
      ..writeln(
        '\$textNodes.Item(0).AppendChild(\$template.CreateTextNode('
        "'$safeTitle')) > \$null",
      );
    if (!singleLine) {
      buffer.writeln(
        '\$textNodes.Item(1).AppendChild(\$template.CreateTextNode('
        "'$trimmedBody')) > \$null",
      );
    }
    buffer
      ..writeln('\$audio = \$template.CreateElement(\'audio\')')
      ..writeln('\$audio.SetAttribute(\'silent\', \'${!playSound}\')')
      ..writeln('\$template.DocumentElement.AppendChild(\$audio) > \$null');

    final hasActions =
        (completeActionUri != null && completeActionUri.isNotEmpty) ||
        (snoozeActionUri != null && snoozeActionUri.isNotEmpty);
    if (hasActions) {
      buffer.writeln("\$actions = \$template.CreateElement('actions')");
      if (completeActionUri != null && completeActionUri.isNotEmpty) {
        final safeCompleteTitle = _escape(completeActionTitle ?? '完成');
        final safeCompleteUri = _escape(completeActionUri);
        buffer
          ..writeln("\$a0 = \$template.CreateElement('action')")
          ..writeln("\$a0.SetAttribute('content', '$safeCompleteTitle')")
          ..writeln("\$a0.SetAttribute('activationType', 'protocol')")
          ..writeln("\$a0.SetAttribute('arguments', '$safeCompleteUri')")
          ..writeln("\$actions.AppendChild(\$a0) > \$null");
      }
      if (snoozeActionUri != null && snoozeActionUri.isNotEmpty) {
        final safeSnoozeTitle = _escape(snoozeActionTitle ?? '延后 15 分钟');
        final safeSnoozeUri = _escape(snoozeActionUri);
        buffer
          ..writeln("\$a1 = \$template.CreateElement('action')")
          ..writeln("\$a1.SetAttribute('content', '$safeSnoozeTitle')")
          ..writeln("\$a1.SetAttribute('activationType', 'protocol')")
          ..writeln("\$a1.SetAttribute('arguments', '$safeSnoozeUri')")
          ..writeln("\$actions.AppendChild(\$a1) > \$null");
      }
      buffer.writeln(
        "\$template.DocumentElement.AppendChild(\$actions) > \$null",
      );
    }

    buffer
      ..writeln(
        '\$notifier = [Windows.UI.Notifications.ToastNotificationManager]'
        '::CreateToastNotifier("$appUserModelId")',
      )
      ..writeln(
        '\$notification = [Windows.UI.Notifications.ToastNotification]'
        '::new(\$template)',
      )
      ..writeln('\$notifier.Show(\$notification)');
    return buffer.toString();
  }

  /// Shows one toast. Failures are reported instead of being swallowed, so a
  /// blocked PowerShell policy is diagnosable from the app log.
  static Future<bool> show({
    required String title,
    String body = '',
    bool playSound = true,
    String? launchUri,
    String? completeActionTitle,
    String? completeActionUri,
    String? snoozeActionTitle,
    String? snoozeActionUri,
    @visibleForTesting
    Future<ProcessResult> Function(List<String> arguments)? runner,
  }) async {
    final run = runner ?? _runPowerShell;
    try {
      final result = await run([
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        script(
          title: title,
          body: body,
          playSound: playSound,
          launchUri: launchUri,
          completeActionTitle: completeActionTitle,
          completeActionUri: completeActionUri,
          snoozeActionTitle: snoozeActionTitle,
          snoozeActionUri: snoozeActionUri,
        ),
      ]);
      if (result.exitCode != 0) {
        debugPrint(
          'Windows toast failed (exit ${result.exitCode}): ${result.stderr}',
        );
        return false;
      }
      final stderr = result.stderr?.toString().trim() ?? '';
      if (stderr.isNotEmpty) {
        debugPrint('Windows toast stderr: $stderr');
      }
      return true;
    } catch (error) {
      debugPrint('Windows toast error: $error');
      return false;
    }
  }

  static Future<ProcessResult> _runPowerShell(List<String> arguments) =>
      Process.run('powershell', arguments);
}
