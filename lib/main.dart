import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'data/database_helper.dart';
import 'models/reminder.dart';
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

Future<void> _handleCli(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('''
======================================================
 DontForget Geek CLI v1.4.0
======================================================
Usage:
  dont_forget --add <content>   (-a) Quickly record a reminder
  dont_forget --list            (-l) List all active reminders
  dont_forget --help            (-h) Show this help message
======================================================''');
    return;
  }

  if (args.contains('--list') || args.contains('-l')) {
    final dbHelper = DatabaseHelper.instance;
    final db = await dbHelper.database;
    final res = await db.query('Reminders', where: 'is_completed = 0');
    stdout.writeln('📋 Active Reminders (${res.length}):');
    for (final item in res) {
      final quad = item['quadrant_level'];
      final title = item['task_title'];
      final time = item['trigger_time'] ?? 'Not set';
      stdout.writeln('  • [Q$quad] $title (Reminder: $time)');
    }
    return;
  }

  int addIdx = args.indexOf('--add');
  if (addIdx == -1) addIdx = args.indexOf('-a');
  if (addIdx != -1) {
    final content = args.sublist(addIdx + 1).join(' ').trim();
    if (content.isEmpty) {
      stderr.writeln('❌ Error: Please provide content for --add');
      return;
    }

    final dbHelper = DatabaseHelper.instance;
    final db = await dbHelper.database;
    final title = content.length > 30 ? '${content.substring(0, 30)}...' : content;
    final reminder = Reminder(
      id: const Uuid().v4(),
      taskTitle: title,
      taskSummary: content,
      quadrantLevel: 2,
      urgencyLevel: 'General',
      importanceLevel: 'Important',
      triggerTime: DateTime.now().add(const Duration(hours: 2)),
    );
    await db.insert('Reminders', reminder.toJson());
    stdout.writeln('✅ [DontForget CLI] Reminder created: "$title"');
    return;
  }
}

void main(List<String> args) async {
  if (args.isNotEmpty &&
      (args.contains('--add') ||
       args.contains('-a') ||
       args.contains('--list') ||
       args.contains('-l') ||
       args.contains('--help') ||
       args.contains('-h'))) {
    await _handleCli(args);
    exit(0);
  }

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
