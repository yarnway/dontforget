import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dont_forget/services/app_update_service.dart';

Map<String, dynamic> releaseFixture([String version = '1.8.12']) => {
  'tag_name': 'v$version',
  'html_url': '$appReleasesUrl/tag/v$version',
  'draft': false,
  'prerelease': false,
  'body': 'Updates for $version',
  'assets': [
    for (final name in [
      'DontForget_Setup_v$version.exe',
      'DontForget_Windows_Portable_v$version.zip',
      'DontForget_Linux_x64_v$version.tar.gz',
      'DontForget_Android_v$version.apk',
      'DontForget_Android_arm64_v$version.apk',
      'DontForget_iOS_unsigned_v$version.ipa',
    ])
      {
        'name': name,
        'state': 'uploaded',
        'size': 123,
        'browser_download_url': 'https://untrusted.invalid/ignored',
      },
  ],
};

ReleaseHttpResponse jsonResponse(Object value) =>
    ReleaseHttpResponse(200, utf8.encode(jsonEncode(value)));
InstalledAppInfo installed([String version = '1.8.11', String build = '81']) =>
    InstalledAppInfo(name: 'DontForget', version: version, buildNumber: build);
Matcher failure(UpdateFailure value) => isA<UpdateCheckException>().having(
  (error) => error.failure,
  'failure',
  value,
);

void main() {
  test(
    'API rate limits fall back to this project’s public latest provenance',
    () async {
      final calls = <Uri>[];
      final service = AppUpdateService(
        fetch: (uri, limit) async {
          calls.add(uri);
          if (uri == AppUpdateService.latestUri) {
            return const ReleaseHttpResponse(403, []);
          }
          return jsonResponse({
            'version': '1.8.11',
            'build_number': '82',
            'revision': 'b' * 40,
            'files': [
              {
                'file': 'DontForget_Setup_v1.8.11.exe',
                'bytes': 123,
                'sha256': 'a' * 64,
              },
            ],
          });
        },
      );
      final result = await service.check(installed());
      expect(calls, [
        AppUpdateService.latestUri,
        AppUpdateService.latestProvenanceUri,
      ]);
      expect(result.comparison, UpdateComparison.newer);
      expect(result.release.buildNumber, 82);
      expect(
        result.release.downloads.single.url.toString(),
        '$appRepositoryUrl/releases/download/v1.8.11/DontForget_Setup_v1.8.11.exe',
      );
    },
  );

  test('malformed public fallback metadata cannot claim an update', () async {
    for (final fault in ['revision', 'build', 'hash', 'duplicate']) {
      final item = {
        'file': 'DontForget_Setup_v1.8.11.exe',
        'bytes': 123,
        'sha256': fault == 'hash' ? 'broken' : 'a' * 64,
      };
      final service = AppUpdateService(
        fetch: (uri, limit) async => uri == AppUpdateService.latestUri
            ? const ReleaseHttpResponse(429, [])
            : jsonResponse({
                'version': '1.8.11',
                'build_number': fault == 'build' ? 'broken' : '82',
                'revision': fault == 'revision' ? 'broken' : 'b' * 40,
                'files': [item, if (fault == 'duplicate') item],
              }),
      );
      await expectLater(
        service.check(installed()),
        throwsA(failure(UpdateFailure.invalidResponse)),
      );
    }
  });

  test(
    'version ordering is numeric and malformed stable versions are rejected',
    () {
      expect(
        AppVersion.parse('1.10.0').compareTo(AppVersion.parse('1.9.99')),
        greaterThan(0),
      );
      expect(
        AppVersion.parse('2.0.0').compareTo(AppVersion.parse('1.99.99')),
        greaterThan(0),
      );
      for (final value in [
        '1.8',
        '01.8.11',
        '1.8.11-rc.1',
        'v1.8.11',
        '1.8.11/../other',
        '9999999999.1.0',
      ]) {
        expect(() => AppVersion.parse(value), throwsFormatException);
      }
    },
  );

  test(
    'only an explicit check requests public metadata and links stay in this repository',
    () async {
      final calls = <Uri>[];
      final service = AppUpdateService(
        fetch: (uri, limit) async {
          calls.add(uri);
          return jsonResponse(releaseFixture());
        },
      );
      expect(calls, isEmpty);
      final result = await service.check(installed());
      expect(calls, [AppUpdateService.latestUri]);
      expect(result.comparison, UpdateComparison.newer);
      expect(result.release.version.value, '1.8.12');
      expect(
        result.release.forPlatform(UpdatePlatform.windows).map((d) => d.kind),
        [ReleasePackage.windowsSetup, ReleasePackage.windowsPortable],
      );
      expect(
        result.release.forPlatform(UpdatePlatform.android).map((d) => d.kind),
        [ReleasePackage.androidUniversal, ReleasePackage.androidArm64],
      );
      expect(
        result.release.forPlatform(UpdatePlatform.ios).single.kind,
        ReleasePackage.iosUnsigned,
      );
      expect(result.release.forPlatform(UpdatePlatform.macos), isEmpty);
      expect(
        result.release.downloads.every(
          (d) => d.url.toString().startsWith(
            '$appRepositoryUrl/releases/download/v1.8.12/DontForget_',
          ),
        ),
        isTrue,
      );
    },
  );

  test('older public releases never offer a downgrade', () async {
    final service = AppUpdateService(
      fetch: (uri, limit) async => jsonResponse(releaseFixture('1.8.10')),
    );
    expect(
      (await service.check(installed())).comparison,
      UpdateComparison.ahead,
    );
  });

  test(
    'same-version candidates compare verified provenance build numbers',
    () async {
      for (final build in ['80', '81', '82']) {
        final proof = utf8.encode(
          jsonEncode({'version': '1.8.11', 'build_number': build}),
        );
        final metadata = releaseFixture('1.8.11');
        (metadata['assets'] as List).add({
          'name': 'release-provenance.json',
          'state': 'uploaded',
          'size': proof.length,
          'digest': 'sha256:${sha256.convert(proof)}',
        });
        final calls = <Uri>[];
        final service = AppUpdateService(
          fetch: (uri, limit) async {
            calls.add(uri);
            return uri == AppUpdateService.latestUri
                ? jsonResponse(metadata)
                : ReleaseHttpResponse(200, proof);
          },
        );
        final result = await service.check(installed());
        expect(
          result.comparison,
          {
            '80': UpdateComparison.ahead,
            '81': UpdateComparison.current,
            '82': UpdateComparison.newer,
          }[build],
        );
        expect(result.release.buildNumber, int.parse(build));
        expect(
          calls.last.toString(),
          '$appRepositoryUrl/releases/download/v1.8.11/release-provenance.json',
        );
      }
    },
  );

  test(
    'missing build evidence is shown as unknown, never verified current',
    () async {
      final service = AppUpdateService(
        fetch: (uri, limit) async => jsonResponse(releaseFixture('1.8.11')),
      );
      expect(
        (await service.check(installed())).comparison,
        UpdateComparison.sameVersionBuildUnknown,
      );
      expect(
        (await service.check(installed('1.8.11', ''))).comparison,
        UpdateComparison.sameVersionBuildUnknown,
      );
    },
  );

  test(
    'wrong hashes, identities and oversized provenance cannot claim a newer build',
    () async {
      for (final fault in ['hash', 'version', 'size', 'build']) {
        final proof = utf8.encode(
          jsonEncode({
            'version': fault == 'version' ? '1.8.10' : '1.8.11',
            'build_number': fault == 'build' ? 'not-a-build' : '82',
          }),
        );
        final metadata = releaseFixture('1.8.11');
        (metadata['assets'] as List).add({
          'name': 'release-provenance.json',
          'state': 'uploaded',
          'size': fault == 'size'
              ? AppUpdateService.provenanceLimit + 1
              : proof.length,
          'digest': fault == 'hash'
              ? 'sha256:${'a' * 64}'
              : 'sha256:${sha256.convert(proof)}',
        });
        final service = AppUpdateService(
          fetch: (uri, limit) async => uri == AppUpdateService.latestUri
              ? jsonResponse(metadata)
              : ReleaseHttpResponse(200, proof),
        );
        await expectLater(
          service.check(installed()),
          throwsA(failure(UpdateFailure.invalidResponse)),
          reason: fault,
        );
      }
    },
  );

  test(
    'drafts, prereleases, foreign release identities and duplicate assets are refused',
    () async {
      for (final fault in [
        'draft',
        'prerelease',
        'tag',
        'url',
        'duplicate',
        'assets',
        'body',
      ]) {
        final value = releaseFixture();
        switch (fault) {
          case 'draft':
            value['draft'] = true;
          case 'prerelease':
            value['prerelease'] = true;
          case 'tag':
            value['tag_name'] = 'v1.8.12-rc.1';
          case 'url':
            value['html_url'] =
                'https://github.com/other/repo/releases/tag/v1.8.12';
          case 'duplicate':
            (value['assets'] as List).add((value['assets'] as List).first);
          case 'assets':
            value['assets'] = {};
          case 'body':
            value['body'] = {};
        }
        final service = AppUpdateService(
          fetch: (uri, limit) async => jsonResponse(value),
        );
        await expectLater(
          service.check(installed()),
          throwsA(failure(UpdateFailure.invalidResponse)),
          reason: fault,
        );
      }
    },
  );

  test(
    'malformed and oversized responses fail with a readable error state',
    () async {
      for (final response in [
        ReleaseHttpResponse(200, utf8.encode('{broken')),
        ReleaseHttpResponse(
          200,
          List.filled(AppUpdateService.metadataLimit + 1, 32),
        ),
        jsonResponse([]),
      ]) {
        final service = AppUpdateService(fetch: (uri, limit) async => response);
        await expectLater(
          service.check(installed()),
          throwsA(failure(UpdateFailure.invalidResponse)),
        );
      }
    },
  );

  test(
    'network, timeout, rate limit and server errors are distinguished',
    () async {
      for (final entry in {
        403: UpdateFailure.rateLimited,
        429: UpdateFailure.rateLimited,
        404: UpdateFailure.noRelease,
        503: UpdateFailure.server,
      }.entries) {
        final service = AppUpdateService(
          fetch: (uri, limit) async => ReleaseHttpResponse(entry.key, const []),
        );
        await expectLater(
          service.check(installed()),
          throwsA(failure(entry.value)),
        );
      }
      var service = AppUpdateService(
        fetch: (uri, limit) async => throw const SocketException('offline'),
      );
      await expectLater(
        service.check(installed()),
        throwsA(failure(UpdateFailure.network)),
      );
      service = AppUpdateService(
        fetch: (uri, limit) async => throw TimeoutException('fixture'),
      );
      await expectLater(
        service.check(installed()),
        throwsA(failure(UpdateFailure.timeout)),
      );
    },
  );

  test(
    'unavailable or unrelated packages are not offered as platform installers',
    () async {
      final value = releaseFixture();
      value['assets'] = [
        {
          'name': 'DontForget_iOS_unsigned_v1.8.12.ipa',
          'state': 'queued',
          'size': 100,
        },
        {'name': 'unrelated.exe', 'state': 'uploaded', 'size': 100},
      ];
      final service = AppUpdateService(
        fetch: (uri, limit) async => jsonResponse(value),
      );
      expect((await service.check(installed())).release.downloads, isEmpty);
    },
  );
}
