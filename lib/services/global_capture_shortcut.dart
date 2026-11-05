import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'recovery/runtime_gate.dart';

abstract class CaptureShortcutBackend {
  void listen(void Function(String nonce) receive);
  Future<bool> setEnabled(bool enabled, String nonce);
  void dispose();
}

class WindowsCaptureShortcutBackend implements CaptureShortcutBackend {
  static const channel = MethodChannel('com.yarnway.dontforget/global_capture');
  static int _activeListener = 0;
  int _listener = -1;
  @override
  void listen(void Function(String) receive) {
    final listener = _listener = ++_activeListener;
    channel.setMethodCallHandler((call) async {
      if (listener == _activeListener &&
          call.method == 'onCapture' &&
          call.arguments is String) {
        receive(call.arguments as String);
      }
    });
  }

  @override
  Future<bool> setEnabled(bool enabled, String nonce) async {
    if (_listener != _activeListener) return !enabled;
    try {
      return await channel.invokeMethod<bool>('setEnabled', {
            'enabled': enabled,
            'nonce': nonce,
          }) ==
          true;
    } on MissingPluginException {
      return !enabled;
    }
  }

  @override
  void dispose() {
    if (_listener == _activeListener) {
      ++_activeListener;
      channel.setMethodCallHandler(null);
    }
  }
}

/// Device-local opt-in. Register only after the app is ready; recovery drains
/// writes and unbinds before replacing business data. Events never replay.
class GlobalCaptureShortcut extends ChangeNotifier {
  GlobalCaptureShortcut({
    required this.backend,
    required this.runtime,
    required this.readSaved,
    required this.writeSaved,
  }) {
    backend.listen(_receive);
  }
  final CaptureShortcutBackend backend;
  final RuntimeRecoveryGate runtime;
  final Future<bool> Function() readSaved;
  final Future<void> Function(bool) writeSaved;
  Future<void> _tail = Future.value();
  bool _disposed = false, _listening = false, _ready = false;
  bool enabled = false, registered = false, busy = false;
  String? error;
  String? _nonce;
  int _epoch = 0;
  VoidCallback? _activate;
  bool get ready => _ready && !_disposed && !runtime.paused;
  Future<T> _serial<T>(Future<T> Function() run) {
    final result = _tail.then((_) => run());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch && !runtime.paused;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _receive(String nonce) {
    if (ready && enabled && registered && !busy && nonce == _nonce) {
      _activate?.call();
    }
  }

  Future<bool> _bind(bool value) async {
    final nonce = value ? const Uuid().v4() : '';
    final bound = await backend.setEnabled(value, nonce);
    if (bound) {
      registered = value;
      _nonce = value ? nonce : null;
    }
    return bound;
  }

  Future<void> start(VoidCallback activate) {
    _activate = activate;
    final epoch = ++_epoch;
    _nonce = null;
    return _serial(() async {
      if (!_current(epoch)) return;
      if (!_listening) {
        runtime.register(this, pause);
        _listening = true;
      }
      busy = true;
      _ready = false;
      _changed();
      try {
        if (!await _bind(false)) throw StateError('Shortcut unbind failed');
        if (!_current(epoch)) return;
        enabled = await readSaved();
        if (!_current(epoch)) return;
        error = enabled && !await _bind(true) ? 'conflict' : null;
      } catch (_) {
        error = 'unavailable';
      } finally {
        if (_current(epoch)) {
          busy = false;
          _ready = true;
          _changed();
        }
      }
    });
  }

  Future<void> setEnabled(bool value) {
    final epoch = _epoch;
    return _serial(() async {
      if (!_current(epoch) || !_ready) return;
      if (enabled == value && registered == value && error == null) return;
      busy = true;
      error = null;
      _changed();
      final previous = enabled;
      var persisted = false;
      try {
        // Every registration uses a fresh native message ID/nonce.
        if (!await _bind(false)) throw StateError('Shortcut unbind failed');
        if (!_current(epoch)) return;
        if (value && !await _bind(true)) {
          error = 'conflict';
          return;
        }
        if (!_current(epoch)) return;
        await writeSaved(value);
        persisted = true;
        if (_current(epoch)) enabled = value;
      } catch (_) {
        if (_current(epoch)) {
          error = 'saveFailed';
          try {
            if (!await _bind(false) || (previous && !await _bind(true))) {
              error = 'unavailable';
              registered = false;
              _nonce = null;
            }
          } catch (_) {
            error = 'unavailable';
            registered = false;
            _nonce = null;
          }
        }
      } finally {
        if (_current(epoch)) {
          if (!persisted) enabled = previous;
          busy = false;
          _changed();
        }
      }
    });
  }

  Future<void> pause() {
    if (_disposed) return Future.value();
    ++_epoch;
    _ready = false;
    _nonce = null;
    _changed();
    return _serial(() async {
      // Failure keeps the runtime gate paused, so an OS binding cannot retain
      // access to an obsolete data set or falsely report a clean shutdown.
      if (!await _bind(false)) throw StateError('Shortcut could not be paused');
      busy = false;
      _changed();
    });
  }

  Future<void> get flushed => _tail;
  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _nonce = null;
    _activate = null;
    if (_listening) runtime.unregister(this);
    unawaited(
      _serial(() async {
        try {
          await backend.setEnabled(false, '');
        } catch (_) {}
        backend.dispose();
      }),
    );
    super.dispose();
  }
}
