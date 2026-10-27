import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../data/database_helper.dart';
import '../models/reminder.dart';
import '../models/medication_plan.dart';
import '../models/departure_plan.dart';

class LanSyncServerInfo {
  final bool isRunning;
  final String ip;
  final int port;
  final String pin;

  LanSyncServerInfo({
    required this.isRunning,
    required this.ip,
    required this.port,
    required this.pin,
  });
}

class LanSyncService {
  static final LanSyncService instance = LanSyncService._internal();
  LanSyncService._internal() : _bindAddress = InternetAddress.anyIPv4;

  @visibleForTesting
  LanSyncService.forTesting() : _bindAddress = InternetAddress.loopbackIPv4;

  final InternetAddress _bindAddress;
  HttpServer? _server;
  HttpServer? _closingServer;
  Future<LanSyncServerInfo>? _starting;
  Future<void>? _stopping;
  final Set<Future<void>> _handlers = {};
  bool _accepting = false;
  bool _recoveryPaused = false;
  int _recoveryEpoch = 0;
  Future<void>? _pausing;
  final Set<HttpClient> _clients = {};
  final Set<Future<bool>> _syncs = {};
  String _lastPin = '';

  bool get pausedForRecovery => _recoveryPaused;

  void _checkRuntime(int epoch) {
    if (_recoveryPaused || epoch != _recoveryEpoch) {
      throw StateError('LAN synchronization is paused for data recovery.');
    }
  }

  Future<void> pauseForRecovery() {
    if (_pausing != null) return _pausing!;
    if (!_recoveryPaused) {
      _recoveryPaused = true;
      _recoveryEpoch++;
    }
    _accepting = false;
    for (final client in List<HttpClient>.of(_clients)) {
      client.close(force: true);
    }
    return _pausing = _pauseForRecovery().whenComplete(() => _pausing = null);
  }

  Future<void> _pauseForRecovery() async {
    // Force-close peer sockets so incomplete request bodies cannot hold a
    // recovery hostage. Already admitted database transactions still drain.
    if (_closingServer case final closing?) await closing.close(force: true);
    final stopping = _stopping ??= _stopServer(
      force: true,
    ).whenComplete(() => _stopping = null);
    await stopping;
    while (_syncs.isNotEmpty) {
      await Future.wait(List<Future<bool>>.of(_syncs));
    }
  }

  void resumeAfterRecovery() {
    if (_pausing != null) throw StateError('LAN cleanup is still running.');
    _recoveryPaused = false;
    // A new server/PIN is created only by a new explicit start request.
  }

  String _currentPin = '';
  int _serverPort = 42888;
  String _localIp = '127.0.0.1';

  bool get isRunning => _server != null;
  String get pin => _currentPin;
  int get port => _serverPort;
  String get localIp => _localIp;

  Future<String> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback &&
              (addr.address.startsWith('192.168.') ||
                  addr.address.startsWith('10.') ||
                  addr.address.startsWith('172.'))) {
            return addr.address;
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (e) {
      debugPrint('Error getting local IP: $e');
    }
    return '127.0.0.1';
  }

  String _generatePin() {
    final rand = Random();
    return (100000 + rand.nextInt(900000)).toString();
  }

  Future<LanSyncServerInfo> startServer({
    int port = 42888,
    required DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
  }) async {
    final epoch = _recoveryEpoch;
    _checkRuntime(epoch);
    if (_stopping != null) await _stopping;
    _checkRuntime(epoch);
    if (_server != null) {
      return _serverInfo();
    }
    final starting = _starting ??= _startServer(
      port,
      dbHelper,
      onDataChanged,
      epoch,
    );
    try {
      return await starting;
    } finally {
      if (identical(_starting, starting)) _starting = null;
    }
  }

  LanSyncServerInfo _serverInfo() => LanSyncServerInfo(
    isRunning: _server != null && _accepting,
    ip: _localIp,
    port: _serverPort,
    pin: _currentPin,
  );

  Future<LanSyncServerInfo> _startServer(
    int port,
    DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
    int epoch,
  ) async {
    _checkRuntime(epoch);
    do {
      _currentPin = _generatePin();
    } while (_currentPin == _lastPin);
    _lastPin = _currentPin;
    _localIp = _bindAddress.isLoopback
        ? _bindAddress.address
        : await getLocalIpAddress();

    try {
      _checkRuntime(epoch);
      final server = await HttpServer.bind(_bindAddress, port);
      if (_recoveryPaused || epoch != _recoveryEpoch) {
        await server.close(force: true);
        _checkRuntime(epoch);
      }
      _server = server;
      _serverPort = server.port;
      _accepting = _stopping == null;
      server.listen((request) {
        final handler = _handleRequest(request, dbHelper, onDataChanged);
        _handlers.add(handler);
        unawaited(handler.then<void>((_) => _handlers.remove(handler)));
      });
      return _serverInfo();
    } catch (e) {
      _server = null;
      _accepting = false;
      _currentPin = '';
      rethrow;
    }
  }

  Future<void> _handleRequest(
    HttpRequest request,
    DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
  ) async {
    final epoch = _recoveryEpoch;
    try {
      request.response.persistentConnection = false;
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add(
        'Access-Control-Allow-Methods',
        'GET, POST, OPTIONS',
      );
      request.response.headers.add('Access-Control-Allow-Headers', '*');
      if (!_accepting) {
        await _respond(request, HttpStatus.serviceUnavailable, {
          'error': 'Sync server is stopping',
        });
        return;
      }
      if (request.method == 'OPTIONS') {
        await _respond(request, HttpStatus.ok, const {});
        return;
      }
      if (request.uri.path == '/status' && request.method == 'GET') {
        await _respond(request, HttpStatus.ok, {
          'status': 'ok',
          'hostname': Platform.localHostname,
          'os': Platform.operatingSystem,
        });
        return;
      }
      if (request.uri.path != '/sync' || request.method != 'POST') {
        await _respond(request, HttpStatus.notFound, const {});
        return;
      }

      // Capture at admission, before waiting for even the request body. A body
      // arriving after recovery must not be admitted against the new database.
      final generation = dbHelper.captureGeneration();
      final data = _decode(
        await request
            .cast<List<int>>()
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 30)),
      );
      _checkRuntime(epoch);
      if (data['pin']?.toString() != _currentPin) {
        await _respond(request, HttpStatus.unauthorized, {
          'error': 'Invalid PIN',
        });
        return;
      }
      final incoming = _reminders(data);
      final current = await dbHelper.writeTransaction(generation, (
        transaction,
      ) async {
        await _merge(transaction, incoming);
        return transaction.query('Reminders');
      });
      dbHelper.checkGeneration(generation);
      _checkRuntime(epoch);
      _notify(onDataChanged);
      await _respond(request, HttpStatus.ok, {
        'status': 'success',
        'reminders': current,
      });
    } on DatabaseAccessException catch (error) {
      await _respond(request, HttpStatus.serviceUnavailable, {
        'error': 'Database unavailable for sync',
        'code': error.code.name,
      });
    } on FormatException {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'Invalid sync data',
      });
    } on TimeoutException {
      await _respond(request, HttpStatus.requestTimeout, {
        'error': 'Sync request timed out',
      });
    } catch (_) {
      await _respond(request, HttpStatus.internalServerError, {
        'error': 'Sync failed',
      });
    }
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?> data,
  ) async {
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(data));
      await request.response.close();
    } catch (_) {
      // A disconnected peer must not leave an unhandled handler Future behind.
    }
  }

  Future<void> stopServer() {
    _accepting = false;
    return _stopping ??= _stopServer().whenComplete(() => _stopping = null);
  }

  Future<void> _stopServer({bool force = false}) async {
    try {
      // Also drain a bind already requested by the UI before maintenance began.
      try {
        await _starting;
      } catch (_) {}
      final server = _server;
      _server = null;
      _closingServer = server;
      await server?.close(force: force || _recoveryPaused);
      while (_handlers.isNotEmpty) {
        await Future.wait(List<Future<void>>.of(_handlers));
      }
    } finally {
      _closingServer = null;
      _currentPin = '';
    }
  }

  Future<bool> syncWithPeer({
    required String peerIp,
    int port = 42888,
    required String pin,
    required DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
  }) {
    final epoch = _recoveryEpoch;
    if (_recoveryPaused) return Future.value(false);
    final syncing = _syncWithPeer(
      peerIp,
      port,
      pin,
      dbHelper,
      onDataChanged,
      epoch,
    );
    _syncs.add(syncing);
    unawaited(syncing.then<void>((_) => _syncs.remove(syncing)));
    return syncing;
  }

  Future<bool> _syncWithPeer(
    String peerIp,
    int port,
    String pin,
    DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
    int epoch,
  ) async {
    HttpClient? client;
    try {
      _checkRuntime(epoch);
      final generation = dbHelper.captureGeneration();
      final localRecords = await dbHelper.read(
        generation,
        (db) => db.query('Reminders'),
      );
      dbHelper.checkGeneration(generation);
      _checkRuntime(epoch);
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      _clients.add(client);

      final uri = Uri(scheme: 'http', host: peerIp, port: port, path: '/sync');
      final request = await client.postUrl(uri);
      _checkRuntime(epoch);
      request.headers.contentType = ContentType.json;

      final payload = {'pin': pin, 'reminders': localRecords};
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode == HttpStatus.ok) {
        final respStr = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 30));
        dbHelper.checkGeneration(generation);
        _checkRuntime(epoch);
        final peerReminders = _reminders(_decode(respStr));
        // The network exchange holds no database scope. Only this short atomic
        // merge re-enters storage, using the original pre-network generation.
        await dbHelper.writeTransaction(
          generation,
          (transaction) => _merge(transaction, peerReminders),
        );
        dbHelper.checkGeneration(generation);
        _checkRuntime(epoch);
        _notify(onDataChanged);
        return true;
      } else {
        return false;
      }
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
      _clients.remove(client);
    }
  }

  static Map<String, dynamic> _decode(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid sync data');
    }
    return decoded;
  }

  static List<Reminder> _reminders(Map<String, dynamic> data) {
    try {
      return (data['reminders'] as List? ?? []).map((row) {
        final reminder = Reminder.fromJson(row as Map<String, dynamic>);
        final details = reminder.details;
        if (details.kind == 'medicationPlan') {
          MedicationPlan.fromJson(details.data);
        }
        if (details.kind == 'medication') Medicine.fromJson(details.data);
        if (details.kind == 'departure') DeparturePlan.fromJson(details.data);
        return reminder;
      }).toList();
    } catch (_) {
      throw const FormatException('Invalid sync reminders');
    }
  }

  static Future<void> _merge(
    DatabaseExecutor db,
    List<Reminder> incoming,
  ) async {
    for (final reminder in incoming) {
      final existing = await db.query(
        'Reminders',
        where: 'id = ?',
        whereArgs: [reminder.id],
      );
      if (existing.isEmpty) {
        // A peer's acknowledgement belongs to that device. Keep the shared
        // effective time and recurrence anchor, but start a local occurrence.
        await db.insert(
          'Reminders',
          reminder
              .copyWith(
                noticeRevision: 0,
                noticeAcknowledgedAt: null,
                upcomingDismissedAt: null,
              )
              .toJson(),
        );
      } else if (existing.first['is_completed'] != 1 && reminder.isCompleted) {
        // Completion wins, but stale peer fields must not overwrite this
        // device's newer title, snooze time, or locally assigned revision.
        final current = Reminder.fromJson(existing.single);
        await db.update(
          'Reminders',
          current
              .copyWith(
                isCompleted: true,
                noticeRevision: current.noticeRevision + 1,
                noticeAcknowledgedAt: null,
                upcomingDismissedAt: null,
                snoozedAt: null,
                recurrenceAnchorTime: null,
              )
              .toJson(),
          where: 'id = ?',
          whereArgs: [reminder.id],
        );
      }
    }
  }

  static void _notify(VoidCallback? callback) {
    try {
      callback?.call();
    } catch (_) {
      debugPrint('LAN sync completed; its UI refresh callback failed.');
    }
  }
}
