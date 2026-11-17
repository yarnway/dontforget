@TestOn('windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/models/media_record.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/desktop_window_service.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/recovery/storage_bootstrap.dart';
import 'package:dont_forget/services/storage_directory_lease.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// This explicit worker never opens the ordinary application directory. The
// companion runner kills only the waiting test-engine process in its own job.
class _Notifications extends NotificationService {
  _Notifications(this.root, this.mode)
    // Standalone acceptance is outside test/ discovery; this remains test-only.
    // ignore: invalid_use_of_visible_for_testing_member
    : super.forTesting(
        FlutterLocalNotificationsPlugin(),
        usesNativeNotifications: false,
      );
  final Directory root;
  final String mode;
  final events = <Map<String, Object?>>[];
  bool paused = false;
  @override
  bool get isPausedForMaintenance => paused;
  Future<void> record(Map<String, Object?> event) async {
    events.add(event);
    await File(
      p.join(root.path, 'notifications-$mode.json'),
    ).writeAsString(jsonEncode(events), flush: true);
  }

  @override
  Future<void> pauseForMaintenance() async {
    paused = true;
    await record({'action': 'pause'});
  }

  @override
  Future<void> resumeFromReminders(Iterable<Reminder> reminders) async {
    final pending = File(
      p.join(root.path, 'live', DatabaseRecovery.journalName),
    );
    final journal = await pending.exists()
        ? jsonDecode(await pending.readAsString()) as Map
        : null;
    await record({
      'action': 'resume',
      'ids': reminders.map((r) => r.id).toList()..sort(),
      'durable_state': journal?['state'],
    });
    paused = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final supplied = Platform.environment['DONTFORGET_CRASH_CASE'];
  test(
    'isolated recovery process worker',
    () async {
      final root = Directory(supplied!);
      expect(
        p.isWithin(p.join(Directory.current.path, 'build'), root.path),
        isTrue,
      );
      expect(
        await root.resolveSymbolicLinks(),
        root.path,
        reason: 'Only a canonical newly owned fixture directory is allowed',
      );
      final token = Platform.environment['DONTFORGET_CRASH_TOKEN'];
      expect(token, matches(r'^[a-f0-9]{32}$'));
      final config =
          jsonDecode(
                await File(
                  p.join(root.path, 'fixture-owner.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(config['format'], 'dontforget.recovery-crash.fixture');
      expect(config['token'], token);
      final mode = Platform.environment['DONTFORGET_CRASH_MODE'];
      expect(mode, anyOf('crash', 'recover', 'reopen', 'blocked'));
      final point = RecoveryCheckpoint.values.byName(
        config['checkpoint'] as String,
      );
      final format = config['input_format'] as String;
      expect(format, anyOf('json', 'sqlite'));
      sqfliteFfiInit();
      Future<String> hash(File file) async =>
          (await sha256.bind(file.openRead()).first).toString();
      Future<Map<String, dynamic>> rows(DatabaseHelper db) => db.read(
        db.captureGeneration(),
        (sql) async => {
          for (final table in ['Reminders', 'MediaRecords', 'Settings'])
            table: await sql.query(table, orderBy: 'id'),
        },
      );
      Future<void> writeJson(String name, Object value) =>
          File(p.join(root.path, name)).writeAsString(
            const JsonEncoder.withIndent('  ').convert(value),
            flush: true,
          );
      // ignore: invalid_use_of_visible_for_testing_member
      final live = DatabaseHelper.forTesting(
        p.join(root.path, 'live'),
        databaseFactoryFfi,
      );
      final notifications = _Notifications(root, mode!);
      final inspector = BackupInspector(
        databaseFactoryFfi,
        temporaryDirectory: root,
      );
      final source = File(p.join(root.path, 'input.$format'));
      final expectedFile = File(p.join(root.path, 'expected-private.json'));
      if (mode == 'crash') {
        expect(await expectedFile.exists(), isFalse);
        // ignore: invalid_use_of_visible_for_testing_member
        final incoming = DatabaseHelper.forTesting(
          p.join(root.path, 'incoming'),
          databaseFactoryFfi,
        );
        await Directory(p.join(root.path, 'materials')).create();
        for (final pair in [('old', live), ('new', incoming)]) {
          final id = pair.$1, db = pair.$2;
          final file = File(p.join(root.path, 'materials', '$id.bin'));
          await file.writeAsBytes(
            Uint8List.fromList(
              List.generate(65536, (i) => (i + (id == 'old' ? 17 : 43)) % 251),
            ),
            flush: true,
          );
          await db.writeTransaction(db.captureGeneration(), (sql) async {
            await sql.insert(
              'MediaRecords',
              MediaRecord(
                id: '$id-file',
                type: 'file',
                contentOrPath: file.path,
                createdAt: DateTime(2032, 3, 1),
              ).toJson(),
            );
            await sql.insert(
              'MediaRecords',
              MediaRecord(
                id: '$id-text',
                type: 'text',
                contentOrPath: '$id 合成记录，保留中文与换行\n第二行。',
                createdAt: DateTime(2032, 3, 2),
              ).toJson(),
            );
            for (var index = 0; index < 2; index++) {
              await sql.insert(
                'Reminders',
                Reminder(
                  id: '$id-task-$index',
                  recordId: '$id-${index == 0 ? 'file' : 'text'}',
                  taskTitle: '$id 合成恢复事项 $index',
                  taskSummary: '$id notes',
                  quadrantLevel: index + 1,
                  triggerTime: DateTime(2032, 4, 1, 9 + index),
                  timeOrigin: ReminderTimeOrigin.manual,
                  sourceText: '$id source $index',
                  isPinned: index == 0,
                  isCompleted: index == 1,
                  createdAt: DateTime(2032, 3, index + 1),
                  noticeRevision: index + 3,
                  linkedTaskIds: ['$id-task-${1 - index}'],
                ).toJson(),
              );
            }
            await sql.update('Settings', {
              'workspace_drafts_json': jsonEncode({
                'capture': {'text': '$id unsent 中文草稿'},
              }),
            });
          });
        }
        await DesktopWindowService.save(
          live,
          const WindowPreferences(width: 1260, height: 820, x: -320, y: 40),
        );
        final oldRows = await rows(live), newRows = await rows(incoming);
        final oldEpoch = await live.readNotificationEpoch();
        await live.createMirrorBackup();
        await incoming.createMirrorBackup();
        await incoming.close(createBackup: false);
        await File(
          p.join(
            root.path,
            'incoming',
            format == 'json' ? 'ha_snapshot.json' : 'dont_forget_v3.mirror.db',
          ),
        ).copy(source.path);
        final preview = await inspector.inspect(source);
        expect(preview.missingMedia, 0);
        expect(preview.unresolvedReferences, 0);
        final protected = <String, String>{};
        for (final relative in [
          'input.$format',
          'live/dont_forget_v3.mirror.db',
          'live/ha_snapshot.json',
          'live/device-window-preferences.json',
          'materials/old.bin',
          'materials/new.bin',
        ]) {
          protected[relative] = await hash(File(p.join(root.path, relative)));
        }
        await writeJson('expected-private.json', {
          'old': oldRows,
          'new': newRows,
          'old_epoch': oldEpoch,
          'protected_files': protected,
        });
        try {
          await DatabaseRecovery(
            live,
            inspector: inspector,
            notifications: notifications,
            checkpoint: (at) async {
              if ((point == RecoveryCheckpoint.rollbackStarted ||
                      point == RecoveryCheckpoint.rollbackInstalled) &&
                  at == RecoveryCheckpoint.candidateOpened) {
                throw StateError('Synthetic rollback request before commit');
              }
              if (at == point) {
                await writeJson('ready.partial', {
                  'pid': pid,
                  'token': token,
                  'checkpoint': at.name,
                  'executable': Platform.resolvedExecutable,
                });
                await File(
                  p.join(root.path, 'ready.partial'),
                ).rename(p.join(root.path, 'ready.json'));
                // No exception injection or graceful database close here.
                // The owning parent terminates this one test-engine process.
                await Completer<void>().future;
              }
            },
          ).restore(source, expectedDigest: preview.digest);
          fail('The explicitly requested crash boundary was not reached');
        } finally {
          await writeJson('graceful-finally-ran.json', {'ran': true});
          await live.close(createBackup: false);
        }
      } else {
        final expected = jsonDecode(await expectedFile.readAsString()) as Map;
        final pending = File(
          p.join(root.path, 'live', DatabaseRecovery.journalName),
        );
        final hadPending = await pending.exists();
        final before = <String, String>{};
        await for (final entry in root.list(
          recursive: true,
          followLinks: false,
        )) {
          // Windows byte-range ownership locks also block another read handle
          // in the same process. Never hash the live lock while holding it.
          // Runner logs are evidence being written, not application material.
          if (entry is File &&
              p.basename(entry.path) != StorageDirectoryLease.lockName &&
              !entry.path.endsWith('.log')) {
            before[p.relative(entry.path, from: root.path)] = await hash(entry);
          }
        }
        final journalGated = hadPending;
        final primary = File(p.join(root.path, 'live', 'dont_forget_v3.db'));
        final primaryExistedBeforeGate = await primary.exists();
        try {
          if (hadPending) {
            await expectLater(
              live.read(
                live.captureGeneration(),
                (db) => db.query('Reminders'),
              ),
              throwsA(isA<DatabaseRecoveryRequiredException>()),
            );
            expect(await primary.exists(), primaryExistedBeforeGate);
            for (final entry in before.entries) {
              expect(
                await hash(File(p.join(root.path, entry.key))),
                entry.value,
              );
            }
          }
          final recovery = DatabaseRecovery(
            live,
            inspector: inspector,
            notifications: notifications,
          );
          if (mode == 'blocked') {
            await expectLater(
              StorageBootstrap(live, recovery: recovery).prepare(),
              throwsA(isA<DatabaseRecoveryException>()),
            );
            expect(
              notifications.events.where((e) => e['action'] == 'resume'),
              isEmpty,
            );
            for (final entry in before.entries) {
              expect(
                await hash(File(p.join(root.path, entry.key))),
                entry.value,
              );
            }
            await writeJson('blocked-result.json', {
              'pid': pid,
              'startup_gate_blocked_normal_reads': journalGated,
              'gate_preserves_primary_identity_and_existing_files': true,
              'unsafe_identity_blocks_recovery': true,
              'all_preexisting_material_file_hashes_preserved': true,
              'notification_resume_attempts': 0,
            });
          } else {
            await StorageBootstrap(live, recovery: recovery).prepare();
            final wanted = point == RecoveryCheckpoint.committed
                ? 'new'
                : 'old';
            expect(await rows(live), expected[wanted]);
            expect(await pending.exists(), isFalse);
            for (final entry in (expected['protected_files'] as Map).entries) {
              expect(
                await hash(File(p.join(root.path, entry.key as String))),
                entry.value,
              );
            }
            final epoch = await live.readNotificationEpoch();
            if (mode == 'recover') {
              expect(epoch == expected['old_epoch'], !hadPending);
              final resumes = notifications.events
                  .where((e) => e['action'] == 'resume')
                  .toList();
              expect(resumes, hasLength(hadPending ? 1 : 0));
              if (hadPending) {
                expect(
                  resumes.single['durable_state'],
                  wanted == 'new' ? 'committed' : 'rollingBack',
                );
                expect(resumes.single['ids'], [
                  '$wanted-task-0',
                  '$wanted-task-1',
                ]);
                final archives = await Directory(p.join(root.path, 'live'))
                    .list(recursive: true)
                    .where(
                      (e) =>
                          e is File &&
                          p.basename(e.path) ==
                              (wanted == 'new'
                                  ? 'completed.json'
                                  : 'rolled-back.json'),
                    )
                    .toList();
                expect(archives, hasLength(1));
                final archive = archives.single as File;
                final decision =
                    jsonDecode(await archive.readAsString()) as Map;
                final rollback = File(
                  p.join(archive.parent.path, 'rollback.db'),
                );
                expect(await hash(rollback), decision['oldDigest']);
                final old = await databaseFactoryFfi.openDatabase(
                  rollback.path,
                  options: OpenDatabaseOptions(
                    readOnly: true,
                    singleInstance: false,
                  ),
                );
                try {
                  expect({
                    for (final table in [
                      'Reminders',
                      'MediaRecords',
                      'Settings',
                    ])
                      table: await old.query(table, orderBy: 'id'),
                  }, expected['old']);
                } finally {
                  await old.close();
                }
              }
              await writeJson('recovered-private.json', {
                'rows': await rows(live),
                'epoch': epoch,
              });
            } else {
              final recovered =
                  jsonDecode(
                        await File(
                          p.join(root.path, 'recovered-private.json'),
                        ).readAsString(),
                      )
                      as Map;
              expect(await rows(live), recovered['rows']);
              expect(epoch, recovered['epoch']);
              expect(notifications.events, isEmpty);
            }
            await writeJson('$mode-result.json', {
              'pid': pid,
              'checkpoint': point.name,
              'input_format': format,
              'startup_gate_blocked_normal_reads': journalGated,
              'gate_preserves_primary_identity_and_existing_files': true,
              'selected_dataset': wanted,
              'all_business_fields_equal': true,
              'source_backup_mirrors_media_and_geometry_hashes_equal': true,
              'pending_journal_absent': true,
              'notification_epoch_and_resume_order_valid': true,
            });
          }
        } finally {
          await live.close(createBackup: false);
        }
      }
    },
    skip: supplied == null
        ? 'Requires the explicit isolated process-crash runner.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
