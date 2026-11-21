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
import 'services/recovery/storage_bootstrap.dart';
import 'ui/screens/storage_unavailable_screen.dart';
import 'app.dart';
import 'services/startup_trace.dart';
import 'services/desktop_window_service.dart';
import 'services/text_bounds.dart';
import 'services/windows_protocol_service.dart';

void _writeCrashLog(dynamic error, StackTrace? stack) {
  try {
    debugPrint('DontForget Error: $error\n$stack');
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      String logDir;
      if (Platform.isWindows) {
        final localAppData =
            Platform.environment['LOCALAPPDATA'] ??
            Platform.environment['APPDATA'] ??
            Platform.environment['USERPROFILE'] ??
            '.';
        logDir = p.join(localAppData, 'DontForget', 'logs');
      } else {
        logDir = p.join(
          Platform.environment['HOME'] ?? '.',
          '.dontforget',
          'logs',
        );
      }
      final dir = Directory(logDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final logFile = File(p.join(logDir, 'error_log.txt'));
      const maxLogBytes = 1024 * 1024;
      if (logFile.existsSync() && logFile.lengthSync() >= maxLogBytes) {
        final prev = File(p.join(logDir, 'error_log.txt.prev'));
        if (prev.existsSync()) prev.deleteSync();
        logFile.renameSync(prev.path);
      }
      final timestamp = DateTime.now().toIso8601String();
      logFile.writeAsStringSync(
        '[$timestamp] Error: $error\nStack: $stack\n\n',
        mode: FileMode.append,
      );
    }
  } catch (_) {}
}

Future<int> _handleCli(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('''
======================================================
 DontForget CLI v1.8.19
======================================================
Usage:
  dont_forget --add <content>   (-a) Quickly record a reminder
  dont_forget --list            (-l) List all active reminders
  dont_forget --help            (-h) Show this help message
======================================================''');
    return 0;
  }

  if (args.contains('--list') || args.contains('-l')) {
    final dbHelper = DatabaseHelper.instance;
    final rows = await dbHelper.read(
      dbHelper.captureGeneration(),
      (db) => db.query('Reminders', where: 'is_completed = 0'),
    );
    final active = rows
        .map(Reminder.fromJson)
        .where((r) => r.isWorkspaceItem)
        .toList();
    stdout.writeln('Active Reminders (${active.length}):');
    for (final item in active) {
      final time = item.triggerTime?.toIso8601String() ?? 'Not set';
      stdout.writeln(
        '  - [Q${item.quadrantLevel}] ${item.taskTitle} (Reminder: $time)',
      );
    }
    return 0;
  }

  int addIdx = args.indexOf('--add');
  if (addIdx == -1) addIdx = args.indexOf('-a');
  if (addIdx != -1) {
    final content = args.sublist(addIdx + 1).join(' ').trim();
    if (content.isEmpty) {
      stderr.writeln('Error: Please provide content for --add');
      return 2;
    }

    final dbHelper = DatabaseHelper.instance;
    final title = truncateRunes(content, 30, suffix: '...');
    final reminder = Reminder(
      id: const Uuid().v4(),
      taskTitle: title,
      taskSummary: content,
      quadrantLevel: 2,
      urgencyLevel: 'General',
      importanceLevel: 'Important',
      triggerTime: DateTime.now().add(const Duration(hours: 2)),
    );
    await dbHelper.writeTransaction(
      dbHelper.captureGeneration(),
      (db) => db.insert('Reminders', reminder.toJson()),
    );
    stdout.writeln('[DontForget CLI] Reminder created: "$title"');
    return 0;
  }

  return 0;
}

void main(List<String> args) async {
  StartupTrace.start();
  if (args.isNotEmpty &&
      (args.contains('--add') ||
          args.contains('-a') ||
          args.contains('--list') ||
          args.contains('-l') ||
          args.contains('--help') ||
          args.contains('-h'))) {
    final helpOnly = args.contains('--help') || args.contains('-h');
    final listRequested = !helpOnly && (args.contains('--list') || args.contains('-l'));
    var addIdx = args.indexOf('--add');
    if (addIdx == -1) addIdx = args.indexOf('-a');
    final emptyAdd = !helpOnly &&
        !listRequested &&
        addIdx != -1 &&
        args.sublist(addIdx + 1).join(' ').trim().isEmpty;
    final needsStorage = !helpOnly && !emptyAdd;
    try {
      if (needsStorage) {
        WidgetsFlutterBinding.ensureInitialized();
        await StorageBootstrap(DatabaseHelper.instance).prepare();
      }
      final code = await _handleCli(args);
      if (needsStorage) {
        await DatabaseHelper.instance.close(createBackup: false);
      }
      await stdout.flush();
      await stderr.flush();
      exit(code);
    } catch (error) {
      final busy =
          error is DatabaseAccessException &&
          error.code == DatabaseAccessError.ownedByAnotherProcess;
      stderr.writeln(
        busy
            ? 'Local data is in use. Quit the other DontForget instance before using CLI.'
            : 'The command did not finish. Check saved data and recovery records before retrying.',
      );
      await stdout.flush();
      await stderr.flush();
      exit(busy ? 75 : 1);
    }
  }

  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      StartupTrace.bind();
      StartupTrace.mark('binding_ready');

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
      final isDesktop =
          Platform.isWindows || Platform.isLinux || Platform.isMacOS;
      if (isDesktop) {
        try {
          await windowManager.ensureInitialized();
        } catch (e, st) {
          _writeCrashLog('windowManager ensureInitialized error: $e', st);
        }
      }

      // Recovery and process ownership precede every provider, migration and
      // notification startup side effect. Never fall through to default data.
      try {
        final helper = DatabaseHelper.instance;
        if (StartupTrace.enabled) {
          StartupTrace.attach(await helper.acquireOwnership());
        }
        await StorageBootstrap(helper).prepare();
        StartupTrace.mark('storage_ready');

        if (isDesktop) {
          try {
            await DesktopWindowService.restoreWindow(helper);
          } catch (e, st) {
            _writeCrashLog('restoreWindow error: $e', st);
          }
        }
      } catch (error, stack) {
        StartupTrace.fail('storage');
        if (kDebugMode) {
          // Keep record contents and credentials out of startup diagnostics.
          debugPrint('Storage bootstrap failed: ${error.runtimeType}');
          if (error is FileSystemException) {
            debugPrint('Storage filesystem code: ${error.osError?.errorCode}');
          }
          debugPrintStack(stackTrace: stack, maxFrames: 12);
        }
        if (isDesktop) {
          try {
            await DesktopWindowService.showDefaultFallbackWindow();
          } catch (e, st) {
            _writeCrashLog('showDefaultFallbackWindow error: $e', st);
          }
        }
        runApp(
          StorageUnavailableScreen(
            busy:
                error is DatabaseAccessException &&
                error.code == DatabaseAccessError.ownedByAnotherProcess,
            onExit: () => exit(1),
          ),
        );
        return;
      }

      final initialProtocolRoute =
          Platform.isWindows
              ? WindowsProtocolService.extractRouteFromArgs(args)
              : null;
      runApp(
        ProviderScope(
          child: MyApp(initialProtocolRoute: initialProtocolRoute),
        ),
      );
    },
    (error, stack) {
      _writeCrashLog('Unhandled Zone Error: $error', stack);
    },
  );
}
