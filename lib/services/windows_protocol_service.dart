import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ProtocolAction { viewTask, completeTask, snoozeTask }

/// Represents a parsed route from a `dontforget://` protocol activation.
class ProtocolRoute {
  final ProtocolAction action;
  final String taskId;
  final int? snoozeMinutes;

  const ProtocolRoute({
    required this.action,
    required this.taskId,
    this.snoozeMinutes,
  });

  /// Safely parses a URI string or command line into a [ProtocolRoute].
  /// Returns `null` if the input is malformed, unrecognized, or not a `dontforget://` URI.
  static ProtocolRoute? tryParse(String? uriOrCommand) {
    if (uriOrCommand == null || uriOrCommand.trim().isEmpty) return null;

    final input = uriOrCommand.trim();
    // Extract URI substring if embedded in command line quotes
    final match = RegExp(r'dontforget://[^\s"]+').firstMatch(input);
    final uriString = match != null ? match.group(0)! : input;

    try {
      final uri = Uri.tryParse(uriString);
      if (uri == null || uri.scheme.toLowerCase() != 'dontforget') return null;

      final host = uri.host.toLowerCase();
      final pathSegments = uri.pathSegments;

      // 1. dontforget://task/<id>
      if (host == 'task' && pathSegments.isNotEmpty) {
        final id = pathSegments.first.trim();
        if (id.isNotEmpty) {
          return ProtocolRoute(action: ProtocolAction.viewTask, taskId: id);
        }
      }

      // 2. dontforget://action/complete?id=<id> or dontforget://action/snooze?id=<id>&minutes=15
      if (host == 'action' && pathSegments.isNotEmpty) {
        final actionType = pathSegments.first.toLowerCase();
        final id = uri.queryParameters['id']?.trim();
        if (id == null || id.isEmpty) return null;

        if (actionType == 'complete') {
          return ProtocolRoute(
            action: ProtocolAction.completeTask,
            taskId: id,
          );
        }
        if (actionType == 'snooze') {
          final rawMinutes = uri.queryParameters['minutes'];
          final minutes =
              rawMinutes != null ? int.tryParse(rawMinutes) ?? 15 : 15;
          return ProtocolRoute(
            action: ProtocolAction.snoozeTask,
            taskId: id,
            snoozeMinutes: minutes > 0 ? minutes : 15,
          );
        }
      }

      // 3. Fallback: dontforget://<id> (direct task ID)
      if (host.isNotEmpty && host != 'task' && host != 'action') {
        return ProtocolRoute(action: ProtocolAction.viewTask, taskId: host);
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProtocolRoute &&
          runtimeType == other.runtimeType &&
          action == other.action &&
          taskId == other.taskId &&
          snoozeMinutes == other.snoozeMinutes;

  @override
  int get hashCode => Object.hash(action, taskId, snoozeMinutes);

  @override
  String toString() =>
      'ProtocolRoute(action: $action, taskId: $taskId, snoozeMinutes: $snoozeMinutes)';
}

/// Service that handles protocol URI activation on Windows.
class WindowsProtocolService {
  static const MethodChannel channel = MethodChannel(
    'com.yarnway.dontforget/protocol',
  );

  static void Function(ProtocolRoute route)? _onRouteReceived;

  @visibleForTesting
  static void Function(ProtocolRoute route)? get onRouteReceived =>
      _onRouteReceived;

  /// Initializes the protocol handler with a callback invoked on URI activation.
  static void initialize({void Function(ProtocolRoute route)? onRoute}) {
    _onRouteReceived = onRoute;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onProtocolUrl') {
        final raw = call.arguments?.toString();
        final route = ProtocolRoute.tryParse(raw);
        if (route != null) {
          _onRouteReceived?.call(route);
        }
      }
    });
  }

  /// Cleans up method channel handlers.
  static void dispose() {
    _onRouteReceived = null;
    channel.setMethodCallHandler(null);
  }

  /// Extracts a [ProtocolRoute] from the command line arguments list if present.
  static ProtocolRoute? extractRouteFromArgs(List<String> args) {
    for (final arg in args) {
      if (arg.contains('dontforget://')) {
        final route = ProtocolRoute.tryParse(arg);
        if (route != null) return route;
      }
    }
    return null;
  }
}
