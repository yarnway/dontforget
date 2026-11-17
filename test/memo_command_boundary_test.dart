import 'package:dont_forget/providers/home_controller.dart';
import 'package:dont_forget/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'support/offline_management_harness.dart';

class _Recorder implements AudioRecorder {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation call) => super.noSuchMethod(call);
}

void main() {
  late OfflineManagementHarness h;
  late ProviderContainer child;
  int commandReads = 0;
  setUp(() async {
    h = OfflineManagementHarness();
    await h.create();
    commandReads = 0;
    child = ProviderContainer(
      parent: h.container,
      overrides: [
        homeControllerProvider.overrideWith(
          (ref) => HomeController(ref, audioRecorder: _Recorder()),
        ),
        multiAgentServiceProvider.overrideWith((ref) {
          commandReads++;
          throw StateError(
            'No agent or network execution in a memo boundary test',
          );
        }),
      ],
    );
  });
  tearDown(() async {
    child.dispose();
    await h.dispose();
  });
  for (final prefix in ['/agent', '/goal']) {
    test(
      'memo-only preserves literal $prefix content without routing commands',
      () async {
        final home = child.read(homeControllerProvider.notifier);
        final text = '  $prefix 明天9点保留这段分享原文\n第二行  ';
        expect(
          await home.processText(
            text,
            memoOnly: true,
            captureId: 'shared-command',
          ),
          isTrue,
        );
        expect(commandReads, 0);
        final row = await h.row('shared-command');
        expect(row.sourceText, text);
        expect(row.taskSummary, text);
        expect(row.triggerTime, isNull);
        expect(row.capturePending, isFalse);
        expect(h.notifications.scheduled, isEmpty);
        expect(await h.rows(), hasLength(1));
      },
    );
    test('explicit $prefix input still uses the command route', () async {
      final home = child.read(homeControllerProvider.notifier);
      expect(await home.processText('$prefix explicit command'), isFalse);
      expect(commandReads, 1);
      expect(await h.rows(), isEmpty);
    });
  }
}
