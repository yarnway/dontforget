/// Desktop shutdown sequence shared by tray exit and tests.
///
/// The desktop build previously called `exit(0)` directly, which skipped the
/// normal database close (mirror backup + notification journal flush) and could
/// leave a half-written store behind. Storage is now closed before the window is
/// destroyed, and a failure in one step must not prevent the process from
/// exiting.
typedef AsyncVoid = Future<void> Function();

Future<void> shutdownDesktopApp({
  required AsyncVoid closeStorage,
  required AsyncVoid destroyWindow,
  required void Function(int code) exitProcess,
  void Function(Object error, StackTrace stack)? onError,
}) async {
  try {
    await closeStorage();
  } catch (error, stack) {
    onError?.call(error, stack);
  }
  try {
    await destroyWindow();
  } catch (error, stack) {
    onError?.call(error, stack);
  }
  exitProcess(0);
}
