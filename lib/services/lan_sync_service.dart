import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../data/database_helper.dart';
import '../models/reminder.dart';

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
  LanSyncService._internal();

  HttpServer? _server;
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
    if (_server != null) {
      return LanSyncServerInfo(
        isRunning: true,
        ip: _localIp,
        port: _serverPort,
        pin: _currentPin,
      );
    }

    _serverPort = port;
    _currentPin = _generatePin();
    _localIp = await getLocalIpAddress();

    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _serverPort,
        shared: true,
      );

      _server!.listen((HttpRequest request) async {
        try {
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
          request.response.headers.add('Access-Control-Allow-Headers', '*');

          if (request.method == 'OPTIONS') {
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
            return;
          }

          final path = request.uri.path;
          if (path == '/status' && request.method == 'GET') {
            final respData = {
              'status': 'ok',
              'hostname': Platform.localHostname,
              'os': Platform.operatingSystem,
            };
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(respData));
            await request.response.close();
            return;
          }

          if (path == '/sync' && request.method == 'POST') {
            final bodyBytes = await request.fold<List<int>>([], (prev, element) => prev..addAll(element));
            final bodyStr = utf8.decode(bodyBytes);
            final Map<String, dynamic> data = jsonDecode(bodyStr);

            final incomingPin = data['pin']?.toString();
            if (incomingPin != _currentPin) {
              request.response.statusCode = HttpStatus.unauthorized;
              request.response.write(jsonEncode({'error': 'Invalid PIN'}));
              await request.response.close();
              return;
            }

            final incomingReminders = (data['reminders'] as List? ?? [])
                .map((e) => Reminder.fromJson(e as Map<String, dynamic>))
                .toList();

            final db = await dbHelper.database;
            for (final rem in incomingReminders) {
              final existing = await db.query('Reminders', where: 'id = ?', whereArgs: [rem.id]);
              if (existing.isEmpty) {
                await db.insert('Reminders', rem.toJson());
              } else {
                // Keep the completed status if completed on either peer
                final isExistingCompleted = (existing.first['is_completed'] as int?) == 1;
                if (!isExistingCompleted && rem.isCompleted) {
                  await db.update('Reminders', rem.toJson(), where: 'id = ?', whereArgs: [rem.id]);
                }
              }
            }

            onDataChanged?.call();

            // Return all local reminders back to sender
            final currentLocal = await db.query('Reminders');
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'status': 'success',
              'reminders': currentLocal,
            }));
            await request.response.close();
            return;
          }

          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        } catch (e) {
          debugPrint('LAN sync request handling error: $e');
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        }
      });

      return LanSyncServerInfo(
        isRunning: true,
        ip: _localIp,
        port: _serverPort,
        pin: _currentPin,
      );
    } catch (e) {
      debugPrint('Failed to start LAN sync server: $e');
      _server = null;
      rethrow;
    }
  }

  Future<void> stopServer() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _currentPin = '';
    }
  }

  Future<bool> syncWithPeer({
    required String peerIp,
    int port = 42888,
    required String pin,
    required DatabaseHelper dbHelper,
    VoidCallback? onDataChanged,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final db = await dbHelper.database;
      final localRecords = await db.query('Reminders');

      final uri = Uri.parse('http://$peerIp:$port/sync');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      
      final payload = {
        'pin': pin,
        'reminders': localRecords,
      };
      request.write(jsonEncode(payload));
      final response = await request.close();

      if (response.statusCode == HttpStatus.ok) {
        final respStr = await response.transform(utf8.decoder).join();
        final Map<String, dynamic> data = jsonDecode(respStr);
        final peerReminders = (data['reminders'] as List? ?? [])
            .map((e) => Reminder.fromJson(e as Map<String, dynamic>))
            .toList();

        for (final rem in peerReminders) {
          final existing = await db.query('Reminders', where: 'id = ?', whereArgs: [rem.id]);
          if (existing.isEmpty) {
            await db.insert('Reminders', rem.toJson());
          } else {
            final isExistingCompleted = (existing.first['is_completed'] as int?) == 1;
            if (!isExistingCompleted && rem.isCompleted) {
              await db.update('Reminders', rem.toJson(), where: 'id = ?', whereArgs: [rem.id]);
            }
          }
        }

        onDataChanged?.call();
        return true;
      } else {
        return false;
      }
    } catch (e) {
      debugPrint('Error syncing with peer $peerIp: $e');
      return false;
    } finally {
      client.close();
    }
  }
}
