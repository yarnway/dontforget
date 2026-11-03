import 'dart:async';

import 'package:dont_forget/models/notification_payload.dart';
import 'package:dont_forget/models/reminder.dart';
import 'package:dont_forget/services/android_protocol_service.dart';
import 'package:dont_forget/services/windows_protocol_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final task = Reminder(
    id: 'android-task',
    taskTitle: 'Isolated task',
    quadrantLevel: 1,
    triggerTime: DateTime.utc(2030, 1, 2),
  );
  final payload = NotificationPayload.forReminder(
    task,
    datasetEpoch: '9c2361cc-ea7b-46bd-ab59-5e2873508ff1',
  );
  String action(String verb, {String? minutes}) => Uri(
    scheme: 'dontforget',
    host: 'action',
    path: '/$verb',
    queryParameters: {
      'id': task.id,
      'payload': payload.encode(),
      if (minutes != null) 'minutes': minutes,
    },
  ).toString();

  group('Android protocol validation', () {
    test('view URI preserves encoded task IDs', () {
      final route = parseAndroidProtocolUrl(
        'dontforget://task/Chinese%20%E4%BA%8B%E9%A1%B9',
      );
      expect(route?.action, ProtocolAction.viewTask);
      expect(route?.taskId, 'Chinese 事项');
    });

    test('complete and snooze carry occurrence tokens', () {
      final complete = parseAndroidProtocolUrl(action('complete'))!;
      expect(complete.action, ProtocolAction.completeTask);
      expect(complete.payload?.identity, payload.identity);
      for (final minutes in [null, '15', '60']) {
        final snooze = parseAndroidProtocolUrl(
          action('snooze', minutes: minutes),
        )!;
        expect(snooze.action, ProtocolAction.snoozeTask);
        expect(snooze.snoozeMinutes, minutes == '60' ? 60 : 15);
      }
    });

    for (final raw in <String?>[
      null,
      '',
      ' dontforget://task/a',
      'https://example.com/task/a',
      'dontforget-live://task/a',
      'dontforget://unknown/a',
      'dontforget://task/a/b',
      'dontforget://user@task/a',
      'dontforget://task:123/a',
      'dontforget://task/a#fragment',
      'dontforget://task/a?extra=1',
      'dontforget://task/%00',
      'dontforget://action/complete?id=a',
      'dontforget://action/snooze?id=a&payload=invalid',
      '${action('complete')}&id=another',
      '${action('complete')}&unexpected=1',
      '${action('complete')}&minutes=15',
      action('snooze', minutes: '-1'),
      action('snooze', minutes: '30'),
      action('snooze', minutes: 'invalid'),
      'dontforget://task/${'a' * 9000}',
    ]) {
      test(
        'rejects malformed or unbound URL ${raw?.substring(0, raw.length > 90 ? 90 : raw.length)}',
        () {
          expect(parseAndroidProtocolUrl(raw), isNull);
        },
      );
    }
  });

  group('Android initial and warm intent delivery', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late AndroidProtocolService service;
    late List<ProtocolRoute> received;
    setUp(() {
      service = AndroidProtocolService();
      received = [];
    });
    tearDown(() {
      service.dispose();
      messenger.setMockMethodCallHandler(AndroidProtocolService.channel, null);
    });

    Future<void> send(Object? raw, {String method = 'onProtocolUrl'}) =>
        messenger.handlePlatformMessage(
          AndroidProtocolService.channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method, raw)),
          (_) {},
        );

    test('initial URI is fetched after receiver installation', () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(AndroidProtocolService.channel, (
        call,
      ) async {
        methods.add(call.method);
        return 'dontforget://task/cold';
      });
      await service.initialize(onRoute: received.add);
      await send('dontforget://task/warm');
      expect(methods, ['initialize']);
      expect(received.map((r) => r.taskId), ['cold', 'warm']);
    });

    test('late initial URL cannot replace a newer warm activation', () async {
      final initial = Completer<String?>();
      messenger.setMockMethodCallHandler(
        AndroidProtocolService.channel,
        (_) => initial.future,
      );
      final ready = service.initialize(onRoute: received.add);
      await send('dontforget://task/new');
      initial.complete('dontforget://task/old');
      await ready;
      expect(received.map((r) => r.taskId), ['new']);
    });

    for (final dispose in [false, true]) {
      test(
        'late initial URL is dropped after ${dispose ? 'dispose' : 'recovery'}',
        () async {
          final initial = Completer<String?>();
          messenger.setMockMethodCallHandler(
            AndroidProtocolService.channel,
            (_) => initial.future,
          );
          final ready = service.initialize(onRoute: received.add);
          if (dispose) {
            service.dispose();
          } else {
            service.invalidatePendingInitialization();
          }
          initial.complete('dontforget://task/old');
          await ready;
          expect(received, isEmpty);
          if (!dispose) {
            await send('dontforget://task/after-recovery');
            expect(received.single.taskId, 'after-recovery');
          }
        },
      );
    }

    test('malformed events and unsupported methods do not dispatch', () async {
      messenger.setMockMethodCallHandler(
        AndroidProtocolService.channel,
        (_) async => null,
      );
      await service.initialize(onRoute: received.add);
      await send({'url': 'dontforget://task/a'});
      await send('dontforget://task/a', method: 'unknown');
      await send('dontforget://action/complete?id=a');
      expect(received, isEmpty);
    });

    for (final error in [
      MissingPluginException(),
      PlatformException(code: 'unavailable'),
    ]) {
      test(
        'initialization failure ${error.runtimeType} leaves warm receiver usable',
        () async {
          messenger.setMockMethodCallHandler(
            AndroidProtocolService.channel,
            (_) async => throw error,
          );
          await service.initialize(onRoute: received.add);
          await send('dontforget://task/warm');
          expect(received.single.taskId, 'warm');
        },
      );
    }
  });
}
