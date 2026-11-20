import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../data/database_helper.dart';
import '../models/media_record.dart';
import '../models/reminder.dart';
import '../models/medication_plan.dart';
import '../models/departure_plan.dart';
import '../models/ordinary_series.dart';
import '../models/task_details.dart';
import 'local_media_store.dart';

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

typedef LanSyncPeerAddress = ({String host, int port});

typedef LanSyncTaskContent = ({String title, String note, bool inTrash});

class LanSyncConflict {
  const LanSyncConflict({
    required this.taskId,
    required this.local,
    required this.peer,
  });

  final String taskId;
  final LanSyncTaskContent local, peer;

  bool canAdoptText(Reminder reminder) =>
      reminder.id == taskId &&
      reminder.isVisible &&
      !reminder.capturePending &&
      reminder.details.kind == 'task' &&
      !OrdinarySeries.isOwner(reminder) &&
      !OrdinarySeries.isOccurrence(reminder) &&
      contentOf(reminder) == local &&
      (peer.title == local.title || peer.title.trim().isNotEmpty) &&
      (local.title != peer.title || local.note != peer.note);

  bool canAdoptTrash(Reminder reminder) =>
      local.inTrash != peer.inTrash &&
      reminder.id == taskId &&
      !reminder.capturePending &&
      !reminder.isRecurring &&
      reminder.details.kind == 'task' &&
      reminder.details.planId == null &&
      reminder.details.archivedAt == null &&
      !OrdinarySeries.isOwner(reminder) &&
      !OrdinarySeries.isOccurrence(reminder) &&
      contentOf(reminder) == local;

  static LanSyncTaskContent contentOf(Reminder reminder) => (
    title: reminder.taskTitle,
    note: reminder.taskSummary ?? '',
    inTrash: reminder.details.deletedAt != null,
  );
}

class LanSyncService {
  static const defaultPort = 42888;
  static const maxMediaBytes = 32 * 1024 * 1024;
  static final LanSyncService instance = LanSyncService._internal(
    InternetAddress.anyIPv4,
    defaultPort,
  );
  LanSyncService._internal(
    this._bindAddress,
    this._preferredPort, [
    LocalMediaStore? mediaStore,
  ]) : _mediaStore = mediaStore ?? LocalMediaStore();

  @visibleForTesting
  LanSyncService.forTesting({
    int preferredPort = defaultPort,
    LocalMediaStore? mediaStore,
  }) : this._internal(
         InternetAddress.loopbackIPv4,
         preferredPort,
         mediaStore,
       );

  final InternetAddress _bindAddress;
  final int _preferredPort;
  final LocalMediaStore _mediaStore;
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
  int _serverPort = defaultPort;
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
    final rand = Random.secure();
    return (100000 + rand.nextInt(900000)).toString();
  }

  Future<LanSyncServerInfo> startServer({
    int? port,
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
    int? port,
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
      final server = await _bindServer(port, epoch);
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

  Future<HttpServer> _bindServer(int? port, int epoch) async {
    try {
      return await HttpServer.bind(_bindAddress, port ?? _preferredPort);
    } on SocketException {
      if (port != null) rethrow;
      // Let the OS assign a port when the preferred port cannot be opened.
      _checkRuntime(epoch);
      return HttpServer.bind(_bindAddress, 0);
    }
  }

  static LanSyncPeerAddress? parsePeerAddress(String input) {
    final value = input
        .trim()
        .replaceAll(RegExp('[。．]'), '.')
        .replaceAll('：', ':');
    final numeric = InternetAddress.tryParse(value);
    if (numeric != null) return (host: numeric.address, port: defaultPort);
    if (value.isEmpty ||
        value.endsWith(':') ||
        RegExp(r'\s|[/\\?#@%]').hasMatch(value)) {
      return null;
    }
    final uri = Uri.tryParse('http://$value');
    if (uri == null || uri.host.isEmpty) return null;
    final host = uri.host;
    if (InternetAddress.tryParse(host) == null &&
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(host)) {
      return null;
    }
    final suffix = RegExp(r':([0-9]+)$').firstMatch(value)?.group(1);
    final port = suffix == null ? defaultPort : int.tryParse(suffix);
    return port != null && port > 0 && port <= 65535
        ? (host: host, port: port)
        : null;
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
      final incomingMedia = _parseIncomingMedia(data);
      final stagedPaths = <String, String>{};
      var committedStaged = const <String>{};
      try {
        await _stageIncomingMedia(
          incomingMedia,
          stagedPaths,
          () => _checkRuntime(epoch),
        );
        final current = await dbHelper.writeTransaction(generation, (
          transaction,
        ) async {
          final usedStaged = await _merge(
            transaction,
            incoming,
            incomingMedia: incomingMedia.records,
            stagedPaths: stagedPaths,
          );
          return (
            reminders: await transaction.query('Reminders'),
            mediaRecords: await transaction.query('MediaRecords'),
            usedStaged: usedStaged,
          );
        });
        committedStaged = current.usedStaged;
        await _cleanupUncommittedStaged(stagedPaths, committedStaged);
        dbHelper.checkGeneration(generation);
        _checkRuntime(epoch);
        final outgoingMedia = await _buildOutgoingMedia(
          current.reminders,
          current.mediaRecords,
          excludeIds: {for (final r in incomingMedia.records) r.id},
          checkAlive: () {
            dbHelper.checkGeneration(generation);
            _checkRuntime(epoch);
          },
        );
        dbHelper.checkGeneration(generation);
        _checkRuntime(epoch);
        _notify(onDataChanged);
        await _respond(request, HttpStatus.ok, {
          'status': 'success',
          'reminders': current.reminders,
          if (outgoingMedia.records.isNotEmpty)
            'media_records': outgoingMedia.records,
          if (outgoingMedia.attachments.isNotEmpty)
            'attachments': outgoingMedia.attachments,
        });
      } finally {
        await _cleanupUncommittedStaged(stagedPaths, committedStaged);
      }
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
    int port = defaultPort,
    required String pin,
    required DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
    ValueChanged<List<LanSyncConflict>>? onConflicts,
  }) {
    final epoch = _recoveryEpoch;
    if (_recoveryPaused) return Future.value(false);
    final syncing = _syncWithPeer(
      peerIp,
      port,
      pin,
      dbHelper,
      onDataChanged,
      onConflicts,
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
    ValueChanged<List<LanSyncConflict>>? onConflicts,
    int epoch,
  ) async {
    HttpClient? client;
    try {
      _checkRuntime(epoch);
      final generation = dbHelper.captureGeneration();
      final local = await dbHelper.read(
        generation,
        (db) async => (
          reminders: await db.query('Reminders'),
          mediaRecords: await db.query('MediaRecords'),
        ),
      );
      dbHelper.checkGeneration(generation);
      _checkRuntime(epoch);
      final outgoingMedia = await _buildOutgoingMedia(
        local.reminders,
        local.mediaRecords,
        checkAlive: () {
          dbHelper.checkGeneration(generation);
          _checkRuntime(epoch);
        },
      );
      dbHelper.checkGeneration(generation);
      _checkRuntime(epoch);
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      _clients.add(client);

      final uri = Uri(scheme: 'http', host: peerIp, port: port, path: '/sync');
      final request = await client.postUrl(uri);
      _checkRuntime(epoch);
      request.headers.contentType = ContentType.json;

      final payload = {
        'pin': pin,
        'reminders': local.reminders,
        if (outgoingMedia.records.isNotEmpty)
          'media_records': outgoingMedia.records,
        if (outgoingMedia.attachments.isNotEmpty)
          'attachments': outgoingMedia.attachments,
      };
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
        final data = _decode(respStr);
        if (data['status'] != 'success') return false;
        final peerReminders = _reminders(data);
        final peerMedia = _parseIncomingMedia(data);
        final existingMediaIds = {
          for (final row in local.mediaRecords) row['id'] as String,
        };
        final stagedPaths = <String, String>{};
        var committedStaged = const <String>{};
        final conflicts = <String, LanSyncConflict>{};
        try {
          await _stageIncomingMedia(
            peerMedia,
            stagedPaths,
            () {
              dbHelper.checkGeneration(generation);
              _checkRuntime(epoch);
            },
            skipIds: existingMediaIds,
          );
          // The network exchange holds no database scope. Only this short atomic
          // merge re-enters storage, using the original pre-network generation.
          committedStaged = await dbHelper.writeTransaction(
            generation,
            (transaction) => _merge(
              transaction,
              peerReminders,
              incomingMedia: peerMedia.records,
              stagedPaths: stagedPaths,
              conflicts: onConflicts == null ? null : conflicts,
            ),
          );
        } finally {
          await _cleanupUncommittedStaged(stagedPaths, committedStaged);
        }
        dbHelper.checkGeneration(generation);
        _checkRuntime(epoch);
        _notify(onDataChanged);
        if (onConflicts != null) {
          _notify(() => onConflicts(List.unmodifiable(conflicts.values)));
        }
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

  Future<
    ({
      List<Map<String, Object?>> records,
      List<Map<String, Object?>> attachments,
    })
  >
  _buildOutgoingMedia(
    List<Map<String, Object?>> reminderRows,
    List<Map<String, Object?>> mediaRows, {
    Set<String> excludeIds = const <String>{},
    required void Function() checkAlive,
  }) async {
    if (mediaRows.isEmpty || reminderRows.isEmpty) {
      return (
        records: const <Map<String, Object?>>[],
        attachments: const <Map<String, Object?>>[],
      );
    }
    final referencedIds = <String>{};
    for (final row in reminderRows) {
      final recordId = row['record_id'];
      if (recordId is String && recordId.isNotEmpty) {
        referencedIds.add(recordId);
      }
      final reminder = Reminder.fromJson(row);
      referencedIds.addAll(reminder.details.attachmentIds);
    }
    referencedIds.removeAll(excludeIds);
    if (referencedIds.isEmpty) {
      return (
        records: const <Map<String, Object?>>[],
        attachments: const <Map<String, Object?>>[],
      );
    }
    final records = <Map<String, Object?>>[];
    final attachments = <Map<String, Object?>>[];
    var totalBytes = 0;
    for (final row in mediaRows) {
      final id = row['id'];
      if (id is! String || !referencedIds.contains(id)) continue;
      checkAlive();
      final record = MediaRecord.fromJson(row);
      if (record.type == 'text') {
        records.add(record.toJson());
        continue;
      }
      final resolved = await _mediaStore.resolvePath(record.contentOrPath);
      if (await FileSystemEntity.type(resolved, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final length = await File(resolved).length();
      if (length > maxMediaBytes || totalBytes + length > maxMediaBytes) {
        continue;
      }
      final bytes = await File(resolved).readAsBytes();
      if (bytes.length > maxMediaBytes ||
          totalBytes + bytes.length > maxMediaBytes) {
        continue;
      }
      totalBytes += bytes.length;
      final name = _safeFileName(p.basename(resolved));
      records.add(record.toJson());
      attachments.add({
        'id': record.id,
        'name': name,
        'sha256': sha256.convert(bytes).toString(),
        'bytes': base64Encode(bytes),
      });
    }
    return (records: records, attachments: attachments);
  }

  Future<void> _stageIncomingMedia(
    ({
      List<MediaRecord> records,
      Map<String, ({String name, Uint8List bytes})> attachments,
    })
    incoming,
    Map<String, String> stagedPaths,
    void Function() checkAlive, {
    Set<String> skipIds = const <String>{},
  }) async {
    for (final record in incoming.records) {
      if (record.type == 'text' || skipIds.contains(record.id)) continue;
      checkAlive();
      final attachment = incoming.attachments[record.id];
      if (attachment == null) {
        throw const FormatException('Missing sync attachment bytes');
      }
      stagedPaths[record.id] = await _mediaStore.importBytes(
        attachment.bytes,
        fileName: attachment.name,
      );
    }
  }

  Future<void> _cleanupUncommittedStaged(
    Map<String, String> stagedPaths,
    Set<String> committedIds,
  ) async {
    final entries = stagedPaths.entries.toList();
    stagedPaths.clear();
    for (final entry in entries) {
      if (!committedIds.contains(entry.key)) {
        await _mediaStore.discardImport(entry.value);
      }
    }
  }

  static String _safeFileName(String rawName) {
    final cleaned = p
        .basename(rawName)
        .replaceAll(RegExp(r'[/\\:\x00-\x1F\x7F]'), '_')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'attachment.bin';
    }
    return cleaned.length <= 180 ? cleaned : cleaned.substring(0, 180);
  }

  static bool _isValidAttachmentName(String name) {
    final trimmed = name.trim();
    return trimmed.isNotEmpty &&
        trimmed.length <= 180 &&
        trimmed == name &&
        trimmed != '.' &&
        trimmed != '..' &&
        p.basename(trimmed) == trimmed &&
        !trimmed.contains('/') &&
        !trimmed.contains('\\') &&
        !RegExp(r'[\x00-\x1F\x7F]').hasMatch(trimmed);
  }

  static ({
    List<MediaRecord> records,
    Map<String, ({String name, Uint8List bytes})> attachments,
  })
  _parseIncomingMedia(Map<String, dynamic> data) {
    if (!data.containsKey('media_records') &&
        !data.containsKey('attachments')) {
      return (
        records: const <MediaRecord>[],
        attachments: const <String, ({String name, Uint8List bytes})>{},
      );
    }
    if (data['media_records'] != null && data['media_records'] is! List) {
      throw const FormatException('Invalid sync media records');
    }
    if (data['attachments'] != null && data['attachments'] is! List) {
      throw const FormatException('Invalid sync attachments');
    }
    try {
      final rawRecords = (data['media_records'] as List?) ?? const [];
      if (rawRecords.length > 10000) {
        throw const FormatException('Too many sync media records');
      }
      final records = <MediaRecord>[];
      final byId = <String, MediaRecord>{};
      for (final raw in rawRecords) {
        final record = MediaRecord.fromJson(raw as Map<String, dynamic>);
        final id = record.id.trim();
        if (id.isEmpty ||
            id != record.id ||
            RegExp(r'[\x00-\x1F\x7F]').hasMatch(id) ||
            !const {
              'text',
              'image',
              'file',
              'audio',
              'video',
            }.contains(record.type) ||
            byId.containsKey(id)) {
          throw const FormatException('Invalid sync media record');
        }
        records.add(record);
        byId[id] = record;
      }
      final rawAttachments = (data['attachments'] as List?) ?? const [];
      final attachments = <String, ({String name, Uint8List bytes})>{};
      var totalBytes = 0;
      for (final raw in rawAttachments) {
        if (raw is! Map) {
          throw const FormatException('Invalid sync attachment');
        }
        final id = raw['id'];
        final name = raw['name'];
        final digest = raw['sha256'];
        final encoded = raw['bytes'];
        if (id is! String ||
            name is! String ||
            digest is! String ||
            encoded is! String ||
            !_isValidAttachmentName(name) ||
            attachments.containsKey(id)) {
          throw const FormatException('Invalid sync attachment');
        }
        final record = byId[id];
        if (record == null || record.type == 'text') {
          throw const FormatException('Orphan sync attachment');
        }
        if (encoded.length > maxMediaBytes * 4 ~/ 3 + 8) {
          throw const FormatException('Sync attachment too large');
        }
        final bytes = base64Decode(encoded);
        totalBytes += bytes.length;
        if (bytes.length > maxMediaBytes ||
            totalBytes > maxMediaBytes ||
            sha256.convert(bytes).toString() != digest) {
          throw const FormatException('Sync attachment digest mismatch');
        }
        attachments[id] = (name: name, bytes: bytes);
      }
      for (final record in records) {
        if (record.type != 'text' && !attachments.containsKey(record.id)) {
          throw const FormatException('Missing sync attachment bytes');
        }
      }
      return (records: records, attachments: attachments);
    } catch (_) {
      throw const FormatException('Invalid sync media');
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
      return (data['reminders'] as List).map((row) {
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

  static Future<Set<String>> _merge(
    DatabaseExecutor db,
    List<Reminder> incoming, {
    List<MediaRecord> incomingMedia = const <MediaRecord>[],
    Map<String, String> stagedPaths = const <String, String>{},
    Map<String, LanSyncConflict>? conflicts,
  }) async {
    final usedStaged = <String>{};
    final newlyInsertedMediaIds = <String>{};
    var knownMediaIds = <String>{};
    final needsMediaLookup =
        incomingMedia.isNotEmpty ||
        incoming.any(
          (r) => r.recordId != null || r.details.attachmentIds.isNotEmpty,
        );
    if (needsMediaLookup) {
      final rows = await db.query('MediaRecords', columns: ['id']);
      knownMediaIds = {for (final row in rows) row['id'] as String};
    }
    for (final record in incomingMedia) {
      if (knownMediaIds.contains(record.id)) continue;
      if (record.type == 'text') {
        await db.insert('MediaRecords', record.toJson());
        knownMediaIds.add(record.id);
        newlyInsertedMediaIds.add(record.id);
        continue;
      }
      final stagedPath = stagedPaths[record.id];
      if (stagedPath == null) continue;
      await db.insert(
        'MediaRecords',
        MediaRecord(
          id: record.id,
          type: record.type,
          contentOrPath: stagedPath,
          createdAt: record.createdAt,
        ).toJson(),
      );
      usedStaged.add(record.id);
      knownMediaIds.add(record.id);
      newlyInsertedMediaIds.add(record.id);
    }

    for (final reminder in incoming) {
      final existing = await db.query(
        'Reminders',
        where: 'id = ?',
        whereArgs: [reminder.id],
      );
      if (existing.isEmpty) {
        // A peer's acknowledgement belongs to that device. Keep the shared
        // effective time and recurrence anchor, but start a local occurrence.
        var candidate = reminder.copyWith(
          noticeRevision: 0,
          noticeAcknowledgedAt: null,
          upcomingDismissedAt: null,
        );
        if (candidate.details.attachmentIds.any(
          (id) => !knownMediaIds.contains(id),
        )) {
          final validAttachments = [
            for (final id in candidate.details.attachmentIds)
              if (knownMediaIds.contains(id)) id,
          ];
          candidate = candidate.copyWith(
            detailsJson: candidate.details
                .patch({'attachment_ids': validAttachments})
                .encode(),
          );
        }
        final row = candidate.toJson();
        if (candidate.recordId != null &&
            !knownMediaIds.contains(candidate.recordId)) {
          row['record_id'] = null;
        }
        await db.insert('Reminders', row);
        continue;
      }
      final stored = existing.single;
      final completes = stored['is_completed'] != 1 && reminder.isCompleted;
      final hasNewAttachments =
          newlyInsertedMediaIds.isNotEmpty &&
          reminder.details.attachmentIds.any(newlyInsertedMediaIds.contains);
      if (conflicts == null && !completes && !hasNewAttachments) continue;
      final current = Reminder.fromJson(stored);
      if (conflicts != null) {
        final local = LanSyncConflict.contentOf(current);
        final peer = LanSyncConflict.contentOf(reminder);
        if (local != peer) {
          conflicts[reminder.id] = LanSyncConflict(
            taskId: reminder.id,
            local: local,
            peer: peer,
          );
        }
      }
      final addedAttachments =
          current.details.kind == 'task' && reminder.details.kind == 'task'
          ? [
              for (final id in reminder.details.attachmentIds)
                if (newlyInsertedMediaIds.contains(id) &&
                    knownMediaIds.contains(id) &&
                    !current.details.attachmentIds.contains(id))
                  id,
            ]
          : const <String>[];
      final canAddAttachments =
          addedAttachments.isNotEmpty &&
          current.details.attachmentIds.length < TaskDetails.maxAttachments;
      if (completes || canAddAttachments) {
        // Completion wins, and newly received peer attachments are linked,
        // without overwriting this device's newer title, snooze time, or
        // locally assigned revision.
        var updated = current;
        if (canAddAttachments) {
          final mergedIds = [
            ...current.details.attachmentIds,
            ...addedAttachments,
          ].take(TaskDetails.maxAttachments).toList();
          updated = updated.copyWith(
            detailsJson: current.details
                .patch({'attachment_ids': mergedIds})
                .encode(),
          );
        }
        if (completes) {
          updated = updated.copyWith(
            isCompleted: true,
            noticeRevision: current.noticeRevision + 1,
            noticeAcknowledgedAt: null,
            upcomingDismissedAt: null,
            snoozedAt: null,
            recurrenceAnchorTime: null,
          );
        }
        await db.update(
          'Reminders',
          updated.toJson(),
          where: 'id = ?',
          whereArgs: [reminder.id],
        );
      }
    }
    return usedStaged;
  }

  static void _notify(VoidCallback? callback) {
    try {
      callback?.call();
    } catch (_) {
      debugPrint('LAN sync completed; its UI refresh callback failed.');
    }
  }
}
