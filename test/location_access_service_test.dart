import 'dart:async';
import 'package:dont_forget/services/location_access_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

class _Gateway implements LocationGateway {
  @override
  bool supported = true;
  bool enabled = true;
  LocationPermission permission = LocationPermission.denied,
      answer = LocationPermission.whileInUse;
  int reads = 0, checks = 0, requests = 0;
  Completer<Position>? barrier;
  late Position position;
  @override
  Future<bool> serviceEnabled() async => enabled;
  @override
  Future<LocationPermission> check() async {
    checks++;
    return permission;
  }

  @override
  Future<LocationPermission> request() async {
    requests++;
    return answer;
  }

  @override
  Future<Position> current() async {
    reads++;
    return barrier == null ? position : await barrier!.future;
  }

  @override
  Future<bool> openSettings({bool services = false}) async => true;
}

Position point(
  DateTime at, {
  double lat = 31.23456,
  double lon = 121.98765,
  double accuracy = 1000,
}) => Position(
  longitude: lon,
  latitude: lat,
  timestamp: at,
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);
void main() {
  final now = DateTime(2026, 10, 28, 8);
  late _Gateway gateway;
  late LocationAccessService service;
  setUp(() {
    gateway = _Gateway()..position = point(now);
    service = LocationAccessService(gateway: gateway, clock: () => now);
  });
  test('construction never queries permission or samples location', () {
    expect(gateway.checks, 0);
    expect(gateway.reads, 0);
  });
  test(
    'explicit foreground sample asks once and returns rounded coordinates',
    () async {
      final result = await service.locate(isCurrent: () => true);
      expect(result.access, LocationAccess.available);
      expect(result.point!.latitude, 31.23);
      expect(result.point!.longitude, 121.99);
      expect(gateway.requests, 1);
      expect(gateway.reads, 1);
    },
  );
  for (final permission in [
    LocationPermission.denied,
    LocationPermission.deniedForever,
    LocationPermission.unableToDetermine,
  ]) {
    test('denied permission $permission never reads a position', () async {
      gateway.permission = permission;
      gateway.answer = permission;
      final result = await service.locate(isCurrent: () => true);
      expect(result.point, isNull);
      expect(gateway.reads, 0);
      expect(gateway.requests, permission == LocationPermission.denied ? 1 : 0);
    });
  }
  test('disabled and unsupported states make no permission request', () async {
    gateway.enabled = false;
    expect(
      (await service.locate(isCurrent: () => true)).access,
      LocationAccess.disabled,
    );
    gateway.supported = false;
    expect(
      (await service.locate(isCurrent: () => true)).access,
      LocationAccess.unsupported,
    );
    expect(gateway.requests, 0);
    expect(gateway.reads, 0);
  });
  test('stale view never requests and late sample cannot be applied', () async {
    expect((await service.locate(isCurrent: () => false)).point, isNull);
    expect(gateway.checks, 0);
    var active = true;
    gateway.barrier = Completer<Position>();
    final pending = service.locate(isCurrent: () => active);
    while (gateway.reads == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    active = false;
    gateway.barrier!.complete(point(now));
    expect((await pending).point, isNull);
  });
  test(
    'concurrent taps share no second permission or location request',
    () async {
      gateway.barrier = Completer<Position>();
      final first = service.locate(isCurrent: () => true);
      expect((await service.locate(isCurrent: () => true)).point, isNull);
      gateway.barrier!.complete(point(now));
      await first;
      expect(gateway.requests, 1);
      expect(gateway.reads, 1);
    },
  );
  for (final invalid in [
    point(now, lat: 91),
    point(now, lon: double.nan),
    point(now, accuracy: -1),
    point(now, accuracy: 50001),
    point(now.subtract(const Duration(minutes: 6))),
    point(now.add(const Duration(minutes: 2))),
  ]) {
    test(
      'unusable or stale sample is discarded ${invalid.latitude}/${invalid.accuracy}/${invalid.timestamp}',
      () async {
        gateway.position = invalid;
        expect((await service.locate(isCurrent: () => true)).point, isNull);
      },
    );
  }
}
