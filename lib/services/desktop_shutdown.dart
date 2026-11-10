import 'dart:async';

/// Wait for the latest local write, including writes queued while awaiting an
/// earlier one. Callers freeze input synchronously after this returns.
Future<void> drainDesktopWrites(
  Future<void> Function() pending,
  bool Function() failed,
) async {
  while (true) {
    final work = pending();
    await work;
    if (failed()) throw StateError('Pending local writes could not be saved');
    if (identical(work, pending())) return;
  }
}

/// Serializes system upgrade requests. A failed preparation does not exit or
/// close storage; a completed exit is never repeated by a duplicate request.
class DesktopUpgradeExit {
  DesktopUpgradeExit({
    required this.canExit,
    required this.prepare,
    required this.exitApp,
    this.onError,
  });
  final bool Function() canExit;
  final AsyncVoid prepare, exitApp;
  final void Function(Object, StackTrace)? onError;
  Future<bool>? _pending;
  bool get inProgress => _pending != null;

  Future<bool> request() {
    if (_pending != null) return _pending!;
    if (!canExit()) return Future.value(false);
    final work = Future<bool>.sync(() async {
      try {
        await prepare();
        await exitApp();
        return true;
      } catch (error, stack) {
        onError?.call(error, stack);
        return false;
      }
    });
    _pending = work;
    unawaited(
      work.then((ok) {
        if (!ok && identical(_pending, work)) _pending = null;
      }),
    );
    return work;
  }
}

/// Desktop shutdown sequence shared by tray exit and tests.
///
/// The desktop build previously called `exit(0)` directly, which skipped the
/// normal database close (mirror backup + notification journal flush) and could
/// leave a half-written store behind. Storage is now closed before the window is
/// destroyed, and a failure in one step must not prevent the process from
/// exiting.
typedef AsyncVoid = Future<void> Function();

Future<void> shutdownDesktopApp({
  AsyncVoid? saveState,
  required AsyncVoid closeStorage,
  required AsyncVoid destroyWindow,
  required void Function(int code) exitProcess,
  void Function(Object error, StackTrace stack)? onError,
}) async {
  if (saveState != null) {
    try {
      await saveState();
    } catch (error, stack) {
      onError?.call(error, stack);
    }
  }
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
