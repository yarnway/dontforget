// Explicit debug-only device acceptance. Not imported by lib/main.dart.
// Uses the production app, SAF save/open, preview, confirmation and coordinator.
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/app.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/providers/recovery_coordinator.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/backup_file_exporter.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/storage_bootstrap.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:dont_forget/ui/widgets/portable_backup_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'support/attachment_round_trip_fixture.dart';

const safFixturePackage = 'com.yarnway.dontforget.acceptance.saf20261114';
const _token = String.fromEnvironment('DF_SAF_TOKEN');
const _port = 17786;
late Directory _root;
Future<void> _auditTail = Future<void>.value();
int _exportNumber = 0;
Future<void> audit(Map<String, Object?> entry) => _auditTail = _auditTail.then(
  (_) async => File(
    p.join(_root.path, 'events.jsonl'),
  ).writeAsString('${jsonEncode(entry)}\n', mode: FileMode.append, flush: true),
);

class _OfflineClients extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Network clients disabled in this synthetic fixture');
}

class _NativeExporter extends BackupFileExporter {
  const _NativeExporter();
  @override
  Future<String?> save(File source, String filename) async {
    final number = ++_exportNumber;
    final hash = await fixtureHash(source);
    final bytes = await source.length();
    final encrypted = await const StreamingBackupService().needsPassword(
      source,
    );
    final result = await super.save(source, filename);
    if (result != null) {
      requireFixture(
        Uri.parse(result).scheme == 'content' &&
            const {
              'com.android.externalstorage.documents',
              'com.android.providers.downloads.documents',
            }.contains(Uri.parse(result).authority),
        'Only local external-storage SAF output is allowed',
      );
      final folder = await Directory(p.join(_root.path, 'exports')).create();
      final target = File(p.join(folder.path, 'export-$number.dfbackup'));
      requireFixture(!await target.exists(), 'Do not replace an audit copy');
      await source.copy(target.path);
      requireFixture(
        await fixtureHash(target) == hash,
        'Export audit copy differs',
      );
    }
    await audit({
      'kind': 'export',
      'number': number,
      'name': filename,
      'uri': result,
      'sha256': hash,
      'bytes': bytes,
      'encrypted': encrypted,
    });
    return result;
  }
}

class _NativeStreaming extends StreamingBackupService {
  const _NativeStreaming();
  @override
  Future<BackupFilePreview> inspect(
    File source, {
    String? password,
    BackupControl? control,
    bool Function()? isCurrent,
    BackupProgressCallback? onProgress,
  }) async {
    final hash = await fixtureHash(source);
    try {
      final preview = await super.inspect(
        source,
        password: password,
        control: control,
        isCurrent: isCurrent,
        onProgress: onProgress,
      );
      await audit({
        'kind': 'native-picked-file-inspected',
        'source': source.path,
        'sha256': hash,
        'encrypted': preview.encrypted,
        'media': preview.mediaCount,
        'missing': preview.missingMedia.length,
      });
      return preview;
    } catch (error) {
      await audit({
        'kind': 'native-picked-file-rejected',
        'sha256': hash,
        'error_type': error.runtimeType.toString(),
      });
      rethrow;
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  requireFixture(
    Platform.isAndroid && _token.length >= 32,
    'Android and explicit fixture token required',
  );
  final support = await getApplicationSupportDirectory();
  requireFixture(
    support.path.startsWith('/data/user/0/$safFixturePackage/') ||
        support.path.startsWith('/data/data/$safFixturePackage/'),
    'Ordinary app identities are forbidden',
  );
  HttpOverrides.global = _OfflineClients();
  _root = await Directory(
    p.join(support.path, 'saf-fixture'),
  ).create(recursive: true);
  // ignore: invalid_use_of_visible_for_testing_member
  final db = DatabaseHelper.forTesting(
    p.join(_root.path, 'db'),
    sqlite.databaseFactory,
  );
  // ignore: invalid_use_of_visible_for_testing_member
  final notifications = NotificationService.forTesting(
    FlutterLocalNotificationsPlugin(),
    usesNativeNotifications: false,
    database: db,
  );
  await StorageBootstrap(db).prepare();
  final seeded = File(p.join(_root.path, 'seeded.json'));
  if (!await seeded.exists()) {
    requireFixture(
      (await db.read(
        db.captureGeneration(),
        (sql) => sql.query('Reminders'),
      )).isEmpty,
      'Never seed over existing rows',
    );
    await seedAttachmentFixture(db, Directory(p.join(_root.path, 'originals')));
    // No configured service and no outbound client. Retain a harmless public
    // marker in drafts so restored data can be distinguished from defaults.
    await db.writeTransaction(
      db.captureGeneration(),
      (sql) => sql.update('Settings', {
        'api_key': '',
        'workspace_drafts_json': jsonEncode({
          'safSynthetic': {'marker': 'saf-local-documents-v1'},
        }),
      }),
    );
    await seeded.writeAsString(
      jsonEncode({'marker': 'saf-local-documents-v1'}),
      flush: true,
    );
  }
  final container = ProviderContainer(
    overrides: [
      databaseHelperProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(notifications),
      remindersProvider.overrideWith(
        (_) => RemindersNotifier(
          db,
          notifications: notifications,
          runLoadEffects: false,
        ),
      ),
      backupFileExporterProvider.overrideWithValue(const _NativeExporter()),
      streamingBackupServiceProvider.overrideWithValue(
        const _NativeStreaming(),
      ),
      backupCacheRootProvider.overrideWithValue(
        () async => Directory(p.join(_root.path, 'export-cache')),
      ),
      backupMediaRootProvider.overrideWithValue(
        () async => Directory(p.join(_root.path, 'restored-media')),
      ),
    ],
  );
  await container.read(settingsProvider.notifier).ready;
  await container.read(remindersProvider.notifier).ready;
  await container.read(workspaceDraftsProvider.notifier).ready;
  final birth = db.captureGeneration();
  final runtimeBirth = container.read(runtimeRecoveryGateProvider).capture();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    audit({
      'kind': 'framework-error',
      'type': details.exception.runtimeType.toString(),
    });
  };
  final priorEvents = File(p.join(_root.path, 'events.jsonl'));
  if (await priorEvents.exists()) {
    for (final line in await priorEvents.readAsLines()) {
      final event = jsonDecode(line) as Map;
      if (event['kind'] == 'export' &&
          (event['number'] as int) > _exportNumber) {
        _exportNumber = event['number'] as int;
      }
    }
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
  runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
  await for (final request in server) {
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_token') {
      request.response.statusCode = 403;
      await request.response.close();
      continue;
    }
    try {
      Object response;
      if (request.method == 'GET' && request.uri.path == '/state') {
        final phase = container.read(recoveryCoordinatorProvider).state;
        if (phase.working) {
          response = {'phase': phase.phase.name, 'busy': true};
        } else {
          final data = await db.read(
            db.captureGeneration(),
            (sql) async => {
              for (final t in ['Reminders', 'MediaRecords', 'Settings'])
                t: await sql.query(t, orderBy: 'id'),
            },
          );
          final media = <String, Object?>{};
          for (final row in data['MediaRecords']!) {
            final file = File(row['content_or_path'] as String);
            media[row['id'] as String] = {
              'path': file.path,
              'sha256': await fixtureHash(file),
              'bytes': await file.length(),
            };
          }
          final originals = <String, String>{};
          await for (final file in Directory(
            p.join(_root.path, 'originals'),
          ).list(recursive: true, followLinks: false)) {
            if (file is File) {
              originals[p.relative(file.path, from: _root.path)] =
                  await fixtureHash(file);
            }
          }
          await _auditTail;
          final log = File(p.join(_root.path, 'events.jsonl'));
          response = {
            'pid': pid,
            'phase': phase.phase.name,
            'runtime_paused': container
                .read(runtimeRecoveryGateProvider)
                .paused,
            'initial_data_generation_current': db.isCurrent(birth),
            'initial_runtime_token_current': container
                .read(runtimeRecoveryGateProvider)
                .isCurrent(runtimeBirth),
            'schema': DatabaseHelper.schemaVersion,
            'tables': data,
            'media': media,
            'originals': originals,
            'events': await log.exists()
                ? (await log.readAsLines()).map(jsonDecode).toList()
                : [],
          };
        }
      } else if (request.method == 'POST' && request.uri.path == '/fill') {
        final mode = request.uri.queryParameters['mode'];
        requireFixture(
          ['plain', 'encrypted', 'wrong', 'unlock'].contains(mode),
          'Known fixture fill mode required',
        );
        final wanted = <String, String>{
          if (mode == 'plain' || mode == 'encrypted')
            'backup-name': mode == 'plain'
                ? 'DF-SAF106-中文-plain'
                : 'DF-SAF106-English-encrypted',
          if (mode == 'encrypted') ...{
            'backup-password': attachmentFixturePassword,
            'backup-password-repeat': attachmentFixturePassword,
          },
          if (mode == 'wrong' || mode == 'unlock')
            'restore-password': mode == 'wrong'
                ? 'Wrong-Synthetic-2026'
                : attachmentFixturePassword,
        };
        final found = <String>[];
        void visit(Element e) {
          final w = e.widget;
          if (w is TextField && w.key is ValueKey<String>) {
            final key = (w.key as ValueKey<String>).value;
            if (wanted.containsKey(key)) {
              w.controller!.value = TextEditingValue(
                text: wanted[key]!,
                selection: TextSelection.collapsed(offset: wanted[key]!.length),
              );
              w.onChanged?.call(wanted[key]!);
              found.add(key);
            }
          }
          e.visitChildren(visit);
        }

        WidgetsBinding.instance.rootElement?.visitChildren(visit);
        requireFixture(
          found.length == wanted.length,
          'Expected fixture fields are not mounted',
        );
        response = {
          'controller_injection_not_software_ime': true,
          'fields': found,
        };
      } else if (request.method == 'POST' && request.uri.path == '/mutate') {
        final mode = request.uri.queryParameters['mode'];
        requireFixture(
          ['plain', 'encrypted'].contains(mode),
          'Known synthetic mutation required',
        );
        requireFixture(
          container.read(recoveryCoordinatorProvider).state.phase ==
              RecoveryPhase.idle,
          'Only mutate an idle fixture',
        );
        await db.writeTransaction(db.captureGeneration(), (sql) async {
          await sql.insert(
            'Reminders',
            Reminder(
              id: 'after-export-$mode',
              taskTitle: 'Synthetic change after $mode export',
              quadrantLevel: 4,
            ).toJson(),
          );
          await sql.update(
            'Reminders',
            {'task_summary': 'Synthetic modified after $mode export'},
            where: 'id = ?',
            whereArgs: ['fixture-active'],
          );
        });
        response = {'synthetic_mutation_applied': true};
      } else {
        request.response.statusCode = 404;
        response = {'error': 'Unknown fixture operation'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    } catch (error) {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'error_type': error.runtimeType.toString()}),
      );
      await request.response.close();
    }
  }
}
