// This is a separate, opt-in executable, never the product entrypoint.
// Test-only database construction guarantees every read/write stays in a new
// synthetic directory. Build with --profile and prepare a unique sandbox ID.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase;

import 'package:crypto/crypto.dart';
import 'notification_startup.dart';
import 'package:dont_forget/data/database_helper.dart';
import 'package:dont_forget/l10n/app_localizations.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:dont_forget/services/task_search_index.dart';
import 'package:dont_forget/ui/widgets/inline_feedback.dart';
import 'package:dont_forget/ui/widgets/task_board.dart';
import 'package:dont_forget/ui/widgets/task_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

const _boardHeight = 792.0;
const _windowHeight = 940.0;

const _revision = String.fromEnvironment('BENCHMARK_REVISION');
final _entryClock = Stopwatch();

Map<String, Object> distribution(List<int> values) {
  if (values.isEmpty) throw StateError('No measured samples');
  final sorted = [...values]..sort();
  return {
    'samples': sorted.length,
    'p50_us': sorted[(sorted.length * .5).ceil() - 1],
    'p95_us': sorted[(sorted.length * .95).ceil() - 1],
    'max_us': sorted.last,
  };
}

List<Reminder> syntheticTasks(int count, DateTime now) => List.generate(
  count,
  (i) => Reminder(
    id: 'synthetic-$i',
    taskTitle: 'Synthetic task $i',
    taskSummary: 'Review documentation and milestones $i',
    subTasks: jsonEncode(['Review checklist $i', '准备发布说明 $i']),
    quadrantLevel: i % 4 + 1,
    createdAt: now,
    triggerTime: now.add(const Duration(days: 1)),
  ),
);

Future<void> main() async {
  // Top-level Dart fields are lazy: initialize/start before any await, not at
  // the first report read after rasterization.
  _entryClock.start();
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS ||
      !kProfileMode ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(_revision)) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'This isolated benchmark requires macOS profile mode and an exact source revision.',
            ),
          ),
        ),
      ),
    );
    return;
  }
  sqfliteFfiInit();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1440, _windowHeight),
      minimumSize: Size(375, 800),
      title: 'DontForget · Isolated performance benchmark',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const _Benchmark());
}

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark>
    with WidgetsBindingObserver, WindowListener {
  GlobalKey _boardKey = GlobalKey();
  final _timings = <FrameTiming>[];
  List<Reminder>? _tasks;
  DatabaseHelper? _database;
  int _boardVersion = 0;
  String _progress = 'Preparing isolated data…';
  final _results = <Map<String, Object>>[];
  Directory? _root;
  final _errors = <String>[];
  int? _entryToFrame;
  bool _running = false;
  bool _includeNotificationStartup = true;
  final _windowEvents = <Map<String, Object>>[];
  final _segments = <Map<String, Object?>>[];

  void _event(String name) =>
      _windowEvents.add({'event': name, 'timeline_us': developer.Timeline.now});

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

  Future<Map<String, Object?>> _windowState() async => {
    'focused': await windowManager.isFocused().timeout(
      const Duration(seconds: 5),
    ),
    'visible': await windowManager.isVisible().timeout(
      const Duration(seconds: 5),
    ),
    'minimized': await windowManager.isMinimized().timeout(
      const Duration(seconds: 5),
    ),
    'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
  };

  bool _foreground(Map<String, Object?> state) =>
      state['focused'] == true &&
      state['visible'] == true &&
      state['minimized'] == false &&
      state['lifecycle'] == 'resumed';

  Future<void> _prepareForeground() async {
    // The explicit Start action may arrive through accessibility before macOS
    // has activated the window. Activate once, then require observed readiness.
    await windowManager.show();
    await windowManager.focus();
    final watch = Stopwatch()..start();
    while (!_foreground(await _windowState())) {
      if (watch.elapsed >= const Duration(seconds: 10)) {
        throw StateError('Benchmark window did not become foreground');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<T> _segment<T>(String label, Future<T> Function() action) async {
    final before = await _windowState();
    final eventIndex = _windowEvents.length;
    final watch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      watch.stop();
      final after = await _windowState();
      final events = _windowEvents.skip(eventIndex).toList();
      _segments.add({
        'label': label,
        'wall_us': watch.elapsedMicroseconds,
        'before': before,
        'after': after,
        'events': events,
        'uninterrupted_foreground':
            _foreground(before) &&
            _foreground(after) &&
            events.every(
              (e) => e['event'] == 'focus' || e['event'] == 'lifecycle:resumed',
            ),
      });
    }
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_receiveTimings);
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      _entryToFrame = _entryClock.elapsedMicroseconds;
    });
  }

  void _receiveTimings(List<FrameTiming> values) => _timings.addAll(values);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    SchedulerBinding.instance.removeTimingsCallback(_receiveTimings);
    super.dispose();
  }

  Future<void> _frame() async {
    await SchedulerBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 10),
    );
  }

  Future<void> _record(String phase) async {
    final root = _root;
    if (root == null) return;
    final report = {
      'scope':
          'Synthetic macOS profile harness; storage startup excludes reconciliation; full notification startup uses a recording OS transport; frames are real engine timings. Foreground validity is recorded per segment, never inferred from completion.',
      'source_revision': _revision,
      'fixture_version': 2,
      'viewport_protocol': 'fixed-height-792-v1',
      'first_frame_protocol':
          'one warmup then five fresh board/provider mounts',
      'notification_startup_included': _includeNotificationStartup,
      'fixture_source':
          'Exact task rows from KaPI1r baseline; notification-only copy uses fixed 2099 trigger',
      'segments': _segments,
      'window_events': _windowEvents,
      'build_mode': 'profile',
      'phase': phase,
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
      'dart': Platform.version,
      'os': Platform.operatingSystemVersion,
      'harness_entry_to_first_raster_us': _entryToFrame,
      'errors': _errors,
      'results': _results,
    };
    final temporary = File('${root.path}/results.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    await temporary.rename('${root.path}/results.json');
  }

  Future<void> _status(String message) async {
    if (!mounted) throw StateError('Benchmark window closed');
    setState(() => _progress = message);
    await _frame();
    await _record(message);
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() => _running = true);
    _results.clear();
    _segments.clear();
    _windowEvents.clear();
    _errors.clear();
    try {
      final support = await getApplicationSupportDirectory();
      _root = await Directory(support.path).createTemp('isolated-performance-');
      stdout.writeln('ISOLATED_BENCHMARK_RESULT=${_root!.path}/results.json');
      await _prepareForeground();
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized.timeout(
        const Duration(seconds: 10),
      );
      for (final count in [100, 1000, 10000]) {
        await _status(
          'Measuring $count synthetic tasks: storage startup and backup',
        );
        final directory = await Directory(
          '${_root!.path}/tasks-$count',
        ).create();
        final tasks = syntheticTasks(
          count,
          DateTime.parse(switch (count) {
            100 => '2026-10-22T10:21:25.551217',
            1000 => '2026-10-22T10:23:40.074174',
            _ => '2026-10-22T10:24:00.391143',
          }),
        );
        var helper = DatabaseHelper.forTesting(
          directory.path,
          databaseFactoryFfi,
        );
        try {
          final db = await helper.database;
          final batch = db.batch();
          for (final task in tasks) {
            batch.insert('Reminders', task.toJson());
          }
          await batch.commit(noResult: true);
        } finally {
          await helper.close(createBackup: false);
        }
        final startup = <int>[];
        List<Reminder> loaded = [];
        await _segment('$count storage startup', () async {
          for (var sample = 0; sample < 6; sample++) {
            helper = DatabaseHelper.forTesting(
              directory.path,
              databaseFactoryFfi,
            );
            final watch = Stopwatch()..start();
            final container = ProviderContainer(
              overrides: [
                databaseHelperProvider.overrideWithValue(helper),
                remindersProvider.overrideWith(
                  (_) => RemindersNotifier(helper, runLoadEffects: false),
                ),
              ],
            );
            final settings = container.read(settingsProvider.notifier);
            final reminders = container.read(remindersProvider.notifier);
            try {
              await Future.wait([settings.ready, reminders.ready]);
              watch.stop();
              if (sample > 0) startup.add(watch.elapsedMicroseconds);
              loaded = [...container.read(remindersProvider)];
              if (loaded.length != count ||
                  container.read(settingsProvider).apiKey.isNotEmpty) {
                throw StateError('Synthetic storage fixture mismatch');
              }
            } finally {
              container.dispose();
              await helper.close(createBackup: false);
            }
          }
        });
        helper = DatabaseHelper.forTesting(directory.path, databaseFactoryFfi);
        _database = helper;
        await helper.database;
        final backups = <int>[];
        await _segment('$count backup', () async {
          for (var sample = 0; sample < 6; sample++) {
            final watch = Stopwatch()..start();
            await helper.createMirrorBackup();
            watch.stop();
            if (sample > 0) backups.add(watch.elapsedMicroseconds);
            await _verifyBackup(directory, tasks);
          }
        });
        final indexBuild = Stopwatch()..start();
        final index = TaskSearchIndex(loaded);
        indexBuild.stop();
        final searches = <int>[];
        for (var sample = 0; sample < 52; sample++) {
          final watch = Stopwatch()..start();
          final found = index.search('发布说明 9');
          watch.stop();
          if (found.isEmpty) throw StateError('Search fixture mismatch');
          if (sample > 1) searches.add(watch.elapsedMicroseconds);
        }
        final result = <String, Object>{
          'tasks': count,
          'task_rows_sha256': sha256
              .convert(
                utf8.encode(jsonEncode(tasks.map((r) => r.toJson()).toList())),
              )
              .toString(),
          'storage_startup': distribution(startup),
          'consistent_backup': distribution(backups),
          'search_index_build_us': indexBuild.elapsedMicroseconds,
          'indexed_search': distribution(searches),
          'backup_json_bytes': await File(
            '${directory.path}/ha_snapshot.json',
          ).length(),
          'backup_mirror_bytes': await File(
            '${directory.path}/dont_forget_v3.mirror.db',
          ).length(),
          'views': <Map<String, Object>>[],
        };
        _results.add(result);
        try {
          for (final width in [375.0, 768.0, 1440.0]) {
            await _status(
              'Measuring $count tasks: ${width.toInt()}px list frames',
            );
            (result['views'] as List<Map<String, Object>>).add(
              await _segment(
                '$count board $width',
                () => _measureBoard(loaded, width),
              ),
            );
            await _record(_progress);
          }
        } finally {
          if (mounted) setState(() => _tasks = null);
          try {
            await _frame();
          } finally {
            // A hidden window stops producing frames. Resource release must
            // still happen when the frame wait itself times out.
            await helper.close(createBackup: false);
            _database = null;
          }
        }
        result['process_rss_bytes_after_size'] = ProcessInfo.currentRss;
        if (_includeNotificationStartup) {
          await _status(
            'Measuring $count complete startup notifications (recording OS transport)',
          );
          final notificationTasks = tasks
              .map((r) => r.copyWith(triggerTime: DateTime.utc(2099, 1, 1)))
              .toList();
          result['notification_task_rows_sha256'] = sha256
              .convert(
                utf8.encode(
                  jsonEncode(notificationTasks.map((r) => r.toJson()).toList()),
                ),
              )
              .toString();
          result['full_notification_startup'] = await _segment(
            '$count full notification startup',
            () => measureNotificationStartup(
              Directory('${_root!.path}/notifications-$count'),
              notificationTasks,
            ),
          );
          await _record(_progress);
        }
      }
      await _status(
        'Completed. Synthetic data and results are preserved for review.',
      );
      await _record('complete');
    } catch (error) {
      _errors.add(error.toString());
      if (mounted) setState(() => _progress = 'Benchmark failed: $error');
      await _record('failed');
    } finally {
      if (mounted) setState(() => _tasks = null);
      final database = _database;
      _database = null;
      try {
        await database?.close(createBackup: false);
      } catch (error) {
        _errors.add('Database cleanup failed: $error');
        await _record('failed');
      }
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _verifyBackup(Directory directory, List<Reminder> tasks) async {
    final data =
        jsonDecode(
              await File('${directory.path}/ha_snapshot.json').readAsString(),
            )
            as Map;
    final expected = {for (final task in tasks) task.id: task.toJson()};
    final rows = data['reminders'] as List;
    if (data['version'] != DatabaseHelper.schemaVersion ||
        rows.length != tasks.length) {
      throw StateError('Backup JSON count/schema mismatch');
    }
    for (final row in rows) {
      if (!mapEquals(row as Map, expected[row['id']])) {
        throw StateError('Backup row mismatch');
      }
    }
    final mirror = await databaseFactoryFfi.openDatabase(
      '${directory.path}/dont_forget_v3.mirror.db',
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final check = await mirror.rawQuery('PRAGMA integrity_check');
      if (check.single.values.single != 'ok') {
        throw StateError('Mirror integrity failure');
      }
      final mirrorRows = await mirror.query('Reminders');
      if (mirrorRows.length != tasks.length) {
        throw StateError('Mirror count mismatch');
      }
      for (final row in mirrorRows) {
        if (!mapEquals(row, expected[row['id']])) {
          throw StateError('Mirror row mismatch');
        }
      }
    } finally {
      await mirror.close();
    }
  }

  Future<Map<String, Object>> _measureBoard(
    List<Reminder> tasks,
    double width,
  ) async {
    await windowManager
        .setSize(Size(width, _windowHeight))
        .timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _frame();
    final firstFrameIntervals = <(int, int)>[];
    final installTimes = <int>[];
    final viewports = <Map<String, Object>>[];
    for (var sample = 0; sample < 6; sample++) {
      final start = developer.Timeline.now;
      final watch = Stopwatch()..start();
      setState(() {
        _tasks = tasks;
        _boardKey = GlobalKey();
        _boardVersion++;
      });
      await _frame();
      watch.stop();
      final end = developer.Timeline.now;
      final context = _boardKey.currentContext;
      if (context == null || !context.mounted) {
        throw StateError('Benchmark board unavailable');
      }
      final size = (context.findRenderObject() as RenderBox).size;
      if ((size.width - width).abs() > .01 ||
          (size.height - _boardHeight).abs() > .01) {
        throw StateError(
          'Fixed viewport $width x $_boardHeight unavailable: $size',
        );
      }
      viewports.add({
        'sample': sample,
        'warmup': sample == 0,
        'width': size.width,
        'height': size.height,
        'device_pixel_ratio': MediaQuery.devicePixelRatioOf(context),
      });
      if (sample > 0) {
        firstFrameIntervals.add((start, end));
        installTimes.add(watch.elapsedMicroseconds);
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final boardContext = _boardKey.currentContext!;
    if (!boardContext.mounted) throw StateError('Benchmark window closed');
    final pixelRatio = MediaQuery.devicePixelRatioOf(boardContext);
    final size = (boardContext.findRenderObject() as RenderBox).size;
    if ((size.width - width).abs() > 2) {
      throw StateError('Requested viewport $width unavailable: $size');
    }
    final scrollables = <ScrollableState>[];
    var cards = 0;
    void visit(Element element) {
      if (element.widget is TaskCard) cards++;
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        if (state.position.hasContentDimensions &&
            state.position.maxScrollExtent > 0) {
          scrollables.add(state);
        }
      }
      element.visitChildElements(visit);
    }

    visit(boardContext as Element);
    if (cards > 120 || scrollables.isEmpty) {
      throw StateError('List is not virtualized or scrollable');
    }
    final position = scrollables.first.position;
    position.jumpTo(0);
    await _frame();
    final start = developer.Timeline.now;
    await position
        .animateTo(
          math.min(position.maxScrollExtent, 3000),
          duration: const Duration(seconds: 2),
          curve: Curves.linear,
        )
        .timeout(const Duration(seconds: 10));
    await position
        .animateTo(
          0,
          duration: const Duration(seconds: 2),
          curve: Curves.linear,
        )
        .timeout(const Duration(seconds: 10));
    final end = developer.Timeline.now;
    // Engine timing callbacks are batched; wait before selecting by timestamps.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    bool inside(FrameTiming t, int from, int to) {
      final time = t.timestampInMicroseconds(FramePhase.buildStart);
      return time >= from && time <= to;
    }

    final frames = _timings.where((t) => inside(t, start, end)).toList();
    if (frames.length < 30) {
      throw StateError('Insufficient native frame timing samples');
    }
    final first = firstFrameIntervals
        .map(
          (interval) =>
              _timings.firstWhere((t) => inside(t, interval.$1, interval.$2)),
        )
        .toList();
    final result = <String, Object>{
      'requested_width': width,
      'requested_height': _boardHeight,
      'sample_viewports': viewports,
      'first_board_build_samples_us': first
          .map((t) => t.buildDuration.inMicroseconds)
          .toList(),
      'first_board_total_samples_us': first
          .map((t) => t.totalSpan.inMicroseconds)
          .toList(),
      'actual_width': size.width,
      'height': size.height,
      'device_pixel_ratio': pixelRatio,
      'mounted_cards': cards,
      'install_to_frame_build': distribution(installTimes),
      'first_board_build': distribution(
        first.map((t) => t.buildDuration.inMicroseconds).toList(),
      ),
      'first_board_raster': distribution(
        first.map((t) => t.rasterDuration.inMicroseconds).toList(),
      ),
      'first_board_vsync_wait': distribution(
        first.map((t) => t.vsyncOverhead.inMicroseconds).toList(),
      ),
      'first_board_frame_total': distribution(
        first.map((t) => t.totalSpan.inMicroseconds).toList(),
      ),
      'scroll_build': distribution(
        frames.map((t) => t.buildDuration.inMicroseconds).toList(),
      ),
      'scroll_raster': distribution(
        frames.map((t) => t.rasterDuration.inMicroseconds).toList(),
      ),
      'scroll_wall_us': end - start,
      'scroll_vsync_wait': distribution(
        frames.map((t) => t.vsyncOverhead.inMicroseconds).toList(),
      ),
      'scroll_build_to_raster_gap': distribution(
        frames
            .map(
              (t) =>
                  t.timestampInMicroseconds(FramePhase.rasterStart) -
                  t.timestampInMicroseconds(FramePhase.buildFinish),
            )
            .toList(),
      ),
      'scroll_build_cadence': distribution([
        for (var i = 1; i < frames.length; i++)
          frames[i].timestampInMicroseconds(FramePhase.buildStart) -
              frames[i - 1].timestampInMicroseconds(FramePhase.buildStart),
      ]),
      'scroll_total': distribution(
        frames.map((t) => t.totalSpan.inMicroseconds).toList(),
      ),
      'build_over_16_67ms': frames
          .where((t) => t.buildDuration.inMicroseconds > 16667)
          .length,
      'raster_over_16_67ms': frames
          .where((t) => t.rasterDuration.inMicroseconds > 16667)
          .length,
    };
    _timings.clear();
    return result;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [AppLocalizationsDelegate()],
    builder: (_, child) => InlineFeedback(child: child!),
    home: Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 40,
            child: Center(child: Text(_progress, maxLines: 2)),
          ),
          if (!_running)
            CheckboxListTile(
              value: _includeNotificationStartup,
              onChanged: (value) =>
                  setState(() => _includeNotificationStartup = value ?? true),
              title: const Text(
                'Include full notification startup (can take several minutes)',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          if (!_running)
            FilledButton(
              onPressed: _run,
              child: const Text('Start isolated measurement'),
            ),
          Expanded(
            child: _tasks == null || _database == null
                ? const Center(child: Text('Isolated synthetic benchmark'))
                : ProviderScope(
                    key: ValueKey(_boardVersion),
                    overrides: [
                      databaseHelperProvider.overrideWithValue(_database!),
                    ],
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          key: _boardKey,
                          width: double.infinity,
                          height: _boardHeight,
                          child: TaskBoard(
                            reminders: _tasks!,
                            onPlayMedia: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          if (_root != null)
            SizedBox(
              height: 40,
              child: SelectableText(
                'Results: ${_root!.path}/results.json',
                maxLines: 1,
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      ),
    ),
  );
}
