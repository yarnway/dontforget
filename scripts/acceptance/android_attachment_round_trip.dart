// Explicit debug-only acceptance target. Never used by lib/main.dart.
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/services/backup_cache_service.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'support/attachment_round_trip_fixture.dart';

const fixturePackage = 'com.yarnway.dontforget.acceptance.attachments20261111';
const token = String.fromEnvironment('DF_ATTACHMENT_TOKEN');
const fixturePort = 17775;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  requireFixture(
    Platform.isAndroid && token.length >= 32,
    'Separate Android identity and explicit token required',
  );
  final support = await getApplicationSupportDirectory();
  requireFixture(
    support.path.startsWith('/data/user/0/$fixturePackage/') ||
        support.path.startsWith('/data/data/$fixturePackage/'),
    'Production identity is forbidden',
  );
  final root = await Directory(
    p.join(support.path, 'attachment-fixture'),
  ).create(recursive: true);
  // Isolated debug identity only; production identity is rejected above.
  // ignore: invalid_use_of_visible_for_testing_member
  DatabaseHelper open(String name) => DatabaseHelper.forTesting(
    p.join(root.path, name),
    sqlite.databaseFactory,
  );
  final source = open('source-db');
  final marker = File(p.join(root.path, 'seeded.json'));
  if (!await marker.exists()) {
    final rows = await source.read(
      source.captureGeneration(),
      (db) => db.query('Reminders'),
    );
    requireFixture(rows.isEmpty, 'Unexpected existing fixture data');
    await seedAttachmentFixture(
      source,
      Directory(p.join(root.path, 'originals')),
    );
    await marker.writeAsString(
      jsonEncode({'fixture': attachmentFixtureMarker}),
      flush: true,
    );
  }
  await verifyAttachmentFixture(source, desktop: false);
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    fixturePort,
  );
  final status = ValueNotifier<String>('验收服务已就绪');
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('附件往返验收')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (_, value, child) => Text('$value\n\n仅合成数据 · 独立测试身份'),
          ),
        ),
      ),
    ),
  );
  var busy = false;
  String? lastError;
  Future<void> jsonReply(
    HttpRequest request,
    Object body, {
    int code = 200,
  }) async {
    request.response.statusCode = code;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  await for (final request in server) {
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $token') {
      await jsonReply(request, {'error': 'Unauthorized'}, code: 403);
      continue;
    }
    if (busy) {
      await jsonReply(request, {'error': 'Busy'}, code: 409);
      continue;
    }
    busy = true;
    try {
      final segments = request.uri.pathSegments;
      if (request.method == 'GET' && request.uri.path == '/source') {
        final report = await verifyAttachmentFixture(source, desktop: false);
        await jsonReply(request, {
          'fixture': attachmentFixtureMarker,
          'pid': pid,
          ...report,
        });
      } else if (request.method == 'GET' && request.uri.path == '/diagnostic') {
        await jsonReply(request, {'error': lastError});
      } else if (segments.length == 2 &&
          const ['plain', 'encrypted'].contains(segments[1]) &&
          segments[0] == 'export' &&
          request.method == 'GET') {
        final encrypted = segments[1] == 'encrypted';
        final backup = await const StreamingBackupService().createFile(
          source,
          source.captureGeneration(),
          Directory(p.join(root.path, 'export-cache')),
          password: encrypted ? attachmentFixturePassword : null,
        );
        requireFixture(
          backup.mediaCount == 3 && backup.missingMedia.isEmpty,
          'Source export differs',
        );
        try {
          request.response.headers.contentType = ContentType.binary;
          request.response.headers.set(
            'X-Backup-SHA256',
            await fixtureHash(backup.file),
          );
          request.response.contentLength = await backup.file.length();
          await request.response.addStream(backup.file.openRead());
          await request.response.close();
        } finally {
          await const BackupCacheService().release(backup.file);
        }
      } else if (segments.length == 2 &&
          const ['plain', 'encrypted'].contains(segments[1]) &&
          segments[0] == 'import' &&
          request.method == 'POST') {
        final format = segments[1], encrypted = format == 'encrypted';
        final input = File(p.join(root.path, 'input-$format.dfbackup'));
        requireFixture(
          !await input.exists() &&
              request.contentLength > 0 &&
              request.contentLength < 16 * 1024 * 1024,
          'Invalid or repeated fixture import',
        );
        final expected = request.headers.value('X-Backup-SHA256') ?? '';
        requireFixture(
          RegExp(r'^[a-f0-9]{64}$').hasMatch(expected),
          'Expected file digest required',
        );
        final out = input.openWrite();
        var count = 0;
        try {
          await for (final chunk in request) {
            count += chunk.length;
            requireFixture(
              count < 16 * 1024 * 1024,
              'Fixture import exceeds limit',
            );
            out.add(chunk);
          }
        } finally {
          await out.close();
        }
        requireFixture(
          count == request.contentLength &&
              await fixtureHash(input) == expected,
          'Transfer digest differs',
        );
        final db = open('return-$format');
        try {
          await db.withDeviceWindowPreferences(
            (store) => store.writeCaptureShortcut(true),
          );
          await restoreAttachmentFixture(
            db,
            sqlite.databaseFactory,
            input,
            Directory(p.join(root.path, 'media-$format')),
            encrypted: encrypted,
            mediaCount: 4,
          );
        } finally {
          await db.close(createBackup: false);
        }
        final reopened = open('return-$format');
        late Map<String, dynamic> report;
        try {
          report = await verifyAttachmentFixture(
            reopened,
            desktop: true,
            restoredRoot: Directory(p.join(root.path, 'media-$format')),
          );
          requireFixture(
            await reopened.withDeviceWindowPreferences(
                  (store) => store.readCaptureShortcut(),
                ) ==
                true,
            'Android device preference changed',
          );
        } finally {
          await reopened.close(createBackup: false);
        }
        await File(p.join(root.path, 'completed-$format.json')).writeAsString(
          jsonEncode({
            'fixture': attachmentFixtureMarker,
            'format': format,
            ...report,
          }),
          flush: true,
        );
        status.value = '$format 恢复通过';
        await jsonReply(request, {
          'pid': pid,
          'format': format,
          'database_reopened': true,
          ...report,
        });
      } else if (request.method == 'GET' && request.uri.path == '/verify') {
        final results = <String, Object>{};
        for (final format in ['plain', 'encrypted']) {
          requireFixture(
            await File(p.join(root.path, 'completed-$format.json')).exists(),
            'Import was not completed',
          );
          final db = open('return-$format');
          try {
            results[format] = await verifyAttachmentFixture(
              db,
              desktop: true,
              restoredRoot: Directory(p.join(root.path, 'media-$format')),
            );
          } finally {
            await db.close(createBackup: false);
          }
        }
        final originals = await verifyAttachmentFixture(source, desktop: false);
        await jsonReply(request, {
          'fixture': attachmentFixtureMarker,
          'pid': pid,
          'formats': results,
          'originals': originals,
          'originals_unchanged': true,
        });
      } else {
        await jsonReply(request, {'error': 'Unsupported operation'}, code: 404);
      }
    } catch (error, stack) {
      lastError = '$error\n$stack';
      status.value = '验收失败';
      await jsonReply(request, {
        'error': error.runtimeType.toString(),
      }, code: 500);
    } finally {
      busy = false;
    }
  }
}
