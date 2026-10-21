import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/llm_service.dart';

void main() {
  final configured = AppSettings.defaults().copyWith(
    apiKey: 'fixture-not-a-real-key',
    modelName: 'deepseek-v4.1-flash',
  );
  test('known Flash names normalize only for the official endpoint', () {
    expect(configured.requestModelName, 'deepseek-flash');
    expect(configured.toJson()['model_name'], 'deepseek-v4.1-flash');
    for (final url in [
      'https://gateway.example/v1',
      'https://api.deepseek.com.evil.example',
      'http://api.deepseek.com',
      'https://api.deepseek.com/custom',
    ]) {
      expect(
        configured.copyWith(baseUrl: url).requestModelName,
        'deepseek-v4.1-flash',
      );
    }
    expect(
      configured.copyWith(modelName: 'deepseek-v4-pro').requestModelName,
      'deepseek-v4-pro',
    );
    expect(
      configured.copyWith(modelName: 'future-custom-model').requestModelName,
      'future-custom-model',
    );
  });

  test(
    'extraction sends the API model identifier without changing saved settings',
    () async {
      final dio = Dio();
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            expect(options.data['model'], 'deepseek-flash');
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'choices': [
                    {
                      'message': {
                        'content':
                            '{"tasks":[{"title":"Fixture","quadrant":2,"time":"2050-01-01 09:00"}]}',
                      },
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      final tasks = await LLMService(
        client: dio,
      ).extractTasks('fixture', configured);
      expect(tasks.single.taskTitle, 'Fixture');
      expect(calls, 1);
      expect(configured.modelName, 'deepseek-v4.1-flash');
      dio.close();
    },
  );

  for (final status in [400, 401, 402, 403, 404, 422]) {
    test(
      'HTTP $status is not repeated and raw server text stays private',
      () async {
        final dio = Dio();
        var calls = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              calls++;
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response(
                    requestOptions: options,
                    statusCode: status,
                    data: {
                      'error': {
                        'message':
                            'The supported API model names are deepseek-flash, but you passed deepseek-v4.1-flash (request_id: SECRET-REQUEST)',
                      },
                    },
                  ),
                ),
              );
            },
          ),
        );
        final service = LLMService(client: dio);
        try {
          await service.extractTasks('fixture', configured);
          fail('Expected rejection');
        } catch (error) {
          expect(error, isA<DioException>());
          final message = service.formatErrorMessage(error);
          expect(message.length, lessThan(50));
          expect(message, isNot(contains('SECRET-REQUEST')));
          expect(message, isNot(contains('The supported')));
        }
        expect(calls, 1);
        dio.close();
      },
    );
  }

  test('non-JSON and unexpected errors get safe concise feedback', () {
    final service = LLMService();
    for (final body in [
      '<html>private upstream error</html>',
      ['private'],
      null,
    ]) {
      final options = RequestOptions(path: '/fixture');
      final error = DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: 500,
          data: body,
        ),
      );
      expect(service.formatErrorMessage(error), 'AI 服务暂不可用，请稍后重试。');
    }
    expect(
      service.formatErrorMessage(Exception('secret credential')),
      isNot(contains('secret')),
    );
  });
}
