import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dont_forget/models/settings.dart';
import 'package:dont_forget/services/departure_weather_service.dart';
import 'package:dont_forget/services/llm_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<Map<String, dynamic>> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(await respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'structured proposal keeps configured gateway, content and cancellation route',
    () async {
      final adapter = _Adapter(
        (_) => {
          'choices': [
            {
              'message': {
                'content': '{"medicines":[],"start":null,"end":null}',
              },
            },
          ],
        },
      );
      final client = Dio()..httpClientAdapter = adapter;
      final model = LLMService(client: client);
      final settings = AppSettings.defaults().copyWith(
        apiKey: 'synthetic-key',
        baseUrl: 'https://fixture.invalid/custom/v1',
        modelName: 'fixture-model',
      );
      final result = await model.structuredProposal(
        'Do not infer dose or course dates.',
        'Approximate course only',
        settings,
      );
      expect(result['start'], isNull);
      expect(result['medicines'], isEmpty);
      expect(
        adapter.requests.single.uri.toString(),
        'https://fixture.invalid/custom/v1/chat/completions',
      );
      expect(adapter.requests.single.followRedirects, isFalse);
      expect(
        adapter.requests.single.data['messages'][1]['content'],
        'Approximate course only',
      );
      model.dispose();
    },
  );
  test(
    'invalid structured model output cannot become an actionable proposal',
    () async {
      final client = Dio()
        ..httpClientAdapter = _Adapter(
          (_) => {
            'choices': [
              {
                'message': {'content': '[]'},
              },
            ],
          },
        );
      final model = LLMService(client: client);
      await expectLater(
        model.structuredProposal(
          'Return an object',
          'data',
          AppSettings.defaults().copyWith(apiKey: 'synthetic-key'),
        ),
        throwsA(anything),
      );
      model.dispose();
    },
  );
  test(
    'weather city selection uses explicit public endpoint without model credentials',
    () async {
      final adapter = _Adapter(
        (_) => {
          'results': [
            {
              'name': 'Fixture city',
              'country': 'Fixture country',
              'latitude': 31.0,
              'longitude': 121.0,
            },
          ],
        },
      );
      final service = DepartureWeatherService(
        client: Dio()..httpClientAdapter = adapter,
      );
      final cities = await service.cities('Fixture');
      expect(cities.single.latitude, 31);
      expect(adapter.requests.single.uri.host, 'geocoding-api.open-meteo.com');
      expect(
        adapter.requests.single.headers.containsKey('Authorization'),
        isFalse,
      );
      service.dispose();
    },
  );
  test(
    'weather forecast matches UTC epochs and rejects invalid hourly data',
    () async {
      final now = DateTime.utc(2030, 1, 1, 8);
      final adapter = _Adapter(
        (_) => {
          'hourly': {
            'time': [
              now.millisecondsSinceEpoch ~/ 1000,
              now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
            ],
            'precipitation_probability': [80, 10],
          },
        },
      );
      final service = DepartureWeatherService(
        client: Dio()..httpClientAdapter = adapter,
      );
      final forecast = await service.fetch(31, 121, now: now);
      expect(forecast.rainDuring(now, now, now: now), isTrue);
      expect(adapter.requests.single.queryParameters['timeformat'], 'unixtime');
      expect(adapter.requests.single.queryParameters['timezone'], 'GMT');
      service.dispose();
      final invalid = DepartureWeatherService(
        client: Dio()
          ..httpClientAdapter = _Adapter(
            (_) => {
              'hourly': {
                'time': [1, 3601],
                'precipitation_probability': [101, 0],
              },
            },
          ),
      );
      await expectLater(
        invalid.fetch(31, 121, now: now),
        throwsFormatException,
      );
      invalid.dispose();
    },
  );
}
