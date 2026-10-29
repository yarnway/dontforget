import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../data/database_helper.dart';
import 'startup_trace.dart';

/// Immutable model representing saved window dimensions, position, and state.
class WindowPreferences {
  final double width;
  final double height;
  final double? x;
  final double? y;
  final bool isMaximized;

  static const double defaultWidth = 1000.0;
  static const double defaultHeight = 700.0;
  static const double minWidth = 480.0;
  static const double minHeight = 360.0;

  const WindowPreferences({
    this.width = defaultWidth,
    this.height = defaultHeight,
    this.x,
    this.y,
    this.isMaximized = false,
  });

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'x': x,
    'y': y,
    'is_maximized': isMaximized,
  };

  factory WindowPreferences.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const WindowPreferences();

    final rawWidth = json['width'];
    final rawHeight = json['height'];
    final rawX = json['x'];
    final rawY = json['y'];
    final rawMax = json['is_maximized'];

    final parsedWidth = (rawWidth is num && rawWidth.isFinite && rawWidth > 0)
        ? rawWidth.toDouble()
        : defaultWidth;
    final parsedHeight =
        (rawHeight is num && rawHeight.isFinite && rawHeight > 0)
            ? rawHeight.toDouble()
            : defaultHeight;

    final width = parsedWidth < minWidth ? minWidth : parsedWidth;
    final height = parsedHeight < minHeight ? minHeight : parsedHeight;

    final x = (rawX is num && rawX.isFinite) ? rawX.toDouble() : null;
    final y = (rawY is num && rawY.isFinite) ? rawY.toDouble() : null;
    final isMaximized = (rawMax is bool) ? rawMax : false;

    return WindowPreferences(
      width: width,
      height: height,
      x: x,
      y: y,
      isMaximized: isMaximized,
    );
  }

  WindowPreferences copyWith({
    double? width,
    double? height,
    double? x,
    double? y,
    bool? isMaximized,
  }) {
    return WindowPreferences(
      width: width ?? this.width,
      height: height ?? this.height,
      x: x ?? this.x,
      y: y ?? this.y,
      isMaximized: isMaximized ?? this.isMaximized,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowPreferences &&
          runtimeType == other.runtimeType &&
          width == other.width &&
          height == other.height &&
          x == other.x &&
          y == other.y &&
          isMaximized == other.isMaximized;

  @override
  int get hashCode => Object.hash(width, height, x, y, isMaximized);

  @override
  String toString() =>
      'WindowPreferences(width: $width, height: $height, x: $x, y: $y, isMaximized: $isMaximized)';
}

/// Service managing desktop window bounds persistence, boundary checking,
/// debounce saves and restoration.
class DesktopWindowService {
  static const String preferenceKey = 'windowPreferences';
  static WindowPreferences? _currentPreferences;
  static Timer? _debounceTimer;

  static WindowPreferences get currentPreferences =>
      _currentPreferences ?? const WindowPreferences();

  @visibleForTesting
  static void setCurrentForTesting(WindowPreferences? prefs) {
    _currentPreferences = prefs;
  }

  @visibleForTesting
  static bool get hasPendingDebounce =>
      _debounceTimer != null && _debounceTimer!.isActive;

  /// Loads saved window preferences from Settings.workspace_drafts_json.
  /// Falls back to defaults if not found, corrupt, or on error.
  static Future<WindowPreferences> load(DatabaseHelper dbHelper) async {
    try {
      final generation = dbHelper.captureGeneration();
      final rows = await dbHelper.read(
        generation,
        (db) => db.query(
          'Settings',
          columns: ['workspace_drafts_json'],
          where: 'id = ?',
          whereArgs: ['default'],
        ),
      );
      if (rows.isEmpty) return const WindowPreferences();
      final rawDrafts = rows.first['workspace_drafts_json'] as String?;
      if (rawDrafts == null || rawDrafts.isEmpty) {
        return const WindowPreferences();
      }
      final decoded = jsonDecode(rawDrafts);
      if (decoded is! Map<String, dynamic>) {
        return const WindowPreferences();
      }
      final rawPrefs = decoded[preferenceKey];
      if (rawPrefs is! Map<String, dynamic>) {
        return const WindowPreferences();
      }
      return WindowPreferences.fromJson(rawPrefs);
    } catch (_) {
      return const WindowPreferences();
    }
  }

  /// Saves window preferences into Settings.workspace_drafts_json.
  static Future<void> save(
    DatabaseHelper dbHelper,
    WindowPreferences prefs,
  ) async {
    try {
      final generation = dbHelper.captureGeneration();
      await dbHelper.writeTransaction(generation, (db) async {
        final rows = await db.query(
          'Settings',
          columns: ['workspace_drafts_json'],
          where: 'id = ?',
          whereArgs: ['default'],
        );
        Map<String, dynamic> drafts = {};
        if (rows.isNotEmpty) {
          final rawDrafts = rows.first['workspace_drafts_json'] as String?;
          if (rawDrafts != null && rawDrafts.isNotEmpty) {
            final decoded = jsonDecode(rawDrafts);
            if (decoded is Map<String, dynamic>) {
              drafts = Map<String, dynamic>.from(decoded);
            }
          }
        }
        drafts[preferenceKey] = prefs.toJson();
        final encoded = jsonEncode(drafts);
        await db.update(
          'Settings',
          {'workspace_drafts_json': encoded},
          where: 'id = ?',
          whereArgs: ['default'],
        );
      });
      _currentPreferences = prefs;
    } catch (e) {
      debugPrint('Failed to save window preferences: $e');
    }
  }

  /// Clamps and validates window preferences against connected screen bounds.
  /// If the window top bar is off-screen (e.g. disconnected monitor or corrupt coordinates),
  /// falls back to centered on the primary display.
  static WindowPreferences validateAndClamp({
    required WindowPreferences prefs,
    required List<Rect> displayBounds,
    Rect? primaryDisplayBounds,
    double minWidth = WindowPreferences.minWidth,
    double minHeight = WindowPreferences.minHeight,
  }) {
    if (displayBounds.isEmpty) {
      displayBounds = const [Rect.fromLTWH(0, 0, 1920, 1080)];
    }
    final primary = primaryDisplayBounds ?? displayBounds.first;

    final maxAvailableWidth = displayBounds
        .map((d) => d.width)
        .reduce(math.max);
    final maxAvailableHeight = displayBounds
        .map((d) => d.height)
        .reduce(math.max);

    final clampedWidth = prefs.width.clamp(
      minWidth,
      math.max(minWidth, maxAvailableWidth),
    ).toDouble();
    final clampedHeight = prefs.height.clamp(
      minHeight,
      math.max(minHeight, maxAvailableHeight),
    ).toDouble();

    if (prefs.x == null || prefs.y == null) {
      final centerX = primary.left + (primary.width - clampedWidth) / 2;
      final centerY = primary.top + (primary.height - clampedHeight) / 2;
      return WindowPreferences(
        width: clampedWidth,
        height: clampedHeight,
        x: centerX,
        y: centerY,
        isMaximized: prefs.isMaximized,
      );
    }

    final titleBar = Rect.fromLTWH(prefs.x!, prefs.y!, clampedWidth, 40);
    final isVisibleOnAnyDisplay = displayBounds.any((display) {
      final intersection = display.intersect(titleBar);
      return intersection.width >= 100 && intersection.height >= 20;
    });

    if (!isVisibleOnAnyDisplay) {
      final centerX = primary.left + (primary.width - clampedWidth) / 2;
      final centerY = primary.top + (primary.height - clampedHeight) / 2;
      return WindowPreferences(
        width: clampedWidth,
        height: clampedHeight,
        x: centerX,
        y: centerY,
        isMaximized: prefs.isMaximized,
      );
    }

    return WindowPreferences(
      width: clampedWidth,
      height: clampedHeight,
      x: prefs.x,
      y: prefs.y,
      isMaximized: prefs.isMaximized,
    );
  }

  /// Queries all connected display viewports.
  static Future<List<Rect>> getDisplayBounds({MethodChannel? channel}) async {
    final methodChannel =
        channel ??
        const MethodChannel('dev.leanflutter.plugins/screen_retriever');
    try {
      final dynamic result = await methodChannel.invokeMethod(
        'getAllDisplays',
        {'devicePixelRatio': 1.0},
      );
      if (result != null && result is Map && result['displays'] is List) {
        final displays = (result['displays'] as List)
            .cast<Map<dynamic, dynamic>>()
            .map((item) {
              final size = item['visibleSize'] ?? item['size'];
              final pos =
                  item['visiblePosition'] ?? const {'dx': 0.0, 'dy': 0.0};
              final width = (size['width'] as num?)?.toDouble() ?? 1920.0;
              final height = (size['height'] as num?)?.toDouble() ?? 1080.0;
              final dx = (pos['dx'] as num?)?.toDouble() ?? 0.0;
              final dy = (pos['dy'] as num?)?.toDouble() ?? 0.0;
              return Rect.fromLTWH(dx, dy, width, height);
            })
            .toList();
        if (displays.isNotEmpty) return displays;
      }
    } catch (_) {}

    try {
      final flutterDisplays = PlatformDispatcher.instance.displays;
      if (flutterDisplays.isNotEmpty) {
        return flutterDisplays.map((d) {
          final dpr = d.devicePixelRatio > 0 ? d.devicePixelRatio : 1.0;
          return Rect.fromLTWH(0, 0, d.size.width / dpr, d.size.height / dpr);
        }).toList();
      }
    } catch (_) {}

    return const [Rect.fromLTWH(0, 0, 1920, 1080)];
  }

  /// Restores the window geometry on application startup.
  static Future<void> restoreWindow(
    DatabaseHelper dbHelper, {
    WindowManager? wm,
    List<Rect>? mockDisplays,
  }) async {
    final manager = wm ?? windowManager;
    final savedPrefs = await load(dbHelper);
    final displays = mockDisplays ?? await getDisplayBounds();
    final validated = validateAndClamp(
      prefs: savedPrefs,
      displayBounds: displays,
    );
    _currentPreferences = validated;

    final windowOptions = WindowOptions(
      size: Size(validated.width, validated.height),
      center: validated.x == null || validated.y == null,
      title: "DontForget",
    );

    await manager.waitUntilReadyToShow(windowOptions, () async {
      try {
        if (validated.x != null && validated.y != null) {
          await manager.setPosition(Offset(validated.x!, validated.y!));
        }
        if (validated.isMaximized) {
          await manager.maximize();
        }
        await manager.show();
        await manager.focus();
        StartupTrace.mark('window_shown');
        await manager.setPreventClose(true);
      } catch (e, st) {
        debugPrint('Error showing window: $e\n$st');
      }
    });
  }

  /// Displays default window when storage fails.
  static Future<void> showDefaultFallbackWindow({WindowManager? wm}) async {
    final manager = wm ?? windowManager;
    const windowOptions = WindowOptions(
      size: Size(WindowPreferences.defaultWidth, WindowPreferences.defaultHeight),
      center: true,
      title: "DontForget",
    );
    await manager.waitUntilReadyToShow(windowOptions, () async {
      try {
        await manager.show();
        await manager.focus();
        await manager.setPreventClose(true);
      } catch (_) {}
    });
  }

  /// Records normal bounds changes (moved or resized) with debounce (>= 500ms).
  static void recordBoundsChanged({
    required DatabaseHelper dbHelper,
    required Rect bounds,
    Duration debounceDuration = const Duration(milliseconds: 500),
  }) {
    _currentPreferences = currentPreferences.copyWith(
      width: bounds.width,
      height: bounds.height,
      x: bounds.left,
      y: bounds.top,
      isMaximized: false,
    );
    _scheduleSave(dbHelper, debounceDuration);
  }

  /// Records maximize / unmaximize state changes with debounce.
  static void recordMaximizeChanged({
    required DatabaseHelper dbHelper,
    required bool isMaximized,
    Duration debounceDuration = const Duration(milliseconds: 500),
  }) {
    _currentPreferences = currentPreferences.copyWith(
      isMaximized: isMaximized,
    );
    _scheduleSave(dbHelper, debounceDuration);
  }

  static void _scheduleSave(DatabaseHelper dbHelper, Duration delay) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, () {
      final toSave = _currentPreferences;
      if (toSave != null) {
        save(dbHelper, toSave).catchError((Object error) {
          debugPrint('Failed to save window bounds: $error');
        });
      }
    });
  }

  /// Flushes any pending debounced preference write immediately.
  static Future<void> flush(DatabaseHelper dbHelper) async {
    if (_debounceTimer != null) {
      _debounceTimer!.cancel();
      _debounceTimer = null;
    }
    final toSave = _currentPreferences;
    if (toSave != null) {
      await save(dbHelper, toSave);
    }
  }
}
