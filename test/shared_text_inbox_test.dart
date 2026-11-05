import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dont_forget/providers/workspace_drafts_provider.dart';
import 'package:dont_forget/services/android_share_service.dart';
import 'package:dont_forget/services/shared_text_inbox.dart';
import 'package:dont_forget/services/streaming_backup_service.dart';
import 'package:dont_forget/services/recovery/backup_inspector.dart';
import 'package:dont_forget/services/recovery/database_recovery.dart';
import 'package:dont_forget/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/offline_management_harness.dart';

SharedText item(int n, {String text = '中文 English https://example.com/link'}) =>
    SharedText(
      id: '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
      text: text,
      createdAt: 1762300800000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('durable shared drafts', () {
    late OfflineManagementHarness h;
    late SharedTextInbox inbox;
    late WorkspaceDrafts drafts;
    setUp(() async {
      h = OfflineManagementHarness();
      await h.create();
      drafts = h.container.read(workspaceDraftsProvider.notifier);
      inbox = SharedTextInbox(drafts);
    });
    tearDown(() => h.dispose());
    Future<SharedTextInboxData> data() async => SharedTextInboxData.parse(
      await drafts.readPersistedKey(SharedTextInbox.key),
    );
    test(
      'accept persists before completion without sending or replacing capture/tools',
      () async {
        final capture = {'id': 'existing-capture', 'text': '原输入草稿'};
        await drafts.put('capture', capture);
        await drafts.put('tool', {'text': 'existing tool'});
        expect(await inbox.accept(item(1)), true);
        expect((await data()).items.single.text, item(1).text);
        expect(await drafts.readPersistedKey('capture'), capture);
        expect(await drafts.readPersistedKey('tool'), {
          'text': 'existing tool',
        });
        expect(await h.rows(), isEmpty);
        expect(h.notifications.scheduled, isEmpty);
      },
    );
    test(
      'replayed event is acknowledged once; deliberate same-text event remains distinct',
      () async {
        expect(await inbox.accept(item(1)), true);
        expect(await inbox.accept(item(1)), true);
        expect((await data()).items, hasLength(1));
        expect(await inbox.accept(item(2)), true);
        expect((await data()).items, hasLength(2));
        await inbox.remove(item(1).id, item(1).text);
        expect(await inbox.accept(item(1)), true);
        expect((await data()).items.map((e) => e.id), [item(2).id]);
      },
    );
    test(
      'concurrent arrivals are serialized and a full inbox leaves new events unacknowledged',
      () async {
        final results = await Future.wait([
          for (var n = 1; n <= 34; n++) inbox.accept(item(n)),
        ]);
        expect(results.where((v) => v), hasLength(32));
        expect((await data()).items, hasLength(32));
        await inbox.remove(item(1).id, item(1).text);
        expect(await inbox.accept(item(33)), true);
        expect((await data()).items, hasLength(32));
      },
    );
    test('stale editor and deletion cannot overwrite newer text', () async {
      await inbox.accept(item(1));
      await inbox.edit(item(1).id, item(1).text, '新草稿');
      await expectLater(
        inbox.edit(item(1).id, item(1).text, '旧编辑'),
        throwsStateError,
      );
      await expectLater(
        inbox.remove(item(1).id, item(1).text),
        throwsStateError,
      );
      expect((await data()).items.single.text, '新草稿');
    });
    test(
      'saved edits survive close and reopen with the composer untouched',
      () async {
        await drafts.put('capture', {'text': 'keep'});
        await inbox.accept(item(1));
        await inbox.edit(item(1).id, item(1).text, 'edited 中文');
        await h.close();
        await h.open();
        drafts = h.container.read(workspaceDraftsProvider.notifier);
        expect((await data()).items.single.text, 'edited 中文');
        expect(await drafts.readPersistedKey('capture'), {'text': 'keep'});
        await expectLater(inbox.accept(item(2)), throwsA(isA<Exception>()));
        expect((await data()).items, hasLength(1));
      },
    );
    test(
      'pruning completed receipts preserves every active old draft',
      () async {
        await inbox.accept(item(1));
        for (var n = 2; n <= 140; n++) {
          await inbox.accept(item(n));
          await inbox.remove(item(n).id, item(n).text);
        }
        final current = await data();
        expect(current.receipts, hasLength(128));
        expect(current.receipts, contains(item(1).id));
        expect(await inbox.accept(item(1)), true);
        expect((await data()).items, hasLength(1));
      },
    );
    test(
      'business backup and actual restore retain shared drafts, receipts and original composer',
      () async {
        await drafts.put('capture', {'id': 'existing', 'text': '原输入草稿'});
        await inbox.accept(item(1));
        await inbox.edit(item(1).id, item(1).text, 'edited shared draft');
        const service = StreamingBackupService();
        final backup = await service.createFile(
          h.database,
          h.database.captureGeneration(),
          Directory('${h.directory.path}/share-backup'),
        );
        final preview = await service.inspect(backup.file);
        final prepared = await service.prepareRestore(
          backup.file,
          Directory('${h.directory.path}/share-restored'),
          expectedDigest: preview.digest,
          isCurrent: () => true,
        );
        final inspector = BackupInspector(databaseFactoryFfi);
        final summary = await inspector.inspect(prepared);
        await drafts.put('capture', {'text': 'later replaced'});
        await DatabaseRecovery(
          h.database,
          inspector: inspector,
          notifications: NotificationService.forTesting(
            FlutterLocalNotificationsPlugin(),
            usesNativeNotifications: false,
          ),
        ).restore(prepared, expectedDigest: summary.digest);
        await h.close();
        await h.open();
        drafts = h.container.read(workspaceDraftsProvider.notifier);
        final restored = await data();
        expect(restored.items.single.text, 'edited shared draft');
        expect(restored.receipts, [item(1).id]);
        expect(await drafts.readPersistedKey('capture'), {
          'id': 'existing',
          'text': '原输入草稿',
        });
        expect(await h.rows(), isEmpty);
      },
    );
    test('unreadable or future inbox data is not overwritten', () async {
      final raw = {'version': 2, 'future': 'keep'};
      await drafts.put(SharedTextInbox.key, raw);
      await expectLater(inbox.accept(item(1)), throwsFormatException);
      expect(await drafts.readPersistedKey(SharedTextInbox.key), raw);
    });
    test('workspace quota failure leaves all prior drafts intact', () async {
      await drafts.put('large-existing-draft', 'x' * 1040000);
      final before = await h.drafts();
      await expectLater(
        inbox.accept(item(1, text: '新' * 16000)),
        throwsFormatException,
      );
      expect(await h.drafts(), before);
    });
    test(
      'maximum text and empty edited draft persist within the allowed boundaries',
      () async {
        final value = item(1, text: '中' * 16000);
        expect(await inbox.accept(value), true);
        await inbox.edit(value.id, value.text, '');
        expect((await data()).items.single.text, isEmpty);
        expect(
          jsonDecode((await h.drafts())!)[SharedTextInbox.key]['items'],
          hasLength(1),
        );
      },
    );
    for (final text in [
      '',
      '   ',
      'x' * 16001,
      'bad\u0000text',
      'bad\u0007text',
    ]) {
      test('invalid incoming text is rejected (${text.codeUnits})', () async {
        await expectLater(
          inbox.accept(item(1, text: text)),
          throwsFormatException,
        );
        expect((await data()).items, isEmpty);
      });
    }
  });

  group('Android handoff channel', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late AndroidShareService service;
    setUp(() {
      service = AndroidShareService();
    });
    tearDown(() {
      service.dispose();
      messenger.setMockMethodCallHandler(AndroidShareService.channel, null);
    });
    Future<void> signal() => messenger.handlePlatformMessage(
      AndroidShareService.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onPendingShares'),
      ),
      (_) {},
    );
    test(
      'receiver precedes readiness; dataset identity and durable acknowledgement are explicit',
      () async {
        final calls = <MethodCall>[];
        var signals = 0;
        messenger.setMockMethodCallHandler(AndroidShareService.channel, (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'initialize') await signal();
          if (call.method == 'pending') return [item(1).toJson()];
          return null;
        });
        expect(
          await service.initialize(
            datasetEpoch: 'dataset',
            onPending: () => signals++,
          ),
          true,
        );
        expect(signals, 1);
        expect(calls.first.arguments, 'dataset');
        expect((await service.pending()).single.id, item(1).id);
        await service.acknowledge(item(1).id);
        expect(calls.last.method, 'acknowledge');
        expect(calls.last.arguments, item(1).id);
      },
    );
    test(
      'reset invalidates a late pending read and receiver is reinitialized for the new data',
      () async {
        final pending = Completer<Object?>();
        final requested = Completer<void>();
        var signals = 0;
        messenger.setMockMethodCallHandler(AndroidShareService.channel, (
          call,
        ) async {
          if (call.method == 'pending') {
            requested.complete();
            return pending.future;
          }
          return null;
        });
        await service.initialize(
          datasetEpoch: 'old',
          onPending: () => signals++,
        );
        final read = service.pending();
        await requested.future;
        await service.resetForRecovery();
        pending.complete([item(1).toJson()]);
        expect(await read, isEmpty);
        await signal();
        expect(signals, 0);
        await service.initialize(
          datasetEpoch: 'new',
          onPending: () => signals++,
        );
        await signal();
        expect(signals, 1);
      },
    );
    test(
      'disposing while initialization waits cannot revive the receiver',
      () async {
        final reply = Completer<void>();
        messenger.setMockMethodCallHandler(
          AndroidShareService.channel,
          (_) => reply.future,
        );
        final init = service.initialize(datasetEpoch: 'old', onPending: () {});
        await Future<void>.delayed(Duration.zero);
        service.dispose();
        reply.complete();
        expect(await init, false);
      },
    );
    for (final raw in <Object?>[
      null,
      {},
      [item(1).toJson(), item(1).toJson()],
      [for (var n = 1; n <= 17; n++) item(n).toJson()],
      [
        {'id': 'external-id', 'text': 'x', 'created_at': 1},
      ],
    ]) {
      test('invalid native envelope is rejected', () async {
        messenger.setMockMethodCallHandler(
          AndroidShareService.channel,
          (_) async => raw,
        );
        await expectLater(service.pending(), throwsFormatException);
      });
    }
  });
}
