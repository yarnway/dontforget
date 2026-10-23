import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/ai_profile.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/ai/priority_router.dart';

AiProfile profile(String id, {String? key, bool enabled = true}) => AiProfile(
  id: id,
  label: id,
  enabled: enabled,
  settings: AppSettings.defaults().copyWith(
    baseUrl: 'https://$id.example/v1',
    apiKey: key ?? 'fixture-$id',
  ),
);
DioException unavailable([int code = 503]) => DioException(
  requestOptions: RequestOptions(path: '/fixture'),
  response: Response(
    requestOptions: RequestOptions(path: '/fixture'),
    statusCode: code,
    data: 'PRIVATE-SERVER-DETAIL',
  ),
);

void main() {
  test('manual order, credential isolation and fallback success', () async {
    final calls = <String>[];
    final result = await PriorityModelRouter().execute(
      profiles: [profile('a'), profile('b'), profile('c')],
      allowFallback: true,
      request: (p, token) async {
        calls.add(p.id);
        expect(p.settings.apiKey, 'fixture-${p.id}');
        if (p.id == 'a') throw unavailable(401);
        return 'result';
      },
    );
    expect(calls, ['a', 'b']);
    expect(result.profileId, 'b');
    expect(result.value, 'result');
  });
  test('fallback disabled never calls the secondary endpoint', () async {
    final calls = <String>[];
    await expectLater(
      PriorityModelRouter().execute<String>(
        profiles: [profile('a'), profile('b')],
        allowFallback: false,
        request: (p, token) async {
          calls.add(p.id);
          throw unavailable();
        },
      ),
      throwsA(isA<AiRouteFailure>()),
    );
    expect(calls, ['a']);
  });
  test(
    'cooldown skips unavailable primary then restores user priority',
    () async {
      var now = DateTime(2026);
      final router = PriorityModelRouter(now: () => now);
      var failed = true;
      final calls = <String>[];
      Future<String> request(AiProfile p, CancelToken _) async {
        calls.add(p.id);
        if (p.id == 'a' && failed) throw unavailable();
        return p.id;
      }

      final profiles = [profile('a'), profile('b')];
      await router.execute(
        profiles: profiles,
        allowFallback: true,
        request: request,
      );
      failed = false;
      calls.clear();
      await router.execute(
        profiles: profiles,
        allowFallback: true,
        request: request,
      );
      expect(calls, ['b']);
      now = now.add(const Duration(seconds: 31));
      calls.clear();
      await router.execute(
        profiles: profiles,
        allowFallback: true,
        request: request,
      );
      expect(calls, ['a']);
      calls.clear();
      await router.execute(
        profiles: profiles.reversed.toList(),
        allowFallback: true,
        request: request,
      );
      expect(calls, ['b']);
    },
  );
  test(
    'disabled and incomplete configurations do not transmit requests',
    () async {
      final calls = <String>[];
      await PriorityModelRouter().execute(
        profiles: [
          profile('a', enabled: false),
          profile('b', key: ''),
          profile('c'),
        ],
        allowFallback: true,
        request: (p, _) async {
          calls.add(p.id);
          return true;
        },
      );
      expect(calls, ['c']);
    },
  );
  test(
    'attempt timeout cancels transport before trying next service',
    () async {
      CancelToken? first;
      final result =
          await PriorityModelRouter(
            attemptTimeout: const Duration(milliseconds: 15),
          ).execute(
            profiles: [profile('a'), profile('b')],
            allowFallback: true,
            request: (p, token) async {
              if (p.id == 'a') {
                first = token;
                return Completer<String>().future;
              }
              expect(first!.isCancelled, isTrue);
              return 'ok';
            },
          );
      expect(result.profileId, 'b');
    },
  );
  test(
    'caller cancellation stops routing even if transport ignores its token',
    () async {
      final parent = CancelToken();
      final calls = <String>[];
      final task = PriorityModelRouter().execute<String>(
        profiles: [profile('a'), profile('b')],
        allowFallback: true,
        cancelToken: parent,
        request: (p, _) {
          calls.add(p.id);
          parent.cancel();
          return Completer<String>().future;
        },
      );
      await expectLater(task, throwsA(isA<DioException>()));
      expect(calls, ['a']);
    },
  );
  test(
    'all failed result is bounded and contains no server response',
    () async {
      await expectLater(
        PriorityModelRouter().execute<String>(
          profiles: [profile('a'), profile('b')],
          allowFallback: true,
          request: (p, _) async => throw unavailable(),
        ),
        throwsA(
          isA<AiRouteFailure>()
              .having((e) => e.failures.length, 'count', 2)
              .having(
                (e) => e.toString(),
                'safe text',
                isNot(contains('PRIVATE')),
              ),
        ),
      );
    },
  );
  test('configuration change bypasses an obsolete cooldown', () async {
    final router = PriorityModelRouter();
    await expectLater(
      router.execute<String>(
        profiles: [profile('a')],
        allowFallback: true,
        request: (p, _) async => throw unavailable(),
      ),
      throwsA(isA<AiRouteFailure>()),
    );
    final result = await router.execute(
      profiles: [profile('a', key: 'replacement-fixture')],
      allowFallback: true,
      request: (p, _) async => p.settings.apiKey,
    );
    expect(result.value, 'replacement-fixture');
  });
  test(
    'total deadline stops the chain and cancels the active transport',
    () async {
      final calls = <String>[];
      CancelToken? active;
      await expectLater(
        PriorityModelRouter(
          attemptTimeout: const Duration(seconds: 1),
          totalTimeout: const Duration(milliseconds: 20),
        ).execute<String>(
          profiles: [profile('a'), profile('b')],
          allowFallback: true,
          request: (p, token) {
            calls.add(p.id);
            active = token;
            return Completer<String>().future;
          },
        ),
        throwsA(isA<AiRouteFailure>()),
      );
      expect(calls, ['a']);
      expect(active!.isCancelled, isTrue);
    },
  );
  test('configuration order is frozen for an in-flight request', () async {
    final profiles = [profile('a'), profile('b'), profile('c')];
    final first = Completer<String>();
    final calls = <String>[];
    final result = PriorityModelRouter().execute<String>(
      profiles: profiles,
      allowFallback: true,
      request: (p, token) {
        calls.add(p.id);
        return p.id == 'a' ? first.future : Future.value(p.id);
      },
    );
    profiles.setAll(0, [profile('c'), profile('a'), profile('b')]);
    first.completeError(unavailable());
    expect((await result).profileId, 'b');
    expect(calls, ['a', 'b']);
  });
}
