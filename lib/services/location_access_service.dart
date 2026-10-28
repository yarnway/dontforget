import 'dart:io';
import 'package:geolocator/geolocator.dart';

enum LocationAccess {
  available,
  denied,
  deniedForever,
  disabled,
  unsupported,
  failed,
}

class ApproximateLocation {
  const ApproximateLocation(this.latitude, this.longitude);
  final double latitude, longitude;
}

class LocationAccessResult {
  const LocationAccessResult(this.access, [this.point]);
  final LocationAccess access;
  final ApproximateLocation? point;
}

abstract interface class LocationGateway {
  bool get supported;
  Future<bool> serviceEnabled();
  Future<LocationPermission> check();
  Future<LocationPermission> request();
  Future<Position> current();
  Future<bool> openSettings({bool services = false});
}

class SystemLocationGateway implements LocationGateway {
  @override
  bool get supported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;
  @override
  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();
  @override
  Future<LocationPermission> check() => Geolocator.checkPermission();
  @override
  Future<LocationPermission> request() => Geolocator.requestPermission();
  @override
  Future<Position> current() => Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.low,
      timeLimit: Duration(seconds: 12),
    ),
  );
  @override
  Future<bool> openSettings({bool services = false}) => services
      ? Geolocator.openLocationSettings()
      : Geolocator.openAppSettings();
}

/// Only an explicit foreground action can access a device position. There is
/// no position stream, background permission request or automatic collection.
class LocationAccessService {
  LocationAccessService({LocationGateway? gateway, DateTime Function()? clock})
    : gateway = gateway ?? SystemLocationGateway(),
      clock = clock ?? DateTime.now;
  final LocationGateway gateway;
  final DateTime Function() clock;
  bool _busy = false;
  Future<bool> repair(LocationAccess access) async {
    if (!gateway.supported) return false;
    try {
      return await gateway.openSettings(
        services: access == LocationAccess.disabled,
      );
    } catch (_) {
      return false;
    }
  }

  Future<LocationAccessResult> locate({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent() || _busy) {
      return const LocationAccessResult(LocationAccess.failed);
    }
    if (!gateway.supported) {
      return const LocationAccessResult(LocationAccess.unsupported);
    }
    _busy = true;
    try {
      if (!await gateway.serviceEnabled() || !isCurrent()) {
        return const LocationAccessResult(LocationAccess.disabled);
      }
      var permission = await gateway.check();
      if (!isCurrent()) {
        return const LocationAccessResult(LocationAccess.failed);
      }
      if (permission == LocationPermission.denied) {
        permission = await gateway.request();
      }
      if (!isCurrent()) {
        return const LocationAccessResult(LocationAccess.failed);
      }
      if (permission == LocationPermission.deniedForever) {
        return const LocationAccessResult(LocationAccess.deniedForever);
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return const LocationAccessResult(LocationAccess.denied);
      }
      final point = await gateway.current().timeout(
        const Duration(seconds: 15),
      );
      if (!isCurrent()) {
        return const LocationAccessResult(LocationAccess.failed);
      }
      if (!point.latitude.isFinite ||
          point.latitude.abs() > 90 ||
          !point.longitude.isFinite ||
          point.longitude.abs() > 180 ||
          !point.accuracy.isFinite ||
          point.accuracy < 0 ||
          point.accuracy > 50000 ||
          point.timestamp.isAfter(clock().add(const Duration(minutes: 1))) ||
          clock().difference(point.timestamp) > const Duration(minutes: 5)) {
        return const LocationAccessResult(LocationAccess.failed);
      }
      return LocationAccessResult(
        LocationAccess.available,
        ApproximateLocation(
          (point.latitude * 100).round() / 100,
          (point.longitude * 100).round() / 100,
        ),
      );
    } catch (_) {
      return const LocationAccessResult(LocationAccess.failed);
    } finally {
      _busy = false;
    }
  }
}
