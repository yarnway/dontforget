import 'package:flutter_test/flutter_test.dart';

/// Let SQLite/file I/O advance on the real clock and widget continuations on
/// the fake clock. A fixed number of pumps is not an I/O completion signal.
Future<void> pumpUntilRealIo(
  WidgetTester tester,
  bool Function() completed, {
  required String reason,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final clock = Stopwatch()..start();
  while (!completed() && clock.elapsed < timeout) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(completed(), isTrue, reason: reason);
}
