import 'package:flutter/services.dart';

import '../models/notification_payload.dart';
import 'windows_protocol_service.dart';

/// An Android URL must be a complete, bounded URI, never a command line.
/// Mutations carry the existing notification occurrence and data-set token.
ProtocolRoute? parseAndroidProtocolUrl(String? raw) {
  if (raw == null || raw.isEmpty || raw.length > 8192 || raw != raw.trim()) {
    return null;
  }
  try {
    final uri = Uri.parse(raw);
    if (uri.scheme != 'dontforget' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment ||
        uri.pathSegments.length != 1 ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) {
      return null;
    }
    final route = ProtocolRoute.tryParse(raw);
    if (route == null ||
        route.taskId.length > 512 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(route.taskId)) {
      return null;
    }
    final parameters = uri.queryParameters;
    if (uri.host == 'task') {
      return parameters.isEmpty ? route : null;
    }
    if (uri.host != 'action' ||
        parameters.keys.any(
          (key) => !{'id', 'minutes', 'payload'}.contains(key),
        )) {
      return null;
    }
    final payload = NotificationPayload.tryParse(parameters['payload']);
    if (payload == null) return null;
    if (route.action == ProtocolAction.completeTask) {
      if (parameters.containsKey('minutes')) return null;
    } else if (route.action == ProtocolAction.snoozeTask) {
      if (parameters.containsKey('minutes') &&
          !{'15', '60'}.contains(parameters['minutes'])) {
        return null;
      }
    } else {
      return null;
    }
    return ProtocolRoute(
      action: route.action,
      taskId: route.taskId,
      snoozeMinutes: route.snoozeMinutes,
      payload: payload,
    );
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// Receives Android's initial intent only after Dart installs its receiver.
class AndroidProtocolService {
  static const channel = MethodChannel('com.yarnway.dontforget/protocol');
  void Function(ProtocolRoute)? _onRoute;
  int _generation = 0;
  int _received = 0;

  Future<void> initialize({
    required void Function(ProtocolRoute) onRoute,
  }) async {
    final generation = ++_generation;
    final received = _received;
    _onRoute = onRoute;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onProtocolUrl' && call.arguments is String) {
        final route = parseAndroidProtocolUrl(call.arguments as String);
        if (route != null) {
          _received++;
          _onRoute?.call(route);
        }
      }
    });
    try {
      final initial = await channel.invokeMethod<String>('initialize');
      if (generation != _generation || received != _received) return;
      final route = parseAndroidProtocolUrl(initial);
      if (route != null) _onRoute?.call(route);
    } on MissingPluginException {
      // Older native builds have no initial-intent handshake.
    } on PlatformException {
      // A native initialization failure must not prevent normal app startup.
    }
  }

  /// A URL fetched before recovery must not arrive in the restored data set.
  void invalidatePendingInitialization() => _generation++;

  void dispose() {
    _generation++;
    _onRoute = null;
    channel.setMethodCallHandler(null);
  }
}
