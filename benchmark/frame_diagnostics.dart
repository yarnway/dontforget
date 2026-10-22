// Opt-in profile-harness diagnostics. Never imported by product lib/.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Connect only to this process's authenticated loopback VM service. No VM URI
/// or authentication token is saved in a report or advertised over Bonjour.
class FrameDiagnostics {
  FrameDiagnostics._(this._service, this._oldStreams);
  final VmService _service;
  final List<String> _oldStreams;
  final _oldBuilds = debugProfileBuildsEnabled;
  final _oldLayouts = debugProfileLayoutsEnabled;
  final _oldPaints = debugProfilePaintsEnabled;
  bool _armed = false;
  bool _closed = false;
  static const _timeout = Duration(seconds: 10);

  static Future<FrameDiagnostics> start() async {
    VmService? service;
    try {
      final uri = (await developer.Service.getInfo()).serverUri;
      if (uri == null ||
          uri.scheme != 'http' ||
          !['127.0.0.1', '::1'].contains(uri.host)) {
        throw StateError('An owned loopback profile VM service is required');
      }
      var abandoned = false;
      final connection = vmServiceConnectUri(
        uri.resolve('ws').replace(scheme: 'ws').toString(),
      );
      unawaited(
        connection.then((lateService) async {
          if (abandoned) await lateService.dispose();
        }, onError: (Object _, StackTrace _) {}),
      );
      service = await connection.timeout(
        _timeout,
        onTimeout: () {
          abandoned = true;
          throw TimeoutException('Loopback service connection timed out');
        },
      );
      return await attach(service, expectedPid: pid);
    } catch (error) {
      await service?.dispose();
      // Connection exceptions can include the authenticated URL.
      throw StateError('Frame diagnostics unavailable: ${error.runtimeType}');
    }
  }

  // Also used by the harness's service-boundary regression tests.
  static Future<FrameDiagnostics> attach(
    VmService service, {
    required int expectedPid,
  }) async {
    FrameDiagnostics? session;
    try {
      final vm = await service.getVM().timeout(_timeout);
      if (vm.pid != expectedPid) throw StateError('VM process mismatch');
      final flags = await service.getVMTimelineFlags().timeout(_timeout);
      if (![
        'Dart',
        'GC',
        'Embedder',
      ].every((name) => flags.availableStreams?.contains(name) ?? false)) {
        throw StateError('Required timeline streams unavailable');
      }
      session = FrameDiagnostics._(service, [...?flags.recordedStreams]);
      // A failed RPC can have taken effect. Always restore before disposal.
      session._armed = true;
      await service
          .setVMTimelineFlags(['Dart', 'GC', 'Embedder'])
          .timeout(_timeout);
      debugProfileBuildsEnabled = true;
      debugProfileLayoutsEnabled = true;
      debugProfilePaintsEnabled = true;
      await service.clearVMTimeline().timeout(_timeout);
      return session;
    } catch (_) {
      if (session != null) {
        await session.close();
      } else {
        await service.dispose();
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> capture(int from, int to) async {
    if (_closed || to <= from) throw StateError('Invalid frame capture');
    try {
      final timeline = await _service
          .getVMTimeline(timeOriginMicros: from, timeExtentMicros: to - from)
          .timeout(_timeout);
      final events = timeline.traceEvents;
      if (events == null || events.isEmpty || events.length > 50000) {
        throw StateError('Missing or oversized frame timeline');
      }
      return {
        'scope':
            'Instrumented replacement frame; includes old-tree disposal; not comparable to uninstrumented baseline timings',
        'from_us': from,
        'to_us': to,
        'vm_trace_origin_us': timeline.timeOriginMicros,
        'vm_trace_extent_us': timeline.timeExtentMicros,
        'events': events.map((event) => event.toJson()).toList(),
      };
    } catch (error) {
      throw StateError('Frame capture failed: ${error.runtimeType}');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    debugProfileBuildsEnabled = _oldBuilds;
    debugProfileLayoutsEnabled = _oldLayouts;
    debugProfilePaintsEnabled = _oldPaints;
    try {
      if (_armed) {
        await _service.setVMTimelineFlags(_oldStreams).timeout(_timeout);
      }
    } finally {
      await _service.dispose();
    }
  }
}
