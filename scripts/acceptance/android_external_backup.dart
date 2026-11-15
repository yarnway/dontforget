// Explicit synthetic device entry. Never imported by the ordinary app.
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/app.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/content/content_cleanup_service.dart';
import 'package:dont_forget/services/content/owned_material_activity.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/storage_bootstrap.dart';
import 'package:dont_forget/ui/widgets/content_management_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'support/attachment_round_trip_fixture.dart'
    show requireFixture, fixtureHash;

const externalFixturePackage = 'com.yarnway.dontforget.acceptance.refs20261115';
const _token = String.fromEnvironment('DF_REFERENCE_TOKEN');

class _OfflineClients extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('External clients disabled in synthetic acceptance');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  requireFixture(
    Platform.isAndroid && _token.length >= 32,
    'Explicit Android fixture required',
  );
  final support = await getApplicationSupportDirectory();
  requireFixture(
    support.path.startsWith('/data/user/0/$externalFixturePackage/') ||
        support.path.startsWith('/data/data/$externalFixturePackage/'),
    'Ordinary identities forbidden',
  );
  HttpOverrides.global = _OfflineClients();
  final root = await Directory(
    p.join(support.path, 'reference-fixture'),
  ).create(recursive: true);
  final documents = await getApplicationDocumentsDirectory();
  // ignore: invalid_use_of_visible_for_testing_member
  final database = DatabaseHelper.forTesting(
    p.join(root.path, 'db'),
    sqlite.databaseFactory,
  );
  await StorageBootstrap(database).prepare();
  final marker = File(p.join(root.path, 'seeded.json'));
  final original = File(
    p.join(documents.path, 'media', 'import-reference-fixture', 'original.txt'),
  );
  final external = File(p.join(root.path, 'old-backup.json'));
  if (!await marker.exists()) {
    final rows = await database.read(
      database.captureGeneration(),
      (db) => db.query('Reminders'),
    );
    requireFixture(
      rows.isEmpty && !await external.exists(),
      'Never overwrite an existing fixture',
    );
    await original.parent.create(recursive: true);
    await original.writeAsString(
      'Public synthetic original for external backup protection.',
    );
    await OwnedMaterialActivity.mark(original.parent, 'original');
    final old = DateTime(2020);
    await for (final entry in original.parent.list()) {
      if (entry is File) await entry.setLastModified(old);
    }
    await database.writeTransaction(database.captureGeneration(), (db) async {
      await db.insert(
        'Reminders',
        Reminder(
          id: 'keep',
          taskTitle: 'Reference acceptance',
          quadrantLevel: 2,
        ).toJson(),
      );
      await db.insert(
        'MediaRecords',
        MediaRecord(
          id: 'orphan',
          type: 'file',
          contentOrPath: original.path,
          createdAt: old,
        ).toJson(),
      );
      await db.update('Settings', {
        'api_key': '',
        'workspace_drafts_json': jsonEncode({'referenceFixture': 'keep'}),
      });
    });
    final snapshot = await database.read(
      database.captureGeneration(),
      (db) async => {
        'version': DatabaseHelper.schemaVersion,
        'timestamp': null,
        'settings': await db.query('Settings'),
        'reminders': await db.query('Reminders'),
        'media_records': await db.query('MediaRecords'),
      },
    );
    await external.writeAsString(jsonEncode(snapshot), flush: true);
    await marker.writeAsString(
      jsonEncode({'source_sha256': await fixtureHash(external)}),
      flush: true,
    );
  }
  // ignore: invalid_use_of_visible_for_testing_member
  final notifications = NotificationService.forTesting(
    FlutterLocalNotificationsPlugin(),
    usesNativeNotifications: false,
    database: database,
  );
  final cleanup = ContentCleanupService(database, documents);
  final container = ProviderContainer(
    overrides: [
      databaseHelperProvider.overrideWithValue(database),
      notificationServiceProvider.overrideWithValue(notifications),
      remindersProvider.overrideWith(
        (_) => RemindersNotifier(
          database,
          notifications: notifications,
          runLoadEffects: false,
        ),
      ),
      contentCleanupServiceProvider.overrideWithValue(Future.value(cleanup)),
    ],
  );
  await container.read(settingsProvider.notifier).ready;
  await container.read(remindersProvider.notifier).ready;
  await container.read(workspaceDraftsProvider.notifier).ready;
  final errors = <String>[];
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    errors.add(details.exception.runtimeType.toString());
  };
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 17787);
  runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
  await for (final request in server) {
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_token') {
      request.response.statusCode = 403;
      await request.response.close();
      continue;
    }
    try {
      requireFixture(
        request.method == 'GET' && request.uri.path == '/state',
        'Read-only bridge',
      );
      final tables = await database.read(
        database.captureGeneration(),
        (db) async => {
          for (final table in ['Settings', 'Reminders', 'MediaRecords'])
            table: await db.query(table, orderBy: 'id'),
        },
      );
      final inventory = await cleanup.inspect(database.captureGeneration());
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'pid': pid,
          'tables': tables,
          'errors': errors,
          'original_sha256': await original.exists()
              ? await fixtureHash(original)
              : null,
          'source_sha256': await fixtureHash(external),
          'source_path': external.path,
          'inventory': [
            for (final entry in inventory.entries)
              {'key': entry.key, 'bytes': entry.bytes, 'reason': entry.reason},
          ],
        }),
      );
    } catch (error) {
      request.response.statusCode = 500;
      request.response.write(
        jsonEncode({'error_type': error.runtimeType.toString()}),
      );
    }
    await request.response.close();
  }
}
