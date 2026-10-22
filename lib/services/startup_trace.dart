import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

/// Passive instrumentation for a separately built, isolated product executable.
/// Ordinary builds never construct this observer or write a report. Native
/// notification transport and the actual main/app/provider path stay unchanged.
class StartupTrace with WidgetsBindingObserver, WindowListener {
  static const enabled = bool.fromEnvironment('DONTFORGET_STARTUP_TRACE');
  static const revision = String.fromEnvironment('BENCHMARK_REVISION');
  static StartupTrace? _active;

  static void start() {
    if (enabled &&
        Platform.isMacOS &&
        kReleaseMode &&
        RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) {
      _active = StartupTrace._();
    }
  }

  static void bind() => _active?._bind();
  static void attach(String directory) => _active?._attach(directory);
  static void mark(String name) => _active?._mark(name);
  static void fail(String stage) => _active?._finish('failed:$stage');

  StartupTrace._();
  final _clock = Stopwatch()..start();
  final _entry = DateTime.now().toUtc();
  final _marks = <String, int>{};
  final _events = <Map<String, Object>>[];
  Directory? _directory;
  Timer? _timeout;
  bool _finished = false;

  void _bind() {
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    _event('initial:${WidgetsBinding.instance.lifecycleState?.name}');
    unawaited(
      WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
        _mark('first_frame_rasterized');
      }),
    );
    _timeout = Timer(const Duration(minutes: 3), () => _finish('timeout'));
  }

  void _attach(String path) {
    // Never enable diagnostics against the normal user's app container, even
    // if an instrumented executable was accidentally launched with its old ID.
    if (!RegExp(
      r'/Containers/com\.example\.dontForget\.acceptance\.[a-zA-Z0-9-]+/Data/',
    ).hasMatch(path)) {
      _finish('isolation_required');
      return;
    }
    _directory = Directory(p.join(p.dirname(path), 'startup-traces'));
  }

  void _mark(String name) {
    if (_finished) return;
    _marks.putIfAbsent(name, () => _clock.elapsedMicroseconds);
    if (const [
      'storage_ready',
      'settings_loaded',
      'tasks_loaded',
      'notifications_ready',
      'routes_ready_frame',
      'first_frame_rasterized',
    ].every(_marks.containsKey)) {
      _finish('complete');
    }
  }

  void _event(String name) {
    if (!_finished && _events.length < 128) {
      _events.add({'event': name, 'elapsed_us': _clock.elapsedMicroseconds});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _event('lifecycle:${state.name}');
  @override
  void onWindowFocus() => _event('focus');
  @override
  void onWindowBlur() => _event('blur');
  @override
  void onWindowMinimize() => _event('minimize');
  @override
  void onWindowRestore() => _event('restore');

  void _finish(String outcome) {
    if (_finished) return;
    _finished = true;
    final elapsed = _clock.elapsedMicroseconds;
    _timeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    unawaited(
      _write(outcome, elapsed).catchError((Object _) {
        // Measurement failure must not change normal product startup or recovery.
        debugPrint('Startup measurement could not be saved.');
      }),
    );
  }

  Future<void> _write(String outcome, int elapsed) async {
    final directory = _directory;
    if (directory == null) return;
    final window = <String, Object?>{};
    try {
      window.addAll({
        'focused': await windowManager.isFocused().timeout(
          const Duration(seconds: 3),
        ),
        'visible': await windowManager.isVisible().timeout(
          const Duration(seconds: 3),
        ),
        'minimized': await windowManager.isMinimized().timeout(
          const Duration(seconds: 3),
        ),
        'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
      });
    } catch (_) {
      window['status'] = 'unavailable';
    }
    await directory.create(recursive: true);
    if (await directory.resolveSymbolicLinks() != directory.path) {
      throw const FileSystemException('Unsafe startup report directory');
    }
    final file = File(
      p.join(directory.path, '${_entry.microsecondsSinceEpoch}-$pid.json'),
    );
    final staging = File('${file.path}.tmp');
    await staging.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'scope':
            'Actual product lib/main.dart release startup; real OS notification transport; passive instrumentation. First raster is the framework completion signal, not a GPU duration.',
        'revision': revision,
        'pid': pid,
        'build_mode': 'release',
        'dart_entry_utc': _entry.toIso8601String(),
        'outcome': outcome,
        'elapsed_to_outcome_us': elapsed,
        'milestones_us': _marks,
        'window_events': _events,
        'window_at_outcome': window,
        'dart': Platform.version,
        'os': Platform.operatingSystemVersion,
      }),
      flush: true,
    );
    await staging.rename(file.path);
  }
}
