import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/windows_toast.dart';

void main() {
  test('a body that repeats the title uses the single-line template', () {
    final script = WindowsToast.script(title: '喝药', body: '喝药');
    expect(script, contains(r'::ToastText01)'));
    expect(script, isNot(contains(r'::ToastText02)')));
    expect(script, isNot(contains(r'Item(1)')));
    expect(script, contains(r"CreateTextNode('喝药')"));
  });

  test('an empty body also stays single-line', () {
    final script = WindowsToast.script(title: '站立提醒');
    expect(script, contains(r'::ToastText01)'));
    expect(script, isNot(contains(r'Item(1)')));
  });

  test('a body with extra context keeps both lines', () {
    final script = WindowsToast.script(
      title: '出门清单',
      body: '带伞、钥匙和门禁卡',
    );
    expect(script, contains(r'::ToastText02)'));
    expect(script, contains(r"CreateTextNode('出门清单')"));
    expect(script, contains(r"CreateTextNode('带伞、钥匙和门禁卡')"));
  });

  test('quotes, dollars, backticks and newlines are escaped', () {
    final script = WindowsToast.script(
      title: "It's \$HOME `x`\r\nnext",
      body: 'line',
    );
    expect(script, contains(r"CreateTextNode('It''s `$HOME ``x`` next')"));
    expect(script, isNot(contains('\r')));
    expect(script, isNot(contains('\nnext')));
  });

  test('silent audio is requested for low-priority reminders', () {
    expect(WindowsToast.script(title: 'a', playSound: true), contains(
      r"SetAttribute('silent', 'false')",
    ));
    expect(WindowsToast.script(title: 'a', playSound: false), contains(
      r"SetAttribute('silent', 'true')",
    ));
  });

  test('overlong bodies are truncated with an ellipsis', () {
    final body = 'x' * (WindowsToast.maxBodyLength + 40);
    final script = WindowsToast.script(title: 't', body: body);
    expect(script, contains('…'));
    expect(script, isNot(contains('x' * (WindowsToast.maxBodyLength + 1))));
  });

  test('the toast identity matches the registered app user model id', () {
    expect(WindowsToast.appUserModelId, 'DontForget');
    final script = WindowsToast.script(title: 'a');
    expect(
      script,
      contains('CreateToastNotifier("${WindowsToast.appUserModelId}")'),
    );
  });

  test('a non-zero exit is reported instead of silently ignored', () async {
    final ok = await WindowsToast.show(
      title: 'a',
      runner: (_) async => ProcessResult(1, 1, '', 'policy blocked'),
    );
    expect(ok, isFalse);
  });

  test('a successful run reports delivery', () async {
    final ok = await WindowsToast.show(
      title: 'a',
      runner: (_) async => ProcessResult(1, 0, '', ''),
    );
    expect(ok, isTrue);
  });

  test('a throw from the runner is contained', () async {
    final ok = await WindowsToast.show(
      title: 'a',
      runner: (_) async => throw StateError('no powershell'),
    );
    expect(ok, isFalse);
  });
}
