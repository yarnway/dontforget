import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'dart:async';

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    // Initialize window manager on desktop platforms only
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.ensureInitialized();
      WindowOptions windowOptions = const WindowOptions(
        size: Size(1000, 700),
        center: true,
        title: "别忘了",
      );
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
        // Prevent default close so we can hide to tray instead
        await windowManager.setPreventClose(true);
      });
    }

    runApp(
      const ProviderScope(
        child: MyApp(),
      ),
    );
  }, (error, stack) {
    debugPrint('Unhandled error: $error\n$stack');
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        File('error_log.txt').writeAsStringSync('Error: $error\nStack: $stack\n', mode: FileMode.append);
      } catch (_) {}
    }
  });
}
