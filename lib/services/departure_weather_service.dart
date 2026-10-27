import 'package:dio/dio.dart';
import '../models/task_details.dart';

class WeatherForecast {
  const WeatherForecast(
    this.fetchedAt,
    this.hours,
    this.probabilities, {
    required this.latitude,
    required this.longitude,
  });
  final DateTime fetchedAt;
  final List<DateTime> hours;
  final List<int?> probabilities;
  final double latitude, longitude;
  static const source = 'Open-Meteo';
  factory WeatherForecast.fromJson(Map data) {
    final hours = data['hours'], values = data['probabilities'];
    if (hours is! List ||
        values is! List ||
        hours.isEmpty ||
        hours.length > 400 ||
        hours.length != values.length ||
        values.any((p) => p != null && (p is! int || p < 0 || p > 100))) {
      throw const FormatException('Invalid weather snapshot');
    }
    final parsed = hours.map((h) => TaskDetails.date(h)!).toList();
    for (var i = 1; i < parsed.length; i++) {
      if (parsed[i].difference(parsed[i - 1]) != const Duration(hours: 1)) {
        throw const FormatException('Incomplete hourly weather');
      }
    }
    final lat = data['latitude'], lon = data['longitude'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      throw const FormatException('Invalid weather location');
    }
    return WeatherForecast(
      TaskDetails.date(data['fetched'])!,
      parsed,
      List<int?>.from(values),
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
    );
  }
  Map<String, dynamic> toJson() => {
    'source': source,
    'fetched': fetchedAt.toIso8601String(),
    'hours': hours.map((h) => h.toIso8601String()).toList(),
    'probabilities': probabilities,
    'latitude': latitude,
    'longitude': longitude,
  };

  /// Null means unknown, including gaps or stale cache; never "no rain".
  bool? rainDuring(
    DateTime start,
    DateTime end, {
    required DateTime now,
    int threshold = 40,
  }) {
    if (end.isBefore(start) ||
        now.difference(fetchedAt) > const Duration(hours: 6) ||
        fetchedAt.difference(now) > const Duration(minutes: 1) ||
        threshold < 1 ||
        threshold > 100) {
      return null;
    }
    final first = DateTime.fromMillisecondsSinceEpoch(
      start.toUtc().millisecondsSinceEpoch ~/ 3600000 * 3600000,
      isUtc: true,
    );
    final last = DateTime.fromMillisecondsSinceEpoch(
      end.toUtc().millisecondsSinceEpoch ~/ 3600000 * 3600000,
      isUtc: true,
    );
    var rain = false;
    for (var t = first; !t.isAfter(last); t = t.add(const Duration(hours: 1))) {
      final i = hours.indexWhere((h) => h.isAtSameMomentAs(t));
      if (i < 0 || probabilities[i] == null) return null;
      rain = rain || probabilities[i]! >= threshold;
    }
    return rain;
  }
}

class WeatherCity {
  const WeatherCity(this.name, this.latitude, this.longitude);
  final String name;
  final double latitude, longitude;
}

/// Only explicit user requests reach public Open-Meteo endpoints. No GPS access.
class DepartureWeatherService {
  DepartureWeatherService({Dio? client})
    : _client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 10),
              followRedirects: false,
            ),
          );
  final Dio _client;
  void dispose() => _client.close(force: true);
  Future<List<WeatherCity>> cities(
    String query, {
    CancelToken? cancelToken,
  }) async {
    if (query.trim().length < 2 || query.length > 120) {
      throw const FormatException('City name required');
    }
    final response = await _client.get(
      'https://geocoding-api.open-meteo.com/v1/search',
      queryParameters: {'name': query.trim(), 'count': 5, 'language': 'zh'},
      cancelToken: cancelToken,
    );
    final values = response.data is Map ? response.data['results'] : null;
    if (values == null) return [];
    if (values is! List || values.length > 5) {
      throw const FormatException('Invalid city results');
    }
    return values.map((row) {
      if (row is! Map ||
          row['name'] is! String ||
          row['latitude'] is! num ||
          row['longitude'] is! num) {
        throw const FormatException('Invalid city');
      }
      final lat = (row['latitude'] as num).toDouble(),
          lon = (row['longitude'] as num).toDouble();
      if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
        throw const FormatException('Invalid city');
      }
      return WeatherCity(
        [
          row['name'],
          row['admin1'],
          row['country'],
        ].whereType<String>().join(' · '),
        lat,
        lon,
      );
    }).toList();
  }

  Future<WeatherForecast> fetch(
    double latitude,
    double longitude, {
    required DateTime now,
    CancelToken? cancelToken,
  }) async {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      throw const FormatException('Invalid coordinates');
    }
    final response = await _client.get(
      'https://api.open-meteo.com/v1/forecast',
      queryParameters: {
        'latitude': latitude,
        'longitude': longitude,
        'hourly': 'precipitation_probability',
        'timeformat': 'unixtime',
        'timezone': 'GMT',
        'forecast_days': 7,
      },
      cancelToken: cancelToken,
    );
    final data = response.data, hourly = data is Map ? data['hourly'] : null;
    if (hourly is! Map ||
        hourly['time'] is! List ||
        hourly['precipitation_probability'] is! List) {
      throw const FormatException('Invalid weather response');
    }
    final times = hourly['time'] as List;
    if (times.any((t) => t is! int || t < 0)) {
      throw const FormatException('Invalid forecast times');
    }
    return WeatherForecast.fromJson({
      'fetched': now.toUtc().toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'hours': times
          .map(
            (t) => DateTime.fromMillisecondsSinceEpoch(
              t * 1000,
              isUtc: true,
            ).toIso8601String(),
          )
          .toList(),
      'probabilities': hourly['precipitation_probability'],
    });
  }
}
