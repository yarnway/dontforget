import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Rebuild persisted local calendar values after a device timezone change.
/// A DateTime can cache its calendar fields, so rebuilding widgets alone is
/// insufficient. The owner supplies the serialized, generation-checked reload.
class TimeZoneChangeCoordinator {
  TimeZoneChangeCoordinator({
    required this.reload,
    String Function()? localSignature,
    Future<String?> Function()? readIdentifier,
  }) : _localSignature = localSignature ?? deviceLocalSignature,
       _readIdentifier = readIdentifier ?? deviceIdentifier {
    _lastLocal = _localSignature();
  }

  static const channel = MethodChannel('dontforget/system_time');

  static String deviceLocalSignature() {
    final now = DateTime.now();
    // Include both seasons: equal current offsets need not mean equal rules.
    return [
      now,
      DateTime(now.year, 1),
      DateTime(now.year, 7),
    ].map((d) => '${d.timeZoneName}:${d.timeZoneOffset.inSeconds}').join('|');
  }

  static Future<String?> deviceIdentifier() async {
    if (defaultTargetPlatform != TargetPlatform.macOS) return null;
    try {
      return await channel
          .invokeMethod<String>('timeZoneIdentifier')
          .timeout(const Duration(seconds: 3));
    } on MissingPluginException {
      // Widget harnesses/older hosts retain offset-based detection.
      return null;
    }
  }

  final Future<void> Function() reload;
  final String Function() _localSignature;
  final Future<String?> Function() _readIdentifier;
  late String _lastLocal;
  String? _lastIdentifier;
  Future<void>? _running;
  bool _stopped = false;

  Future<void> tick() {
    if (_stopped) return Future.value();
    return _running ??= _check()
        .catchError((Object _) {
          // Keep the previous identity on read/reload failure; retry next tick.
        })
        .whenComplete(() => _running = null);
  }

  Future<void> _check() async {
    final identifier = await _readIdentifier();
    if (_stopped) return;
    final local = _localSignature();
    if (local != _lastLocal ||
        (_lastIdentifier != null && identifier != _lastIdentifier)) {
      await reload();
    }
    if (_stopped) return;
    _lastLocal = local;
    _lastIdentifier = identifier;
  }

  Future<void> stop() async {
    _stopped = true;
    await _running;
  }
}
