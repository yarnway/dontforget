import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/providers/home_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recorder = MethodChannel('com.llfbandit.record/messages');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late ProviderContainer container;
  late List<MethodCall> calls;
  late Completer<void> disposed;
  bool permitted = true;
  bool failStart = false;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dontforget-recording-');
    calls = [];
    disposed = Completer<void>();
    permitted = true;
    failStart = false;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(recorder, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'create':
          return null;
        case 'hasPermission':
          return permitted;
        case 'start':
          if (failStart) throw PlatformException(code: 'device_unavailable');
          return null;
        case 'stop':
          return null; // No audio file or external AI request in this test.
        case 'dispose':
          disposed.complete();
          return null;
        default:
          throw UnsupportedError(call.method);
      }
    });
    container = ProviderContainer();
    container.read(homeControllerProvider);
  });

  tearDown(() async {
    container.dispose();
    await disposed.future;
    messenger.setMockMethodCallHandler(recorder, null);
    messenger.setMockMethodCallHandler(paths, null);
    await directory.delete(recursive: true);
  });

  test(
    'recording uses explicit AAC config and stops without inventing an audio file',
    () async {
      final controller = container.read(homeControllerProvider.notifier);
      expect(await controller.startRecording(), isTrue);
      expect(container.read(homeControllerProvider).isRecording, isTrue);
      final start = calls.singleWhere((call) => call.method == 'start');
      final args = start.arguments as Map;
      expect(args['path'], startsWith(directory.path));
      expect(args['path'], endsWith('.m4a'));
      expect(args['encoder'], 'aacLc');
      await controller.stopRecordingAndProcess();
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(container.read(homeControllerProvider).pendingTasksCount, 0);
      expect(calls.where((call) => call.method == 'stop'), hasLength(1));
    },
  );

  test('permission denial does not start recording', () async {
    permitted = false;
    expect(
      await container.read(homeControllerProvider.notifier).startRecording(),
      isFalse,
    );
    expect(container.read(homeControllerProvider).isRecording, isFalse);
    expect(calls.where((call) => call.method == 'start'), isEmpty);
  });

  test(
    'native start failure leaves recording off and reports an error',
    () async {
      failStart = true;
      expect(
        await container.read(homeControllerProvider.notifier).startRecording(),
        isFalse,
      );
      expect(container.read(homeControllerProvider).isRecording, isFalse);
      expect(
        container.read(homeControllerProvider).error,
        contains('device_unavailable'),
      );
    },
  );
}
