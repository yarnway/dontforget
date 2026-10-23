// Explicit native negative-input acceptance, never imported by product lib/.
// Only one synthetic task in an acceptance-only directory uses the real OS.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/macos_notification_scheduler.dart';
import 'package:dont_forget/services/notification_permission_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _InvalidRequestScheduler extends MacOSNotificationScheduler {
  const _InvalidRequestScheduler(this.mode);
  final String mode;
  @override
  Future<void> schedule({
    required int nativeId,
    required String title,
    required String body,
    required DateTime trigger,
    required bool playSound,
    required String payload,
  }) => super.schedule(
    nativeId: nativeId,
    title: mode == 'empty_content' ? '' : title,
    body: mode == 'empty_content' ? '' : body,
    trigger: mode == 'past_date' ? DateTime.utc(2000) : trigger,
    playSound: false,
    payload: payload,
  );
}

class NativeNotificationFailurePanel extends StatefulWidget {
  const NativeNotificationFailurePanel({super.key});
  @override
  State<NativeNotificationFailurePanel> createState() => _NativeFailureState();
}

class _NativeFailureState extends State<NativeNotificationFailurePanel> {
  DatabaseHelper? _database;
  NotificationService? _service;
  final _plugin = FlutterLocalNotificationsPlugin();
  late final _permissions = NotificationPermissionService(
    backend: PluginNotificationPermissionBackend(plugin: _plugin),
  );
  Directory? _root;
  bool _busy = true;
  bool _ready = false;
  String _status = 'Opening acceptance-only state…';
  Map<String, Object?> _report = {};
  final _task = Reminder(
    id: 'qa-native-os-rejection',
    taskTitle: 'Synthetic native OS retry acceptance',
    quadrantLevel: 3,
    triggerTime: DateTime.utc(2099),
    createdAt: DateTime.utc(2026, 10, 22),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      if (!Platform.isMacOS) throw StateError('macOS only');
      final support = await getApplicationSupportDirectory();
      if (!p
          .basename(support.path)
          .startsWith('com.example.dontForget.acceptance.')) {
        throw StateError('A separate acceptance bundle is required');
      }
      final pointer = File(
        p.join(support.path, 'native-os-failure-session.json'),
      );
      if (await pointer.exists()) {
        final name =
            (jsonDecode(await pointer.readAsString()) as Map)['directory']
                as String;
        if (!RegExp(r'^native-os-failure-[A-Za-z0-9]+$').hasMatch(name)) {
          throw StateError('Invalid isolated session');
        }
        _root = Directory(p.join(support.path, name));
        if (await _root!.resolveSymbolicLinks() != _root!.path) {
          throw StateError('Unsafe isolated session');
        }
      } else {
        _root = await Directory(support.path).createTemp('native-os-failure-');
        await pointer.writeAsString(
          jsonEncode({'directory': p.basename(_root!.path)}),
          flush: true,
        );
      }
      sqfliteFfiInit();
      _database = DatabaseHelper.forTesting(_root!.path, databaseFactoryFfi);
      final database = _database!;
      await database.database;
      final saved = await database.read(
        database.captureGeneration(),
        (db) => db.query('Reminders'),
      );
      if (saved.isEmpty) {
        await database.writeTransaction(
          database.captureGeneration(),
          (db) => db.insert('Reminders', _task.toJson()),
        );
      } else if (saved.length != 1 ||
          jsonEncode(Reminder.fromJson(saved.single).toJson()) !=
              jsonEncode(_task.toJson())) {
        throw StateError('Unexpected synthetic task contents');
      }
      final report = File(p.join(_root!.path, 'native-failure-report.json'));
      if (await report.exists()) {
        _report = Map<String, Object?>.from(
          jsonDecode(await report.readAsString()) as Map,
        );
      }
      await _observe('opened_saved_state');
      _ready = true;
    } catch (error) {
      _status = 'Acceptance unavailable: ${error.runtimeType}';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _observe(String phase, {Object? error, String? mode}) async {
    final journal = await _database!.withNotificationJournal((j) => j.read());
    final entries = journal?.entries.values.toList() ?? [];
    final saved = entries.where((e) => e.reminderId == _task.id).firstOrNull;
    final permission = await _permissions.refresh();
    List<int>? pendingIds;
    String? pendingReadError;
    try {
      pendingIds = (await _plugin.pendingNotificationRequests())
          .map((request) => request.id)
          .toList();
    } catch (error) {
      pendingReadError = error.runtimeType.toString();
    }
    _status =
        '$phase · saved ${saved?.status ?? 'none'} · PID $pid'
        ' · permission ${permission.authorization.status.name}'
        ' · pending ${pendingIds?.length ?? 'unknown'}';
    final history = List<Object?>.of(_report['events'] as List? ?? []);
    history.add({
      'phase': phase,
      'mode': mode,
      'pid': pid,
      'at': DateTime.now().toUtc().toIso8601String(),
      'journal': journal?.toJson(),
      'authorization': {
        'status': permission.authorization.status.name,
        'alerts_enabled': permission.authorization.alertsEnabled,
        'sounds_enabled': permission.authorization.soundsEnabled,
      },
      'pending_native_ids': pendingIds,
      if (pendingReadError != null) 'pending_read_error': pendingReadError,
      if (error != null) 'error_type': error.runtimeType.toString(),
      if (error is PlatformException)
        'platform_error': {'code': error.code, 'details': error.details},
    });
    _report = {
      'scope':
          'Explicitly altered synthetic request, real OS callback and production service/journal; not a spontaneous OS outage',
      'source_revision': const String.fromEnvironment('BENCHMARK_REVISION'),
      'events': history,
    };
    final temp = File(p.join(_root!.path, 'native-failure-report.tmp'));
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_report),
      flush: true,
    );
    await temp.rename(p.join(_root!.path, 'native-failure-report.json'));
    if (mounted) setState(() {});
  }

  Future<void> _inspectPermission({bool request = false}) async {
    if (_busy || !_ready) return;
    setState(() => _busy = true);
    try {
      if (request) {
        final result = await _permissions.requestNotifications();
        await _observe(
          result.requestFailed
              ? 'permission_request_failed'
              : 'permission_requested',
        );
      } else {
        await _observe('observed_native_state');
      }
    } catch (error) {
      _status = 'Native observation failed: ${error.runtimeType}';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _schedule(String? mode) async {
    if (_busy || !_ready) return;
    setState(() => _busy = true);
    try {
      await _service?.pauseForMaintenance();
      _service = NotificationService.forTesting(
        _plugin,
        usesNativeNotifications: true,
        database: _database,
        macScheduler: mode == null
            ? const MacOSNotificationScheduler()
            : _InvalidRequestScheduler(mode),
      );
      try {
        await _service!.scheduleReminderStrict(_task);
        await _observe(
          mode == null ? 'valid_retry_submitted' : 'probe_accepted_by_os',
          mode: mode,
        );
      } catch (error) {
        // Only the bridge's NSError details establish a real OS rejection.
        // Storage or initialization errors must not be labelled as one.
        await _observe('request_failed', error: error, mode: mode);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cleanup() async {
    if (_busy || !_ready) return;
    setState(() => _busy = true);
    try {
      _service ??= NotificationService.forTesting(
        _plugin,
        usesNativeNotifications: true,
        database: _database,
        macScheduler: const MacOSNotificationScheduler(),
      );
      await _service!.cancelReminderStrict(_task.id);
      final pending = await _plugin.pendingNotificationRequests();
      if (pending.isNotEmpty) throw StateError('Owned native requests remain');
      await _observe('cleanup_no_pending_requests');
    } catch (error) {
      await _observe('cleanup_failed', error: error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    final service = _service;
    final database = _database;
    unawaited(() async {
      await service?.pauseForMaintenance();
      await database?.close(createBackup: false);
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Isolated real OS failure probe')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          const Text(
            'One synthetic task. The two probes alter only the outgoing OS request. No error is fabricated. A successful callback is recorded as accepted, never as failure.',
          ),
          const SizedBox(height: 16),
          SelectableText(_status),
          if (_root != null)
            SelectableText('Report: ${_root!.path}/native-failure-report.json'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _busy || !_ready
                ? null
                : () => _inspectPermission(request: true),
            child: const Text('Request isolated notification permission'),
          ),
          OutlinedButton(
            onPressed: _busy || !_ready ? null : _inspectPermission,
            child: const Text('Read permission and pending OS requests'),
          ),
          FilledButton(
            onPressed: _busy || !_ready
                ? null
                : () => _schedule('empty_content'),
            child: const Text('Probe empty notification content'),
          ),
          OutlinedButton(
            onPressed: _busy || !_ready ? null : () => _schedule('past_date'),
            child: const Text('Probe past calendar date'),
          ),
          OutlinedButton(
            onPressed: _busy || !_ready ? null : () => _schedule(null),
            child: const Text('Retry valid product request'),
          ),
          OutlinedButton(
            onPressed: _busy || !_ready ? null : _cleanup,
            child: const Text('Cancel isolated OS requests'),
          ),
        ],
      ),
    ),
  );
}
