import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/models/ai_profile.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:dont_forget/services/multi_agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deliberately ignores close while a response is pending. This proves callers
/// reject a late response even when a transport cannot retract received bytes.
class _LateAdapter implements HttpClientAdapter {
  final started = Completer<void>();
  final response = Completer<ResponseBody>();
  final requests = <RequestOptions>[];
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    if (!started.isCompleted) started.complete();
    return response.future;
  }

  @override
  void close({bool force = false}) => closed = force;

  void complete(Map<String, Object?> value) => response.complete(
    ResponseBody.fromString(
      jsonEncode(value),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ),
  );
}

void main() {
  final settings = AppSettings.defaults().copyWith(
    apiKey: 'isolated-key',
    baseUrl: 'https://fixture.invalid/v1',
    modelName: 'fixture',
  );
  Map<String, Object?> chat(String content) => {
    'choices': [
      {
        'message': {'content': content},
      },
    ],
  };

  test(
    'disposing a model route cancels its transport and never calls fallback',
    () async {
      final adapter = _LateAdapter();
      final service = LLMService(client: Dio()..httpClientAdapter = adapter);
      final routed = settings.copyWith(
        aiProfiles: [
          AiProfile(id: 'a', label: 'A', settings: settings),
          AiProfile(
            id: 'b',
            label: 'B',
            settings: settings.copyWith(
              baseUrl: 'https://second.invalid/v1',
              apiKey: 'second-only',
            ),
          ),
        ],
        aiFallbackEnabled: true,
      );
      final result = service.extractTasks('synthetic input', routed);
      final rejected = expectLater(
        result,
        throwsA(anyOf(isA<DioException>(), isA<StateError>())),
      );
      await adapter.started.future;
      service.dispose();
      await rejected;
      adapter.complete(chat('{"tasks":[{"title":"late task"}]}'));
      await Future<void>.delayed(Duration.zero);
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.followRedirects, isFalse);
    },
  );

  test(
    'disposing multi-agent transport blocks a late manager response from starting decomposer',
    () async {
      final adapter = _LateAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final service = MultiAgentService(client: dio);
      final result = service.executePipeline(
        '准备旧会话的复杂项目和执行计划',
        settings: settings,
      );
      final rejected = expectLater(result, throwsStateError);
      await adapter.started.future;
      service.dispose();
      expect(adapter.closed, isTrue);
      adapter.complete(
        chat(
          '{"macro_title":"old project","quadrant":2,"needs_decomposition":true}',
        ),
      );
      await rejected;
      expect(adapter.requests, hasLength(1));
      await expectLater(
        service.executePipeline('new call on old instance', settings: settings),
        throwsStateError,
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'disposing extraction transport rejects late success and new requests',
    () async {
      final adapter = _LateAdapter();
      final service = LLMService(client: Dio()..httpClientAdapter = adapter);
      final result = service.extractTasks('old input', settings);
      final rejected = expectLater(result, throwsStateError);
      await adapter.started.future;
      service.dispose();
      expect(adapter.closed, isTrue);
      adapter.complete(chat('{"tasks":[{"title":"old task","quadrant":2}]}'));
      await rejected;
      await expectLater(
        service.extractTasksFromImage('image', settings),
        throwsStateError,
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'disposing extraction before a retry prevents the next network request',
    () async {
      final dio = Dio();
      final started = Completer<void>();
      var requests = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            started.complete();
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            );
          },
        ),
      );
      final service = LLMService(client: dio);
      final result = service.extractTasks('old input', settings);
      final rejected = expectLater(result, throwsStateError);
      await started.future;
      // Let the transient failure enter its delayed retry before shutting down.
      await Future<void>.delayed(Duration.zero);
      service.dispose();
      await rejected;
      expect(requests, 1);
    },
  );

  test(
    'disposing local endpoint probe closes it and prevents later probes',
    () async {
      final adapter = _LateAdapter();
      final probe = Dio()..httpClientAdapter = adapter;
      final service = LLMService(probeClientFactory: () => probe);
      final result = service.probeLocalInferenceEndpoints();
      final rejected = expectLater(result, throwsStateError);
      await adapter.started.future;
      service.dispose();
      expect(adapter.closed, isTrue);
      adapter.complete({
        'models': [
          {'name': 'old-local-model'},
        ],
      });
      await rejected;
      expect(adapter.requests, hasLength(1));
      await expectLater(
        service.probeLocalInferenceEndpoints(),
        throwsStateError,
      );
    },
  );
}
