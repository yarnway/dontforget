import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/desktop_shutdown.dart';
import 'package:dont_forget/services/desktop_window_service.dart';
import 'package:dont_forget/services/device_window_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowPreferences parsing and invalid value fallbacks', () {
    test('null json returns default values', () {
      final prefs = WindowPreferences.fromJson(null);
      expect(prefs.width, WindowPreferences.defaultWidth);
      expect(prefs.height, WindowPreferences.defaultHeight);
      expect(prefs.x, isNull);
      expect(prefs.y, isNull);
      expect(prefs.isMaximized, isFalse);
    });

    test('empty json returns default values', () {
      final prefs = WindowPreferences.fromJson(const {});
      expect(prefs.width, WindowPreferences.defaultWidth);
      expect(prefs.height, WindowPreferences.defaultHeight);
      expect(prefs.x, isNull);
      expect(prefs.y, isNull);
      expect(prefs.isMaximized, isFalse);
    });

    test('valid json parses correctly', () {
      final prefs = WindowPreferences.fromJson({
        'width': 1200.0,
        'height': 800.0,
        'x': 150.0,
        'y': 200.0,
        'is_maximized': true,
      });
      expect(prefs.width, 1200.0);
      expect(prefs.height, 800.0);
      expect(prefs.x, 150.0);
      expect(prefs.y, 200.0);
      expect(prefs.isMaximized, isTrue);
    });

    test('negative, zero, NaN or infinite dimensions fallback to defaults', () {
      final p1 = WindowPreferences.fromJson({'width': -100.0, 'height': 0.0});
      expect(p1.width, WindowPreferences.defaultWidth);
      expect(p1.height, WindowPreferences.defaultHeight);

      final p2 = WindowPreferences.fromJson({
        'width': double.nan,
        'height': double.infinity,
      });
      expect(p2.width, WindowPreferences.defaultWidth);
      expect(p2.height, WindowPreferences.defaultHeight);

      final p3 = WindowPreferences.fromJson({
        'width': 'not-a-number',
        'height': [100],
      });
      expect(p3.width, WindowPreferences.defaultWidth);
      expect(p3.height, WindowPreferences.defaultHeight);
    });

    test(
      'dimensions below minimum size are clamped to minWidth and minHeight',
      () {
        final prefs = WindowPreferences.fromJson({
          'width': 200.0,
          'height': 150.0,
        });
        expect(prefs.width, WindowPreferences.minWidth);
        expect(prefs.height, WindowPreferences.minHeight);
      },
    );

    test('illegal coordinates fallback to null (centered)', () {
      final prefs = WindowPreferences.fromJson({
        'x': 'invalid',
        'y': double.nan,
      });
      expect(prefs.x, isNull);
      expect(prefs.y, isNull);
    });

    test('illegal is_maximized falls back to false', () {
      final prefs = WindowPreferences.fromJson({'is_maximized': 'yes'});
      expect(prefs.isMaximized, isFalse);
    });

    test('roundtrip serialization via toJson and fromJson', () {
      const original = WindowPreferences(
        width: 1100.0,
        height: 750.0,
        x: 100.0,
        y: 120.0,
        isMaximized: true,
      );
      final json = original.toJson();
      final restored = WindowPreferences.fromJson(json);
      expect(restored, original);
    });
  });

  group('Screen boundary checking and offscreen fallback (validateAndClamp)', () {
    const primary = Rect.fromLTWH(0, 0, 1920, 1080);
    const secondary = Rect.fromLTWH(1920, 0, 1920, 1080);

    test('no position specified centers on primary display', () {
      const prefs = WindowPreferences(
        width: 1000.0,
        height: 700.0,
        x: null,
        y: null,
      );
      final validated = DesktopWindowService.validateAndClamp(
        prefs: prefs,
        displayBounds: [primary],
      );
      expect(validated.width, 1000.0);
      expect(validated.height, 700.0);
      expect(validated.x, (1920 - 1000) / 2);
      expect(validated.y, (1080 - 700) / 2);
      expect(validated.isMaximized, isFalse);
    });

    test('valid position on primary screen is preserved', () {
      const prefs = WindowPreferences(
        width: 1000.0,
        height: 700.0,
        x: 100.0,
        y: 150.0,
      );
      final validated = DesktopWindowService.validateAndClamp(
        prefs: prefs,
        displayBounds: [primary],
      );
      expect(validated.width, 1000.0);
      expect(validated.height, 700.0);
      expect(validated.x, 100.0);
      expect(validated.y, 150.0);
    });

    test(
      'valid position on secondary screen is preserved when secondary is connected',
      () {
        const prefs = WindowPreferences(
          width: 1000.0,
          height: 700.0,
          x: 2000.0,
          y: 100.0,
        );
        final validated = DesktopWindowService.validateAndClamp(
          prefs: prefs,
          displayBounds: [primary, secondary],
        );
        expect(validated.x, 2000.0);
        expect(validated.y, 100.0);
      },
    );

    test(
      'offscreen position (unplugged secondary monitor) falls back to primary center',
      () {
        const prefs = WindowPreferences(
          width: 1000.0,
          height: 700.0,
          x: 2500.0,
          y: 100.0,
        );
        // Secondary monitor is gone, only primary exists:
        final validated = DesktopWindowService.validateAndClamp(
          prefs: prefs,
          displayBounds: [primary],
        );
        expect(validated.x, (1920 - 1000) / 2);
        expect(validated.y, (1080 - 700) / 2);
      },
    );

    test('far negative offscreen coordinates fall back to primary center', () {
      const prefs = WindowPreferences(
        width: 1000.0,
        height: 700.0,
        x: -9999.0,
        y: -9999.0,
      );
      final validated = DesktopWindowService.validateAndClamp(
        prefs: prefs,
        displayBounds: [primary],
      );
      expect(validated.x, (1920 - 1000) / 2);
      expect(validated.y, (1080 - 700) / 2);
    });

    test('oversized dimensions are clamped to available screen dimensions', () {
      const prefs = WindowPreferences(width: 99999.0, height: 99999.0);
      final validated = DesktopWindowService.validateAndClamp(
        prefs: prefs,
        displayBounds: [primary],
      );
      expect(validated.width, 1920.0);
      expect(validated.height, 1080.0);
    });

    test('empty displayBounds falls back safely without throwing', () {
      const prefs = WindowPreferences(width: 1000.0, height: 700.0);
      final validated = DesktopWindowService.validateAndClamp(
        prefs: prefs,
        displayBounds: [],
      );
      expect(validated.width, 1000.0);
      expect(validated.height, 700.0);
      expect(validated.x, (1920 - 1000) / 2);
    });

    test('isMaximized is preserved during validation and clamping', () {
      const prefs = WindowPreferences(
        width: 1000.0,
        height: 700.0,
        isMaximized: true,
      );
      final validated = DesktopWindowService.validateAndClamp(
        prefs: prefs,
        displayBounds: [primary],
      );
      expect(validated.isMaximized, isTrue);
    });
  });

  group(
    'Database persistence with DatabaseHelper (Settings.workspace_drafts_json)',
    () {
      late DatabaseHelper dbHelper;
      late Directory tempDir;

      setUpAll(() {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      });

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'dontforget_window_test_',
        );
        dbHelper = DatabaseHelper.forTesting(tempDir.path, databaseFactoryFfi);
        await dbHelper.database;
      });

      tearDown(() async {
        await dbHelper.close();
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      });

      test('loading from clean database returns default preferences', () async {
        final loaded = await DesktopWindowService.load(dbHelper);
        expect(loaded.width, WindowPreferences.defaultWidth);
        expect(loaded.height, WindowPreferences.defaultHeight);
        expect(loaded.x, isNull);
        expect(loaded.y, isNull);
        expect(loaded.isMaximized, isFalse);
      });

      test(
        'saving and loading preserves window preferences and other workspace drafts',
        () async {
          // Pre-seed an existing draft in workspace_drafts_json
          final gen1 = dbHelper.captureGeneration();
          await dbHelper.writeTransaction(gen1, (db) async {
            await db.update(
              'Settings',
              {
                'workspace_drafts_json': jsonEncode({
                  'existingDraft': 'valuable-data',
                }),
              },
              where: 'id = ?',
              whereArgs: ['default'],
            );
          });

          const prefs = WindowPreferences(
            width: 1280.0,
            height: 800.0,
            x: 120.0,
            y: 80.0,
            isMaximized: true,
          );
          await DesktopWindowService.save(dbHelper, prefs);

          // Verify window preferences loaded correctly
          final loaded = await DesktopWindowService.load(dbHelper);
          expect(loaded, prefs);

          // Verify existing drafts were NOT overwritten or lost
          final gen2 = dbHelper.captureGeneration();
          final rows = await dbHelper.read(
            gen2,
            (db) =>
                db.query('Settings', where: 'id = ?', whereArgs: ['default']),
          );
          final raw = rows.first['workspace_drafts_json'] as String;
          final map = jsonDecode(raw) as Map<String, dynamic>;
          expect(map['existingDraft'], 'valuable-data');
          expect(map.containsKey(DesktopWindowService.preferenceKey), isFalse);
        },
      );

      test(
        'saving never replaces unreadable or oversized workspace data',
        () async {
          for (final raw in <String>[
            '',
            '{broken',
            '["preserve"]',
            'null',
            jsonEncode({'draft': 'x' * 1048570}),
            jsonEncode({'draft': 'x' * 1048500}),
          ]) {
            final generation = dbHelper.captureGeneration();
            await dbHelper.writeTransaction(
              generation,
              (db) => db.update(
                'Settings',
                {'workspace_drafts_json': raw},
                where: 'id = ?',
                whereArgs: ['default'],
              ),
            );
            await DesktopWindowService.save(
              dbHelper,
              const WindowPreferences(width: 1280, height: 800),
            );
            final rows = await dbHelper.read(
              generation,
              (db) =>
                  db.query('Settings', where: 'id = ?', whereArgs: ['default']),
            );
            expect(rows.single['workspace_drafts_json'], raw);
          }
        },
      );

      test('concurrent draft and window writes preserve both values', () async {
        final drafts = WorkspaceDrafts(dbHelper);
        try {
          await drafts.ready;
          await Future.wait([
            drafts.put('capture', {'text': 'unsent draft'}),
            DesktopWindowService.save(
              dbHelper,
              const WindowPreferences(width: 1280, height: 800),
            ),
          ]);
          final rows = await dbHelper.read(
            dbHelper.captureGeneration(),
            (db) =>
                db.query('Settings', where: 'id = ?', whereArgs: ['default']),
          );
          final data = jsonDecode(
            rows.single['workspace_drafts_json'] as String,
          );
          expect(data['capture'], {'text': 'unsent draft'});
          expect(data.containsKey(DesktopWindowService.preferenceKey), isFalse);
          expect((await DesktopWindowService.load(dbHelper)).width, 1280);
        } finally {
          await drafts.flushed;
          drafts.dispose();
        }
      });

      Future<void> seedLegacy(String raw) => dbHelper.writeTransaction(
        dbHelper.captureGeneration(),
        (db) => db.update('Settings', {'workspace_drafts_json': raw}),
      );

      File localFile() =>
          File('${tempDir.path}/${DeviceWindowPreferencesStore.fileName}');

      test(
        'legacy migration copies geometry and preserves draft bytes for downgrade',
        () async {
          const raw =
              '{ "capture": {"text":"未发送"}, "windowPreferences": '
              '{"width":1300,"height":850,"x":-40,"y":30} }';
          await seedLegacy(raw);
          final loaded = await DesktopWindowService.load(dbHelper);
          expect(loaded.width, 1300);
          expect(loaded.x, -40);
          expect(await localFile().exists(), isTrue);
          await DesktopWindowService.save(
            dbHelper,
            const WindowPreferences(width: 1450),
          );
          final rows = await dbHelper.read(
            dbHelper.captureGeneration(),
            (db) => db.query('Settings'),
          );
          expect(rows.single['workspace_drafts_json'], raw);
          expect((await DesktopWindowService.load(dbHelper)).width, 1450);
        },
      );

      test(
        'a fresh local record ignores later imported legacy geometry',
        () async {
          expect((await DesktopWindowService.load(dbHelper)).width, 1000);
          await seedLegacy(
            jsonEncode({
              'windowPreferences': {'width': 1700},
            }),
          );
          expect((await DesktopWindowService.load(dbHelper)).width, 1000);
        },
      );

      test(
        'local preferences survive closing and reopening their owner',
        () async {
          const prefs = WindowPreferences(
            width: 1380,
            x: -600,
            y: 50,
            isMaximized: true,
          );
          await DesktopWindowService.save(dbHelper, prefs);
          await dbHelper.close();
          dbHelper = DatabaseHelper.forTesting(
            tempDir.path,
            databaseFactoryFfi,
          );
          expect(await DesktopWindowService.load(dbHelper), prefs);
        },
      );

      test(
        'corrupt local data falls back without resurrecting stale legacy bounds',
        () async {
          await seedLegacy(
            jsonEncode({
              'windowPreferences': {'width': 1700},
            }),
          );
          for (final raw in [
            '{broken',
            'null',
            '[]',
            '{"version":1}',
            'x' * 4097,
          ]) {
            await localFile().writeAsString(raw);
            expect((await DesktopWindowService.load(dbHelper)).width, 1000);
            expect(await localFile().readAsString(), raw);
          }
          await DesktopWindowService.save(
            dbHelper,
            const WindowPreferences(width: 1200),
          );
          expect(await localFile().length(), 4097);
          await localFile().writeAsString('{broken');
          await DesktopWindowService.save(
            dbHelper,
            const WindowPreferences(width: 1200),
          );
          expect((await DesktopWindowService.load(dbHelper)).width, 1200);
        },
      );

      test(
        'a future local format is preserved on load and save by an older app',
        () async {
          const raw =
              '{"version":2,"preferences":{"width":1700},"future":true}';
          await localFile().writeAsString(raw);
          expect((await DesktopWindowService.load(dbHelper)).width, 1000);
          await DesktopWindowService.save(
            dbHelper,
            const WindowPreferences(width: 1200),
          );
          expect(await localFile().readAsString(), raw);
        },
      );

      test(
        'an unsafe target is preserved and does not poison later saves',
        () async {
          await Directory(localFile().path).create();
          await DesktopWindowService.save(
            dbHelper,
            const WindowPreferences(width: 1200),
          );
          expect(await Directory(localFile().path).exists(), isTrue);
          expect(
            await tempDir.list().where((f) => f.path.endsWith('.tmp')).toList(),
            isEmpty,
          );
          await Directory(localFile().path).delete();
          await DesktopWindowService.save(
            dbHelper,
            const WindowPreferences(width: 1200),
          );
          expect((await DesktopWindowService.load(dbHelper)).width, 1200);
        },
      );

      test('an invalid save leaves durable geometry intact', () async {
        await DesktopWindowService.save(
          dbHelper,
          const WindowPreferences(width: 1300),
        );
        final before = await localFile().readAsBytes();
        await DesktopWindowService.save(
          dbHelper,
          const WindowPreferences(width: double.nan),
        );
        expect(await localFile().readAsBytes(), before);
        expect((await DesktopWindowService.load(dbHelper)).width, 1300);
      });

      test(
        'serialized migration cannot overwrite a concurrent newer save',
        () async {
          await seedLegacy(
            jsonEncode({
              'windowPreferences': {'width': 1700},
            }),
          );
          final migrating = DesktopWindowService.load(dbHelper);
          final saving = DesktopWindowService.save(
            dbHelper,
            const WindowPreferences(width: 1250),
          );
          await migrating;
          await saving;
          expect((await DesktopWindowService.load(dbHelper)).width, 1250);
        },
      );

      test(
        'maintenance drains local operations and rejects newly arriving saves',
        () async {
          final started = Completer<void>();
          final release = Completer<void>();
          final blocked = dbHelper.withDeviceWindowPreferences((store) async {
            started.complete();
            await release.future;
            await store.write(const WindowPreferences(width: 1350).toJson());
          });
          await started.future;
          var drained = false;
          final maintaining = dbHelper.beginMaintenance().then((lease) {
            drained = true;
            return lease;
          });
          await DesktopWindowService.save(
            dbHelper,
            const WindowPreferences(width: 1800),
          );
          expect(drained, isFalse);
          release.complete();
          await blocked;
          final lease = await maintaining;
          await lease.resume();
          expect((await DesktopWindowService.load(dbHelper)).width, 1350);
        },
      );

      test(
        'an older in-flight save cannot replace newer window bounds',
        () async {
          const old = WindowPreferences(width: 1000, height: 700);
          DesktopWindowService.setCurrentForTesting(old);
          final started = Completer<void>();
          final release = Completer<void>();
          final blocker = dbHelper.withDeviceWindowPreferences((store) async {
            started.complete();
            await release.future;
          });
          await started.future;
          final saving = DesktopWindowService.save(dbHelper, old);
          DesktopWindowService.recordBoundsChanged(
            dbHelper: dbHelper,
            bounds: const Rect.fromLTWH(100, 150, 1400, 900),
            debounceDuration: const Duration(days: 1),
          );
          release.complete();
          await blocker;
          await saving;
          try {
            expect(DesktopWindowService.currentPreferences.width, 1400);
            await DesktopWindowService.flush(dbHelper);
            expect((await DesktopWindowService.load(dbHelper)).width, 1400);
          } finally {
            await DesktopWindowService.flush(dbHelper);
            DesktopWindowService.setCurrentForTesting(null);
          }
        },
      );

      test(
        'recordBoundsChanged and recordMaximizeChanged debounce and flush correctly',
        () async {
          DesktopWindowService.setCurrentForTesting(null);

          // Record bounds change
          DesktopWindowService.recordBoundsChanged(
            dbHelper: dbHelper,
            bounds: const Rect.fromLTWH(100, 150, 1100, 750),
            debounceDuration: const Duration(milliseconds: 100),
          );
          expect(DesktopWindowService.hasPendingDebounce, isTrue);
          expect(DesktopWindowService.currentPreferences.width, 1100.0);
          expect(DesktopWindowService.currentPreferences.height, 750.0);
          expect(DesktopWindowService.currentPreferences.x, 100.0);
          expect(DesktopWindowService.currentPreferences.y, 150.0);
          expect(DesktopWindowService.currentPreferences.isMaximized, isFalse);

          // Flush writes immediately
          await DesktopWindowService.flush(dbHelper);
          expect(DesktopWindowService.hasPendingDebounce, isFalse);

          // Verify database has it
          final loaded1 = await DesktopWindowService.load(dbHelper);
          expect(loaded1.width, 1100.0);
          expect(loaded1.isMaximized, isFalse);

          // Record maximize change
          DesktopWindowService.recordMaximizeChanged(
            dbHelper: dbHelper,
            isMaximized: true,
            debounceDuration: const Duration(milliseconds: 100),
          );
          expect(DesktopWindowService.currentPreferences.isMaximized, isTrue);

          await DesktopWindowService.flush(dbHelper);
          final loaded2 = await DesktopWindowService.load(dbHelper);
          expect(loaded2.width, 1100.0);
          expect(loaded2.isMaximized, isTrue);
        },
      );
    },
  );

  group('Shutdown with saveState', () {
    test(
      'saveState executes before closeStorage, window destroy, and exit',
      () async {
        final order = <String>[];
        await shutdownDesktopApp(
          saveState: () async => order.add('saveState'),
          closeStorage: () async => order.add('closeStorage'),
          destroyWindow: () async => order.add('destroyWindow'),
          exitProcess: (code) => order.add('exit:$code'),
        );
        expect(order, ['saveState', 'closeStorage', 'destroyWindow', 'exit:0']);
      },
    );

    test(
      'failing saveState does not prevent storage closing or exiting',
      () async {
        final order = <String>[];
        final errors = <Object>[];
        await shutdownDesktopApp(
          saveState: () async => throw StateError('disk full'),
          closeStorage: () async => order.add('closeStorage'),
          destroyWindow: () async => order.add('destroyWindow'),
          exitProcess: (code) => order.add('exit:$code'),
          onError: (err, _) => errors.add(err),
        );
        expect(order, ['closeStorage', 'destroyWindow', 'exit:0']);
        expect(errors.single, isA<StateError>());
      },
    );
  });

  group('getDisplayBounds fallback', () {
    test(
      'falls back to 1920x1080 when method channel and flutter displays are empty',
      () async {
        final testMessenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel(
          'dev.leanflutter.plugins/screen_retriever',
        );

        testMessenger.setMockMethodCallHandler(channel, (call) async {
          return null;
        });

        final bounds = await DesktopWindowService.getDisplayBounds(
          channel: channel,
        );
        expect(bounds.isNotEmpty, isTrue);
        expect(bounds.first.width, greaterThan(0));
        expect(bounds.first.height, greaterThan(0));
      },
    );

    test(
      'parses displays from screen_retriever channel format correctly',
      () async {
        final testMessenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel(
          'dev.leanflutter.plugins/screen_retriever',
        );

        testMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAllDisplays') {
            return {
              'displays': [
                {
                  'id': 0,
                  'size': {'width': 2560.0, 'height': 1440.0},
                  'visibleSize': {'width': 2560.0, 'height': 1400.0},
                  'visiblePosition': {'dx': 0.0, 'dy': 0.0},
                },
                {
                  'id': 1,
                  'size': {'width': 1920.0, 'height': 1080.0},
                  'visibleSize': {'width': 1920.0, 'height': 1040.0},
                  'visiblePosition': {'dx': 2560.0, 'dy': 0.0},
                },
              ],
            };
          }
          return null;
        });

        final bounds = await DesktopWindowService.getDisplayBounds(
          channel: channel,
        );
        expect(bounds.length, 2);
        expect(bounds[0], const Rect.fromLTWH(0.0, 0.0, 2560.0, 1400.0));
        expect(bounds[1], const Rect.fromLTWH(2560.0, 0.0, 1920.0, 1040.0));
      },
    );
  });
}
