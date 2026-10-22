import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import '../benchmark/frame_diagnostics.dart';

class _Service implements VmService {
  int process = 42;
  int disposals = 0;
  bool rejectEnable = false;
  bool rejectRestore = false;
  bool rejectCapture = false;
  final flags = <List<String>>[];
  int? origin;
  int? extent;

  @override
  Future<VM> getVM() async => VM(pid: process);
  @override
  Future<TimelineFlags> getVMTimelineFlags() async => TimelineFlags(
    availableStreams: ['Dart', 'GC', 'Embedder'],
    recordedStreams: ['GC'],
    recorderName: 'Ring',
  );
  @override
  Future<Success> setVMTimelineFlags(List<String> streams) async {
    flags.add([...streams]);
    if ((streams.length == 3 && rejectEnable) ||
        (streams.length == 1 && rejectRestore)) {
      throw StateError('Injected RPC failure');
    }
    return Success();
  }

  @override
  Future<Success> clearVMTimeline() async => Success();
  @override
  Future<Timeline> getVMTimeline({
    int? timeOriginMicros,
    int? timeExtentMicros,
  }) async {
    origin = timeOriginMicros;
    extent = timeExtentMicros;
    if (rejectCapture) throw StateError('private-auth-token');
    return Timeline(
      traceEvents: [
        TimelineEvent.parse({
          'name': 'Layout',
          'ph': 'X',
          'ts': timeOriginMicros,
          'dur': 4,
        })!,
      ],
    );
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late (bool, bool, bool) original;
  setUp(
    () => original = (
      debugProfileBuildsEnabled,
      debugProfileLayoutsEnabled,
      debugProfilePaintsEnabled,
    ),
  );
  tearDown(() {
    debugProfileBuildsEnabled = original.$1;
    debugProfileLayoutsEnabled = original.$2;
    debugProfilePaintsEnabled = original.$3;
  });

  test(
    'rejects a different process before changing diagnostic state',
    () async {
      final service = _Service()..process = 999;
      await expectLater(
        FrameDiagnostics.attach(service, expectedPid: 42),
        throwsStateError,
      );
      expect(service.flags, isEmpty);
      expect(service.disposals, 1);
      expect((
        debugProfileBuildsEnabled,
        debugProfileLayoutsEnabled,
        debugProfilePaintsEnabled,
      ), original);
    },
  );

  test('captures the exact frame interval and restores flags once', () async {
    final service = _Service();
    final session = await FrameDiagnostics.attach(service, expectedPid: 42);
    expect(
      debugProfileBuildsEnabled &&
          debugProfileLayoutsEnabled &&
          debugProfilePaintsEnabled,
      isTrue,
    );
    final capture = await session.capture(100, 150);
    expect((service.origin, service.extent), (100, 50));
    expect(capture['events'], hasLength(1));
    await session.close();
    await session.close();
    expect(service.flags, [
      ['Dart', 'GC', 'Embedder'],
      ['GC'],
    ]);
    expect(service.disposals, 1);
    expect((
      debugProfileBuildsEnabled,
      debugProfileLayoutsEnabled,
      debugProfilePaintsEnabled,
    ), original);
    await expectLater(session.capture(100, 150), throwsStateError);
  });

  test(
    'uncertain enable failure still restores the prior VM streams',
    () async {
      final service = _Service()..rejectEnable = true;
      await expectLater(
        FrameDiagnostics.attach(service, expectedPid: 42),
        throwsStateError,
      );
      expect(service.flags.last, ['GC']);
      expect(service.disposals, 1);
    },
  );

  test('capture errors do not expose connection authentication text', () async {
    final service = _Service()..rejectCapture = true;
    final session = await FrameDiagnostics.attach(service, expectedPid: 42);
    await expectLater(
      session.capture(100, 150),
      throwsA(
        predicate(
          (e) =>
              e is StateError && !e.toString().contains('private-auth-token'),
        ),
      ),
    );
    await session.close();
  });

  test(
    'restore failure still restores Flutter flags and disposes transport',
    () async {
      final service = _Service();
      final session = await FrameDiagnostics.attach(service, expectedPid: 42);
      service.rejectRestore = true;
      await expectLater(session.close(), throwsStateError);
      expect(service.disposals, 1);
      expect((
        debugProfileBuildsEnabled,
        debugProfileLayoutsEnabled,
        debugProfilePaintsEnabled,
      ), original);
    },
  );
}
