import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path/path.dart' as p;
import 'app.dart';

void _writeCrashLog(dynamic error, StackTrace? stack) {
  try {
    debugPrint('DontForget Error: $error\n$stack');
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      String logDir;
      if (Platform.isWindows) {
        final localAppData = Platform.environment['LOCALAPPDATA'] ??
            Platform.environment['APPDATA'] ??
            Platform.environment['USERPROFILE'] ??
            '.';
        logDir = p.join(localAppData, 'DontForget', 'logs');
      } else {
        logDir = p.join(Platform.environment['HOME'] ?? '.', '.dontforget', 'logs');
      }
      final dir = Directory(logDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final logFile = File(p.join(logDir, 'error_log.txt'));
      final timestamp = DateTime.now().toIso8601String();
      logFile.writeAsStringSync(
        '[$timestamp] Error: $error\nStack: $stack\n\n',
        mode: FileMode.append,
      );
    }
  } catch (_) {}
}

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Catch framework-level errors
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      _writeCrashLog(details.exception, details.stack);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      _writeCrashLog(error, stack);
      return true;
    };
    
    // Initialize window manager safely on desktop platforms
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        await windowManager.ensureInitialized();
        const windowOptions = WindowOptions(
          size: Size(1000, 700),
          center: true,
          title: "DontForget",
        );
        windowManager.waitUntilReadyToShow(windowOptions, () async {
          try {
            await windowManager.show();
            await windowManager.focus();
            // Prevent default close so we can hide to tray instead
            await windowManager.setPreventClose(true);
          } catch (e, st) {
            _writeCrashLog('windowManager show error: $e', st);
          }
        });
      } catch (e, st) {
        _writeCrashLog('windowManager ensureInitialized error: $e', st);
      }
    }

    runApp(
      const ProviderScope(
        child: MyApp(),
      ),
    );
  }, (error, stack) {
    _writeCrashLog('Unhandled Zone Error: $error', stack);
  });
}
