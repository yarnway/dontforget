import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native menu entry points share the product input pipeline. A sheet belongs
/// to the data/runtime session that opened it, never a later restored dataset.
class MacMenuCommands<T extends Object> {
  MacMenuCommands({
    required this.beginInput,
    required this.isCurrent,
    required this.submitInput,
    required this.openSettings,
    this.openTools,
    this.saveEditor,
    this.editText,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('dontforget/mac_commands');

  final Future<T?> Function() beginInput;
  final bool Function(T) isCurrent;
  final Future<void> Function(String) submitInput;
  final bool Function() openSettings;
  final bool Function()? openTools;
  final bool Function()? saveEditor;
  final Future<bool> Function(String, bool Function())? editText;
  final MethodChannel _channel;
  Map<String, Object>? _configuration;
  bool _enabled = false;
  bool _inputOpen = false;
  bool _disposed = false;
  int _epoch = 0;

  void start() => _channel.setMethodCallHandler(_handle);

  Future<void> configure(
    Map<String, String> labels, {
    required bool enabled,
  }) async {
    if (_disposed) return;
    _enabled = enabled;
    final configuration = <String, Object>{...labels, 'enabled': enabled};
    if (mapEquals(_configuration, configuration)) return;
    _configuration = configuration;
    try {
      await _channel.invokeMethod<void>('configure', configuration);
    } on PlatformException {
      _configuration = null;
    } on MissingPluginException {
      _configuration = null;
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    if (_disposed || !_enabled) return false;
    if (call.method == 'openSettings') {
      return !_inputOpen && openSettings();
    }
    if (call.method == 'openTools') {
      return !_inputOpen && (openTools?.call() ?? false);
    }
    if (call.method == 'saveEditor') {
      return !_inputOpen && (saveEditor?.call() ?? false);
    }
    if (call.method == 'editText') {
      if (_inputOpen || call.arguments is! String || editText == null) {
        return false;
      }
      final epoch = _epoch;
      return editText!(
        call.arguments as String,
        () => !_disposed && _enabled && !_inputOpen && _epoch == epoch,
      );
    }
    if (call.method != 'quickInput') throw MissingPluginException();
    if (_inputOpen) return false;
    _inputOpen = true;
    final epoch = _epoch;
    try {
      final session = await beginInput();
      if (session == null ||
          _disposed ||
          epoch != _epoch ||
          !isCurrent(session)) {
        return false;
      }
      // No deadline on a person's editing time. Recovery closes the sheet and
      // invalidates its eventual answer instead of replaying it after reload.
      final text = await _channel.invokeMethod<String>('showInput');
      if (text == null ||
          text.trim().isEmpty ||
          _disposed ||
          epoch != _epoch ||
          !_enabled ||
          !isCurrent(session)) {
        return false;
      }
      await submitInput(text.trim());
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } finally {
      _inputOpen = false;
    }
  }

  void invalidate() {
    _epoch++;
    unawaited(_cancelSheet());
  }

  Future<void> _cancelSheet() async {
    try {
      await _channel.invokeMethod<void>('cancelInput');
    } on PlatformException {
      // The epoch is already invalid even if the native sheet cannot close.
    } on MissingPluginException {
      // Other platforms and widget tests do not install this macOS bridge.
    }
  }

  void dispose() {
    _disposed = true;
    _enabled = false;
    invalidate();
    _channel.setMethodCallHandler(null);
  }
}
