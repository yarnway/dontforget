import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const appRepositoryUrl = 'https://github.com/yarnway/dontforget';
const appReleasesUrl = '$appRepositoryUrl/releases';
const iosInstallGuideUrl =
    '$appRepositoryUrl/blob/main/docs/iOS_Sideload_Windows.md';

/// Distribution versions in this project always have three numeric components.
class AppVersion implements Comparable<AppVersion> {
  AppVersion._(this.value, List<int> parts) : parts = List.unmodifiable(parts);

  factory AppVersion.parse(String value) {
    if (!RegExp(
      r'^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})$',
    ).hasMatch(value)) {
      throw const FormatException('Unsupported application version');
    }
    return AppVersion._(value, value.split('.').map(int.parse).toList());
  }

  final String value;
  final List<int> parts;

  @override
  int compareTo(AppVersion other) {
    for (var i = 0; i < 3; i++) {
      final order = parts[i].compareTo(other.parts[i]);
      if (order != 0) return order;
    }
    return 0;
  }
}

class InstalledAppInfo {
  InstalledAppInfo({
    required String name,
    required String version,
    required this.buildNumber,
  }) : name = name.trim().isEmpty ? 'DontForget' : name.trim(),
       version = AppVersion.parse(version);

  final String name;
  final AppVersion version;
  final String buildNumber;
  int? get numericBuild => RegExp(r'^[0-9]{1,9}$').hasMatch(buildNumber)
      ? int.parse(buildNumber)
      : null;
  String get displayVersion =>
      buildNumber.isEmpty ? version.value : '${version.value} ($buildNumber)';
}

enum UpdatePlatform { windows, linux, android, ios, macos, other }

enum ReleasePackage {
  windowsSetup,
  windowsPortable,
  linuxArchive,
  androidUniversal,
  androidArm64,
  iosUnsigned,
}

enum UpdateComparison { newer, current, ahead, sameVersionBuildUnknown }

enum UpdateFailure {
  network,
  timeout,
  rateLimited,
  noRelease,
  invalidResponse,
  server,
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.failure);
  final UpdateFailure failure;
}

class ReleaseDownload {
  const ReleaseDownload(this.kind, this.url, this.bytes);
  final ReleasePackage kind;
  final Uri url;
  final int bytes;
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.buildNumber,
    required this.notes,
    required this.url,
    required this.downloads,
  });
  final AppVersion version;
  final int? buildNumber;
  final String notes;
  final Uri url;
  final List<ReleaseDownload> downloads;

  String get displayVersion =>
      buildNumber == null ? version.value : '${version.value} ($buildNumber)';
  List<ReleaseDownload> forPlatform(UpdatePlatform platform) => downloads
      .where(
        (download) => switch (platform) {
          UpdatePlatform.windows => const [
            ReleasePackage.windowsSetup,
            ReleasePackage.windowsPortable,
          ].contains(download.kind),
          UpdatePlatform.android => const [
            ReleasePackage.androidUniversal,
            ReleasePackage.androidArm64,
          ].contains(download.kind),
          UpdatePlatform.linux => download.kind == ReleasePackage.linuxArchive,
          UpdatePlatform.ios => download.kind == ReleasePackage.iosUnsigned,
          _ => false,
        },
      )
      .toList(growable: false);
}

class AppUpdateResult {
  const AppUpdateResult(this.release, this.comparison);
  final AppRelease release;
  final UpdateComparison comparison;
}

class ReleaseHttpResponse {
  const ReleaseHttpResponse(this.statusCode, this.body);
  final int statusCode;
  final List<int> body;
}

typedef ReleaseFetcher =
    Future<ReleaseHttpResponse> Function(Uri uri, int maxBytes);

/// Uses a separate public HTTP client, without model configuration or credentials.
/// Constructing the service and opening Settings never performs a request.
class AppUpdateService {
  AppUpdateService({ReleaseFetcher? fetch})
    : _fetch = fetch ?? _fetchPublicRelease;
  final ReleaseFetcher _fetch;
  static final latestUri = Uri.parse(
    'https://api.github.com/repos/yarnway/dontforget/releases/latest',
  );
  static final latestProvenanceUri = Uri.parse(
    '$appReleasesUrl/latest/download/release-provenance.json',
  );
  static const metadataLimit = 512 * 1024;
  static const provenanceLimit = 128 * 1024;

  Future<AppUpdateResult> check(InstalledAppInfo installed) async {
    try {
      final List<int> metadata;
      try {
        metadata = await _read(latestUri, metadataLimit);
      } on UpdateCheckException catch (error) {
        if (error.failure != UpdateFailure.rateLimited) rethrow;
        return await _fromPublicProvenance(installed);
      }
      final release = _object(metadata);
      if (release['draft'] != false || release['prerelease'] != false) {
        _invalid();
      }
      final tag = release['tag_name'];
      if (tag is! String || !tag.startsWith('v')) _invalid();
      final version = AppVersion.parse((tag).substring(1));
      final url = Uri.parse('$appReleasesUrl/tag/$tag');
      if (release['html_url'] != url.toString()) _invalid();
      final rawAssets = release['assets'];
      if (rawAssets is! List || rawAssets.length > 100) _invalid();
      final assets = <String, Map<String, dynamic>>{};
      for (final item in rawAssets) {
        if (item is! Map<String, dynamic> || item['name'] is! String) {
          _invalid();
        }
        final asset = item;
        final name = asset['name'] as String;
        if (assets.containsKey(name)) _invalid();
        assets[name] = asset;
      }
      final order = version.compareTo(installed.version);
      int? build;
      // Build numbers distinguish a newer final build from a same-version candidate.
      if (order == 0 && installed.numericBuild != null) {
        final provenance = assets['release-provenance.json'];
        if (provenance != null && provenance['state'] == 'uploaded') {
          final size = provenance['size'];
          final checksum = provenance['digest'];
          if (size is! int ||
              size <= 0 ||
              size > provenanceLimit ||
              checksum is! String ||
              !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(checksum)) {
            _invalid();
          }
          final bytes = await _read(
            Uri.parse(
              '$appRepositoryUrl/releases/download/$tag/release-provenance.json',
            ),
            provenanceLimit,
          );
          if (bytes.length != size ||
              'sha256:${sha256.convert(bytes)}' != checksum) {
            _invalid();
          }
          final proof = _object(bytes);
          if (proof['version'] != version.value ||
              proof['build_number'] is! String ||
              !RegExp(
                r'^[0-9]{1,9}$',
              ).hasMatch(proof['build_number'] as String)) {
            _invalid();
          }
          build = int.parse(proof['build_number'] as String);
        }
      }
      final downloads = _downloads(version, tag, assets);
      final notes = release['body'];
      if (notes != null && notes is! String) _invalid();
      final comparison = _compare(version, build, installed);
      final text = notes as String? ?? '';
      return AppUpdateResult(
        AppRelease(
          version: version,
          buildNumber: build,
          notes: text.length > 32000 ? text.substring(0, 32000) : text,
          url: url,
          downloads: List.unmodifiable(downloads),
        ),
        comparison,
      );
    } on UpdateCheckException {
      rethrow;
    } on TimeoutException {
      throw const UpdateCheckException(UpdateFailure.timeout);
    } on SocketException {
      throw const UpdateCheckException(UpdateFailure.network);
    } on HandshakeException {
      throw const UpdateCheckException(UpdateFailure.network);
    } on HttpException {
      throw const UpdateCheckException(UpdateFailure.network);
    } on FormatException {
      throw const UpdateCheckException(UpdateFailure.invalidResponse);
    }
  }

  Future<AppUpdateResult> _fromPublicProvenance(
    InstalledAppInfo installed,
  ) async {
    final proof = _object(await _read(latestProvenanceUri, provenanceLimit));
    final versionText = proof['version'];
    final buildText = proof['build_number'];
    final revision = proof['revision'];
    final files = proof['files'];
    if (versionText is! String ||
        buildText is! String ||
        !RegExp(r'^[0-9]{1,9}$').hasMatch(buildText) ||
        revision is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(revision) ||
        files is! List ||
        files.isEmpty ||
        files.length > 100) {
      _invalid();
    }
    final version = AppVersion.parse(versionText);
    final build = int.parse(buildText);
    final assets = <String, Map<String, dynamic>>{};
    for (final item in files) {
      if (item is! Map<String, dynamic>) _invalid();
      final filename = item['file'];
      final bytes = item['bytes'];
      final checksum = item['sha256'];
      if (filename is! String ||
          assets.containsKey(filename) ||
          bytes is! int ||
          bytes < 0 ||
          checksum is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum)) {
        _invalid();
      }
      assets[filename] = {'name': filename, 'state': 'uploaded', 'size': bytes};
    }
    final tag = 'v${version.value}';
    return AppUpdateResult(
      AppRelease(
        version: version,
        buildNumber: build,
        notes: '',
        url: Uri.parse('$appReleasesUrl/tag/$tag'),
        downloads: _downloads(version, tag, assets),
      ),
      _compare(version, build, installed),
    );
  }

  static UpdateComparison _compare(
    AppVersion version,
    int? build,
    InstalledAppInfo installed,
  ) {
    final order = version.compareTo(installed.version);
    return order > 0
        ? UpdateComparison.newer
        : order < 0
        ? UpdateComparison.ahead
        : build == null || installed.numericBuild == null
        ? UpdateComparison.sameVersionBuildUnknown
        : build > installed.numericBuild!
        ? UpdateComparison.newer
        : build < installed.numericBuild!
        ? UpdateComparison.ahead
        : UpdateComparison.current;
  }

  static List<ReleaseDownload> _downloads(
    AppVersion version,
    String tag,
    Map<String, Map<String, dynamic>> assets,
  ) {
    final filenames = <ReleasePackage, String>{
      ReleasePackage.windowsSetup: 'DontForget_Setup_v${version.value}.exe',
      ReleasePackage.windowsPortable:
          'DontForget_Windows_Portable_v${version.value}.zip',
      ReleasePackage.linuxArchive:
          'DontForget_Linux_x64_v${version.value}.tar.gz',
      ReleasePackage.androidUniversal:
          'DontForget_Android_v${version.value}.apk',
      ReleasePackage.androidArm64:
          'DontForget_Android_arm64_v${version.value}.apk',
      ReleasePackage.iosUnsigned:
          'DontForget_iOS_unsigned_v${version.value}.ipa',
    };
    final downloads = <ReleaseDownload>[];
    for (final entry in filenames.entries) {
      final asset = assets[entry.value];
      if (asset == null || asset['state'] != 'uploaded') continue;
      final bytes = asset['size'];
      if (bytes is! int || bytes <= 0) _invalid();
      // Construct links from this repository and known filenames, never remote URLs.
      downloads.add(
        ReleaseDownload(
          entry.key,
          Uri.parse('$appRepositoryUrl/releases/download/$tag/${entry.value}'),
          bytes,
        ),
      );
    }
    return List.unmodifiable(downloads);
  }

  Future<List<int>> _read(Uri uri, int limit) async {
    final response = await _fetch(
      uri,
      limit,
    ).timeout(const Duration(seconds: 20));
    switch (response.statusCode) {
      case 200:
        break;
      case 404:
        throw UpdateCheckException(
          uri == latestUri
              ? UpdateFailure.noRelease
              : UpdateFailure.invalidResponse,
        );
      case 403 || 429:
        throw const UpdateCheckException(UpdateFailure.rateLimited);
      default:
        throw const UpdateCheckException(UpdateFailure.server);
    }
    if (response.body.length > limit) _invalid();
    return response.body;
  }

  static Map<String, dynamic> _object(List<int> bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) _invalid();
    return value;
  }

  static Never _invalid() =>
      throw const UpdateCheckException(UpdateFailure.invalidResponse);
}

Future<ReleaseHttpResponse> _fetchPublicRelease(Uri uri, int maxBytes) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  Future<ReleaseHttpResponse> read() async {
    var target = uri;
    for (var redirects = 0; redirects <= 4; redirects++) {
      if (target.scheme != 'https' ||
          target.userInfo.isNotEmpty ||
          target.port != 443 ||
          !const {
            'api.github.com',
            'github.com',
            'objects.githubusercontent.com',
            'release-assets.githubusercontent.com',
          }.contains(target.host)) {
        throw const UpdateCheckException(UpdateFailure.invalidResponse);
      }
      final request = await client.getUrl(target);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'DontForget-Update-Check',
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set('X-GitHub-Api-Version', '2026-03-10');
      final response = await request.close();
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.length > 8192) {
          throw const UpdateCheckException(UpdateFailure.invalidResponse);
        }
        target = target.resolve(location);
        await response.drain<void>();
        continue;
      }
      if (response.statusCode != 200) {
        return ReleaseHttpResponse(response.statusCode, const []);
      }
      if (response.contentLength > maxBytes) {
        throw const UpdateCheckException(UpdateFailure.invalidResponse);
      }
      final body = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (body.length + chunk.length > maxBytes) {
          throw const UpdateCheckException(UpdateFailure.invalidResponse);
        }
        body.add(chunk);
      }
      return ReleaseHttpResponse(200, body.takeBytes());
    }
    throw const UpdateCheckException(UpdateFailure.invalidResponse);
  }

  try {
    return await read().timeout(const Duration(seconds: 15));
  } finally {
    client.close(force: true);
  }
}
