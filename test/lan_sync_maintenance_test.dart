import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/lan_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ObservedDatabase extends DatabaseHelper {
  _ObservedDatabase(String directory)
    : super.forTesting(directory, databaseFactoryFfi);

  Completer<void>? captured;
  Completer<void>? writeEntered;
  Completer<void>? allowWrite;

  @override
  DataGeneration captureGeneration() {
    final result = super.captureGeneration();
    if (captured case final signal? when !signal.isCompleted) {
      signal.complete();
    }
    return result;
  }

  @override
  Future<T> writeTransaction<T>(
    DataGeneration generation,
    Future<T> Function(Transaction) operation,
  ) => super.writeTransaction(generation, (transaction) async {
    if (writeEntered case final signal? when !signal.isCompleted) {
      signal.complete();
    }
    await allowWrite?.future;
    return operation(transaction);
  });
}

void main() {
  late Directory directory;
  late _ObservedDatabase helper;
  late LanSyncService service;
  final peers = <HttpServer>[];
  Reminder reminder(String id, {bool completed = false}) =>
      Reminder(id: id, taskTitle: id, quadrantLevel: 3, isCompleted: completed);

  Future<List<Map<String, Object?>>> rows() => helper.read(
    helper.captureGeneration(),
    (database) => database.query('Reminders'),
  );

  Future<void> seed(List<Reminder> records) =>
      helper.writeTransaction(helper.captureGeneration(), (transaction) async {
        for (final record in records) {
          await transaction.insert('Reminders', record.toJson());
        }
      });

  Future<void> rejectSecondInsert() => helper.writeTransaction(
    helper.captureGeneration(),
    (transaction) => transaction.execute(
      "CREATE TRIGGER reject_sync BEFORE INSERT ON Reminders WHEN NEW.id = 'blocked' "
      "BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    ),
  );

  Future<({int status, Map<String, dynamic> data})> post(
    LanSyncServerInfo server,
    List<Reminder> records,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.port,
          path: '/sync',
        ),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'pin': server.pin,
          'reminders': records.map((r) => r.toJson()).toList(),
        }),
      );
      final response = await request.close();
      final data =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      return (status: response.statusCode, data: data);
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpServer> peer(
    Future<List<Reminder>> Function(Map<String, dynamic>) respond,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    peers.add(server);
    server.listen((request) async {
      final incoming =
          jsonDecode(
                await request.cast<List<int>>().transform(utf8.decoder).join(),
              )
              as Map<String, dynamic>;
      final records = await respond(incoming);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'status': 'success',
          'reminders': records.map((r) => r.toJson()).toList(),
        }),
      );
      await request.response.close();
    });
    return server;
  }

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('lan-maintenance-');
    helper = _ObservedDatabase(directory.path);
    service = LanSyncService.forTesting();
    await rows();
  });

  tearDown(() async {
    if (helper.allowWrite case final signal? when !signal.isCompleted) {
      signal.complete();
    }
    await service.stopServer();
    for (final server in peers) {
      await server.close(force: true);
    }
    peers.clear();
    await helper.close();
    await directory.delete(recursive: true);
  });

  test('server atomically merges and returns the committed snapshot', () async {
    await seed([reminder('local'), reminder('done', completed: true)]);
    var callbacks = 0;
    final server = await service.startServer(
      port: 0,
      dbHelper: helper,
      onDataChanged: () => callbacks++,
    );
    expect(server.ip, '127.0.0.1');
    expect(server.port, greaterThan(0));
    final response = await post(server, [
      reminder('remote'),
      reminder('local', completed: true),
      reminder('done'),
    ]);
    expect(response.status, HttpStatus.ok);
    expect(response.data['status'], 'success');
    final snapshot = (response.data['reminders'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      snapshot.map((r) => r['id']),
      unorderedEquals(['local', 'done', 'remote']),
    );
    expect(
      snapshot.where((r) => r['is_completed'] == 1).map((r) => r['id']),
      unorderedEquals(['local', 'done']),
    );
    expect(snapshot, await rows());
    expect(callbacks, 1);
  });

  test('server merge failure rolls back every incoming row', () async {
    await seed([reminder('baseline')]);
    await rejectSecondInsert();
    var callbacks = 0;
    final server = await service.startServer(
      port: 0,
      dbHelper: helper,
      onDataChanged: () => callbacks++,
    );
    final response = await post(server, [
      reminder('first'),
      reminder('blocked'),
    ]);
    expect(response.status, HttpStatus.internalServerError);
    expect((await rows()).map((r) => r['id']), ['baseline']);
    expect(callbacks, 0);
  });

  test(
    'maintenance rejects server requests and client admission without callbacks',
    () async {
      var callbacks = 0;
      var peerRequests = 0;
      final server = await service.startServer(
        port: 0,
        dbHelper: helper,
        onDataChanged: () => callbacks++,
      );
      final remote = await peer((_) async {
        peerRequests++;
        return [reminder('unexpected')];
      });
      final lease = await helper.beginMaintenance();
      try {
        final response = await post(server, [reminder('blocked')]);
        expect(response.status, HttpStatus.serviceUnavailable);
        expect(response.data['code'], 'maintenance');
        expect(
          await service.syncWithPeer(
            peerIp: '127.0.0.1',
            port: remote.port,
            pin: '123456',
            dbHelper: helper,
            onDataChanged: () => callbacks++,
          ),
          isFalse,
        );
        expect(peerRequests, 0);
        expect(callbacks, 0);
      } finally {
        await lease.resume();
      }
      expect(await rows(), isEmpty);
      expect((await post(server, [reminder('fresh')])).status, HttpStatus.ok);
      expect(callbacks, 1);
    },
  );

  test(
    'a server request admitted before maintenance cannot merge its late body',
    () async {
      var callbacks = 0;
      final server = await service.startServer(
        port: 0,
        dbHelper: helper,
        onDataChanged: () => callbacks++,
      );
      helper.captured = Completer<void>();
      final client = HttpClient();
      try {
        final bytes = utf8.encode(
          jsonEncode({
            'pin': server.pin,
            'reminders': [reminder('stale').toJson()],
          }),
        );
        final request = await client.postUrl(
          Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: server.port,
            path: '/sync',
          ),
        );
        request.bufferOutput = false;
        request.contentLength = bytes.length;
        request.add(bytes.sublist(0, 1));
        await request.flush();
        await helper.captured!.future.timeout(const Duration(seconds: 5));
        final lease = await helper.beginMaintenance();
        await lease.closeWithoutBackup();
        await lease.resume();
        await seed([reminder('restored')]);
        request.add(bytes.sublist(1));
        final response = await request.close();
        final data = jsonDecode(await response.transform(utf8.decoder).join());
        expect(response.statusCode, HttpStatus.serviceUnavailable);
        expect(data['code'], 'staleGeneration');
        expect((await rows()).map((r) => r['id']), ['restored']);
        expect(callbacks, 0);
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'client releases its read scope during network IO and rejects a stale response',
    () async {
      await seed([reminder('before')]);
      final received = Completer<Map<String, dynamic>>();
      final release = Completer<void>();
      final remote = await peer((incoming) async {
        received.complete(incoming);
        await release.future;
        return [reminder('old-peer-result')];
      });
      var callbacks = 0;
      final syncing = service.syncWithPeer(
        peerIp: '127.0.0.1',
        port: remote.port,
        pin: '123456',
        dbHelper: helper,
        onDataChanged: () => callbacks++,
      );
      try {
        final payload = await received.future.timeout(
          const Duration(seconds: 5),
        );
        expect((payload['reminders'] as List).single['id'], 'before');
        // Maintenance must finish without waiting for this peer's reply.
        final lease = await helper.beginMaintenance().timeout(
          const Duration(seconds: 5),
        );
        await lease.closeWithoutBackup();
        await lease.resume();
        await helper.writeTransaction(helper.captureGeneration(), (
          transaction,
        ) async {
          await transaction.delete('Reminders');
          await transaction.insert('Reminders', reminder('restored').toJson());
        });
        release.complete();
        expect(await syncing, isFalse);
        expect((await rows()).map((r) => r['id']), ['restored']);
        expect(callbacks, 0);
      } finally {
        if (!release.isCompleted) release.complete();
        await syncing;
      }
    },
  );

  test('client merge failure is atomic and a later sync can retry', () async {
    await seed([reminder('baseline')]);
    await rejectSecondInsert();
    var callbacks = 0;
    var fail = true;
    final remote = await peer(
      (_) async =>
          fail ? [reminder('first'), reminder('blocked')] : [reminder('fresh')],
    );
    Future<bool> sync() => service.syncWithPeer(
      peerIp: '127.0.0.1',
      port: remote.port,
      pin: '123456',
      dbHelper: helper,
      onDataChanged: () => callbacks++,
    );
    expect(await sync(), isFalse);
    expect((await rows()).map((r) => r['id']), ['baseline']);
    expect(callbacks, 0);
    fail = false;
    expect(await sync(), isTrue);
    expect(
      (await rows()).map((r) => r['id']),
      unorderedEquals(['baseline', 'fresh']),
    );
    expect(callbacks, 1);
  });

  test(
    'stopServer drains admitted handlers before returning and closes admission',
    () async {
      var callbacks = 0;
      final server = await service.startServer(
        port: 0,
        dbHelper: helper,
        onDataChanged: () => callbacks++,
      );
      helper.writeEntered = Completer<void>();
      helper.allowWrite = Completer<void>();
      final response = post(server, [reminder('accepted')]);
      await helper.writeEntered!.future.timeout(const Duration(seconds: 5));
      var stopped = false;
      final stopping = service.stopServer().then((_) => stopped = true);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(stopped, isFalse);
        helper.allowWrite!.complete();
        expect((await response).status, HttpStatus.ok);
        await stopping;
        expect(service.isRunning, isFalse);
        expect(service.pin, isEmpty);
        expect(callbacks, 1);
        expect((await rows()).single['id'], 'accepted');
        await expectLater(post(server, []), throwsA(isA<SocketException>()));
      } finally {
        if (!helper.allowWrite!.isCompleted) helper.allowWrite!.complete();
        await stopping;
      }
    },
  );
}
