import 'dart:async';
import 'dart:ui' as ui;

import 'package:dont_forget/services/mac_menu_commands.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dontforget/mac_commands');
  const codec = StandardMethodCodec();
  late MacMenuCommands<int> commands;
  late Completer<String?> sheet;
  late Completer<void> shown;
  late List<String> submitted;
  late List<MethodCall> outbound;
  var epoch = 0;
  var settingsOpens = 0;
  var toolsOpens = 0;
  var editorSaves = 0;
  var edits = <String>[];
  bool Function()? editIsCurrent;
  var workspaceVisible = true;
  Future<int?> Function()? begin;

  Future<Object?> invoke(String method, [Object? arguments]) async {
    final answer = Completer<ByteData?>();
    ui.channelBuffers.push(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      answer.complete,
    );
    return codec.decodeEnvelope((await answer.future)!);
  }

  setUp(() async {
    epoch = 0;
    settingsOpens = 0;
    toolsOpens = 0;
    editorSaves = 0;
    edits = [];
    editIsCurrent = null;
    workspaceVisible = true;
    begin = null;
    sheet = Completer<String?>();
    shown = Completer<void>();
    submitted = [];
    outbound = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          outbound.add(call);
          if (call.method == 'showInput') {
            shown.complete();
            return sheet.future;
          }
          return null;
        });
    commands = MacMenuCommands<int>(
      beginInput: () => begin?.call() ?? Future.value(epoch),
      isCurrent: (token) => token == epoch,
      submitInput: (text) async => submitted.add(text),
      saveEditor: () {
        editorSaves++;
        return true;
      },
      editText: (command, isCurrent) async {
        edits.add(command);
        editIsCurrent = isCurrent;
        return isCurrent();
      },
      openTools: () {
        if (!workspaceVisible) return false;
        toolsOpens++;
        workspaceVisible = false;
        return true;
      },
      openSettings: () {
        settingsOpens++;
        return true;
      },
    )..start();
    await commands.configure({'quickEntry': '快速输入…'}, enabled: true);
  });

  tearDown(() async {
    commands.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'native editing is scoped to enabled session and excluded from native input',
    () async {
      expect(await invoke('editText', 'selectAll'), true);
      expect(edits, ['selectAll']);
      final old = editIsCurrent!;
      commands.invalidate();
      expect(old(), false);
      final pending = invoke('quickInput');
      await shown.future;
      expect(await invoke('editText', 'paste'), false);
      sheet.complete(null);
      await pending;
      await commands.configure({}, enabled: false);
      expect(await invoke('editText', 'cut'), false);
      expect(edits, ['selectAll']);
    },
  );

  test(
    'confirmed text enters the product callback once; duplicates wait',
    () async {
      final first = invoke('quickInput');
      await shown.future;
      expect(await invoke('quickInput'), false);
      expect(await invoke('openSettings'), false);
      sheet.complete('  明天下午三点检查报告。  ');
      expect(await first, true);
      expect(submitted, ['明天下午三点检查报告。']);
      expect(await invoke('openSettings'), true);
      expect(settingsOpens, 1);
      expect(outbound.where((c) => c.method == 'showInput'), hasLength(1));
    },
  );

  for (final value in <String?>[null, '', ' \n ']) {
    test('cancelled or blank input writes nothing: $value', () async {
      final pending = invoke('quickInput');
      await shown.future;
      sheet.complete(value);
      expect(await pending, false);
      expect(submitted, isEmpty);
    });
  }

  test(
    'recovery cancels the sheet and rejects a late confirmation after resume',
    () async {
      final pending = invoke('quickInput');
      await shown.future;
      commands.invalidate();
      await commands.configure({'quickEntry': '快速输入…'}, enabled: false);
      expect(await invoke('openSettings'), false);
      await commands.configure({'quickEntry': '快速输入…'}, enabled: true);
      sheet.complete('old draft');
      expect(await pending, false);
      expect(submitted, isEmpty);
      expect(outbound.any((c) => c.method == 'cancelInput'), true);
    },
  );

  test(
    'changed data generation rejects a confirmation without replay',
    () async {
      final pending = invoke('quickInput');
      await shown.future;
      epoch++;
      sheet.complete('old dataset');
      expect(await pending, false);
      expect(submitted, isEmpty);
    },
  );

  test(
    'invalidation during readiness wait never opens a stale sheet',
    () async {
      final ready = Completer<int?>();
      final started = Completer<void>();
      begin = () {
        started.complete();
        return ready.future;
      };
      final pending = invoke('quickInput');
      await started.future;
      commands.invalidate();
      ready.complete(epoch);
      expect(await pending, false);
      expect(shown.isCompleted, false);
    },
  );

  test('disposing with an open sheet cannot submit after teardown', () async {
    final pending = invoke('quickInput');
    await shown.future;
    commands.dispose();
    sheet.complete('late');
    expect(await pending, false);
    expect(submitted, isEmpty);
  });

  test(
    'unavailable native input fails closed and releases the next attempt',
    () async {
      final pending = invoke('quickInput');
      await shown.future;
      sheet.completeError(PlatformException(code: 'unavailable'));
      expect(await pending, false);
      sheet = Completer<String?>();
      shown = Completer<void>();
      final retry = invoke('quickInput');
      await shown.future;
      sheet.complete('fresh input');
      expect(await retry, true);
      expect(submitted, ['fresh input']);
    },
  );

  test(
    'unchanged menus do not repeat native work; disabled actions do nothing',
    () async {
      await commands.configure({'quickEntry': '快速输入…'}, enabled: true);
      expect(outbound.where((c) => c.method == 'configure'), hasLength(1));
      await commands.configure({'quickEntry': 'Quick Entry…'}, enabled: false);
      expect(await invoke('quickInput'), false);
      expect(await invoke('openSettings'), false);
      expect(settingsOpens, 0);
      expect(shown.isCompleted, false);
    },
  );
  test(
    'native save is fenced while input sheet or recovery owns the session',
    () async {
      expect(await invoke('saveEditor'), true);
      final pending = invoke('quickInput');
      await shown.future;
      expect(await invoke('saveEditor'), false);
      sheet.complete(null);
      await pending;
      await commands.configure({}, enabled: false);
      expect(await invoke('saveEditor'), false);
      expect(editorSaves, 1);
    },
  );

  test(
    'native tools command respects visibility, input sheet and disabled state',
    () async {
      expect(await invoke('openTools'), true);
      expect(await invoke('openTools'), false);
      expect(toolsOpens, 1);
      workspaceVisible = true;
      final pending = invoke('quickInput');
      await shown.future;
      expect(await invoke('openTools'), false);
      sheet.complete(null);
      await pending;
      expect(await invoke('openTools'), true);
      workspaceVisible = true;
      await commands.configure({}, enabled: false);
      expect(await invoke('openTools'), false);
      expect(toolsOpens, 2);
    },
  );
}
