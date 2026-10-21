import 'dart:async';
import 'package:dio/dio.dart';
import '../../models/ai_profile.dart';

enum AiFailureKind {
  configuration,
  authentication,
  rateLimited,
  unavailable,
  timeout,
  invalidResponse,
}

class AiRouteFailure implements Exception {
  AiRouteFailure(this.failures);

  /// IDs and reason codes only. Never include server bodies or credentials.
  final Map<String, AiFailureKind> failures;
  @override
  String toString() => 'No configured model completed the request';
}

class AiRouteResult<T> {
  const AiRouteResult(
    this.value,
    this.profileId,
    this.attemptedIds,
    this.usedFallback,
  );
  final T value;
  final String profileId;
  final List<String> attemptedIds;
  final bool usedFallback;
}

class _Health {
  const _Health(this.profile, this.until, this.kind);
  final AiProfile profile;
  final DateTime until;
  final AiFailureKind kind;
  bool matches(AiProfile p) =>
      p.id == profile.id &&
      p.settings.baseUrl == profile.settings.baseUrl &&
      p.settings.modelName == profile.settings.modelName &&
      p.settings.apiKey == profile.settings.apiKey;
}

/// Transport-only routing. Persistence/UI opt-in are separate integration gates.
/// The callback must pass its token to Dio and validate content before returning.
class PriorityModelRouter {
  PriorityModelRouter({
    DateTime Function()? now,
    this.attemptTimeout = const Duration(seconds: 12),
    this.totalTimeout = const Duration(seconds: 30),
    this.cooldown = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final Duration attemptTimeout;
  final Duration totalTimeout;
  final Duration cooldown;
  final Map<String, _Health> _health = {};

  Future<AiRouteResult<T>> execute<T>({
    required List<AiProfile> profiles,
    required bool allowFallback,
    required Future<T> Function(AiProfile, CancelToken) request,
    CancelToken? cancelToken,
  }) async {
    if (profiles.length > 16 ||
        profiles.map((p) => p.id).toSet().length != profiles.length) {
      throw ArgumentError('Profiles must have unique IDs, at most 16');
    }
    final candidates = List<AiProfile>.unmodifiable(
      profiles.where((p) => p.enabled),
    );
    final ids = candidates.map((p) => p.id).toSet();
    _health.removeWhere(
      (id, value) => !ids.contains(id) || !value.until.isAfter(_now()),
    );
    final selected = allowFallback ? candidates : candidates.take(1);
    final attempts = <String>[];
    final failures = <String, AiFailureKind>{};
    final elapsed = Stopwatch()..start();
    var totalBudgetExpired = false;
    for (final profile in selected) {
      if (totalBudgetExpired) break;
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (!profile.isConfigured) {
        failures[profile.id] = AiFailureKind.configuration;
        continue;
      }
      final health = _health[profile.id];
      if (allowFallback &&
          health != null &&
          health.matches(profile) &&
          health.until.isAfter(_now())) {
        failures[profile.id] = health.kind;
        continue;
      }
      final remaining = totalTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      final usesRemainingBudget = remaining <= attemptTimeout;
      final limit = usesRemainingBudget ? remaining : attemptTimeout;
      final attemptToken = CancelToken();
      var settled = false;
      // Ignore cancellation after this attempt finishes, and never forward the
      // parent's potentially sensitive cancellation reason to another provider.
      cancelToken?.whenCancel.then((_) {
        if (!settled) attemptToken.cancel('Request cancelled');
      });
      attempts.add(profile.id);
      try {
        final value =
            await Future.any<T>([
              Future.sync(() => request(profile, attemptToken)),
              attemptToken.whenCancel.then<T>((error) => throw error),
            ]).timeout(
              limit,
              onTimeout: () {
                // Timer resolution may round a sub-millisecond remainder down.
                // Once the total-budget timer fires, never launch another host.
                if (usesRemainingBudget) totalBudgetExpired = true;
                attemptToken.cancel('Attempt timed out');
                throw TimeoutException('Attempt timed out');
              },
            );
        if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
        if (elapsed.elapsed >= totalTimeout) {
          totalBudgetExpired = true;
          throw TimeoutException('Total request budget expired');
        }
        _health.remove(profile.id);
        return AiRouteResult(
          value,
          profile.id,
          List.unmodifiable(attempts),
          profile.id != candidates.first.id,
        );
      } catch (error) {
        if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
        final kind = _classify(error);
        failures[profile.id] = kind;
        if (!_health.containsKey(profile.id) && _health.length >= 16) {
          _health.remove(_health.keys.first);
        }
        _health[profile.id] = _Health(profile, _now().add(cooldown), kind);
      } finally {
        settled = true;
      }
    }
    throw AiRouteFailure(Map.unmodifiable(failures));
  }

  AiFailureKind _classify(Object error) {
    if (error is TimeoutException) return AiFailureKind.timeout;
    if (error is FormatException) return AiFailureKind.invalidResponse;
    if (error is DioException) {
      if (const [401, 403].contains(error.response?.statusCode)) {
        return AiFailureKind.authentication;
      }
      if (const [400, 404, 422].contains(error.response?.statusCode)) {
        return AiFailureKind.configuration;
      }
      if (error.response?.statusCode == 429) return AiFailureKind.rateLimited;
      if (const [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ].contains(error.type)) {
        return AiFailureKind.timeout;
      }
    }
    return AiFailureKind.unavailable;
  }
}
