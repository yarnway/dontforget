import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/services/desktop_shutdown.dart';
import 'package:dont_forget/services/desktop_window_service.dart';

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
      final p1 = WindowPreferences.fromJson({
        'width': -100.0,
        'height': 0.0,
      });
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

    test('dimensions below minimum size are clamped to minWidth and minHeight', () {
      final prefs = WindowPreferences.fromJson({
        'width': 200.0,
        'height': 150.0,
      });
      expect(prefs.width, WindowPreferences.minWidth);
      expect(prefs.height, WindowPreferences.minHeight);
    });

    test('illegal coordinates fallback to null (centered)', () {
      final prefs = WindowPreferences.fromJson({
        'x': 'invalid',
        'y': double.nan,
      });
      expect(prefs.x, isNull);
      expect(prefs.y, isNull);
    });

    test('illegal is_maximized falls back to false', () {
      final prefs = WindowPreferences.fromJson({
        'is_maximized': 'yes',
      });
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

    test('valid position on secondary screen is preserved when secondary is connected', () {
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
    });

    test('offscreen position (unplugged secondary monitor) falls back to primary center', () {
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
    });

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
      const prefs = WindowPreferences(
        width: 99999.0,
        height: 99999.0,
      );
      final validated = DesktopWindowService.validateAndClamp(
        prefs: prefs,
        displayBounds: [primary],
      );
      expect(validated.width, 1920.0);
      expect(validated.height, 1080.0);
    });

    test('empty displayBounds falls back safely without throwing', () {
      const prefs = WindowPreferences(
        width: 1000.0,
        height: 700.0,
      );
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

  group('Database persistence with DatabaseHelper (Settings.workspace_drafts_json)', () {
    late DatabaseHelper dbHelper;
    late Directory tempDir;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dontforget_window_test_');
      dbHelper = DatabaseHelper.forTesting(
        tempDir.path,
        databaseFactoryFfi,
      );
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

    test('saving and loading preserves window preferences and other workspace drafts', () async {
      // Pre-seed an existing draft in workspace_drafts_json
      final gen1 = dbHelper.captureGeneration();
      await dbHelper.writeTransaction(gen1, (db) async {
        await db.update(
          'Settings',
          {'workspace_drafts_json': jsonEncode({'existingDraft': 'valuable-data'})},
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
      final rows = await dbHelper.read(gen2, (db) => db.query('Settings', where: 'id = ?', whereArgs: ['default']));
      final raw = rows.first['workspace_drafts_json'] as String;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      expect(map['existingDraft'], 'valuable-data');
      expect(map[DesktopWindowService.preferenceKey]['width'], 1280.0);
      expect(map[DesktopWindowService.preferenceKey]['is_maximized'], true);
    });

    test('recordBoundsChanged and recordMaximizeChanged debounce and flush correctly', () async {
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
    });
  });

  group('Shutdown with saveState', () {
    test('saveState executes before closeStorage, window destroy, and exit', () async {
      final order = <String>[];
      await shutdownDesktopApp(
        saveState: () async => order.add('saveState'),
        closeStorage: () async => order.add('closeStorage'),
        destroyWindow: () async => order.add('destroyWindow'),
        exitProcess: (code) => order.add('exit:$code'),
      );
      expect(order, ['saveState', 'closeStorage', 'destroyWindow', 'exit:0']);
    });

    test('failing saveState does not prevent storage closing or exiting', () async {
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
    });
  });

  group('getDisplayBounds fallback', () {
    test('falls back to 1920x1080 when method channel and flutter displays are empty', () async {
      final testMessenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('dev.leanflutter.plugins/screen_retriever');

      testMessenger.setMockMethodCallHandler(channel, (call) async {
        return null;
      });

      final bounds = await DesktopWindowService.getDisplayBounds(channel: channel);
      expect(bounds.isNotEmpty, isTrue);
      expect(bounds.first.width, greaterThan(0));
      expect(bounds.first.height, greaterThan(0));
    });

    test('parses displays from screen_retriever channel format correctly', () async {
      final testMessenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('dev.leanflutter.plugins/screen_retriever');

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
              }
            ]
          };
        }
        return null;
      });

      final bounds = await DesktopWindowService.getDisplayBounds(channel: channel);
      expect(bounds.length, 2);
      expect(bounds[0], const Rect.fromLTWH(0.0, 0.0, 2560.0, 1400.0));
      expect(bounds[1], const Rect.fromLTWH(2560.0, 0.0, 1920.0, 1040.0));
    });
  });
}
