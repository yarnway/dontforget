import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

typedef ConsoleProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Cross-platform browser handoff, injectable without launching real apps in tests.
class ConsoleUrlLauncher {
  const ConsoleUrlLauncher({
    this.runProcess = Process.run,
    this.launchExternalUrl,
  });

  final ConsoleProcessRunner runProcess;
  final Future<bool> Function(Uri uri)? launchExternalUrl;

  Future<bool> open(String url, {TargetPlatform? platform}) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return false;
    }
    final target = platform ?? defaultTargetPlatform;
    final (String, List<String>)? command = switch (target) {
      TargetPlatform.windows => (
        'rundll32',
        ['url.dll,FileProtocolHandler', url],
      ),
      TargetPlatform.macOS => ('open', [url]),
      TargetPlatform.linux => ('xdg-open', [url]),
      _ => null,
    };
    if (command == null) {
      if (target == TargetPlatform.android || target == TargetPlatform.iOS) {
        try {
          final opener =
              launchExternalUrl ??
              ((u) => launchUrl(u, mode: LaunchMode.externalApplication));
          return await opener(uri);
        } catch (_) {
          return false;
        }
      }
      return false;
    }
    try {
      final result = await runProcess(command.$1, command.$2);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}

final consoleUrlLauncherProvider = Provider<ConsoleUrlLauncher>(
  (_) => const ConsoleUrlLauncher(),
);
