import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import warnings

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android_apk_variants import ABIS, libraries, verify_pair
from build_android_variants import build
from package_artifacts import package
from verify_artifacts import verify
from android_release_signing import verify_android_signatures


def apk(path, abis, plugin=True, wrong_machine=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, 'w') as archive:
        for abi in abis:
            header = bytearray(64)
            header[:6] = b'\x7fELF' + bytes([ABIS[abi][0], 1])
            struct.pack_into('<H', header, 18, 0 if wrong_machine else ABIS[abi][1])
            for name in ['libapp.so', 'libflutter.so'] + (['libsqlite3.so'] if plugin else []):
                archive.writestr(f'lib/{abi}/{name}', header)


class AndroidVariantsTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'pubspec.yaml').write_text('version: 1.8.3+72\n')
        self.output = self.root / 'build/app/outputs/flutter-apk'
        self.full = self.output / 'app-release.apk'
        self.small = self.output / 'app-arm64-v8a-release.apk'
        self.aab = self.root / 'build/app/outputs/bundle/release/app-release.aab'
        apk(self.full, ABIS)
        apk(self.small, ['arm64-v8a'])
        self.aab.parent.mkdir(parents=True)
        self.aab.write_bytes(b'bundle fixture')

    def test_real_abi_headers_and_plugin_inventory_are_required(self):
        self.assertEqual(set(verify_pair(self.full, self.small)['universal']), set(ABIS))
        for abis, plugin, wrong in [(ABIS, True, False), (['arm64-v8a'], False, False),
                                     (['arm64-v8a'], True, True), (['x86_64'], True, False)]:
            with self.subTest(abis=abis, plugin=plugin, wrong=wrong):
                apk(self.small, abis, plugin, wrong)
                with self.assertRaises(ValueError): verify_pair(self.full, self.small)

    def test_duplicate_library_and_missing_flutter_are_rejected(self):
        with zipfile.ZipFile(self.small, 'a') as archive:
            archive.writestr('lib/arm64-v8a/libextra.so', b'not ELF')
        with self.assertRaises(ValueError): libraries(self.small, ['arm64-v8a'])
        apk(self.small, ['arm64-v8a'])
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.small, 'a') as archive:
                archive.writestr('lib/arm64-v8a/libapp.so', b'duplicate')
        with self.assertRaises(ValueError): libraries(self.small, ['arm64-v8a'])
        with zipfile.ZipFile(self.small, 'w') as archive:
            archive.writestr('assets/only', b'fixture')
        with self.assertRaises(ValueError): libraries(self.small, ['arm64-v8a'])

    def test_three_android_files_are_required_by_platform_publisher(self):
        import test_platform_release as fixtures
        fixture = fixtures.ReleaseFilesTest()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        files = fixture.files
        for path in list(files.iterdir()):
            target = path.with_name(path.name.replace('1.7.0', '1.8.3'))
            if path.suffix == '.json':
                content = path.read_text().replace('1.7.0', '1.8.3').replace('"59"', '"72"')
                path.write_text(content)
            if target != path: path.rename(target)
        for path in list(files.glob('android-*')): path.unlink()
        with patch.dict(os.environ, {'DONTFORGET_REQUIRE_RELEASE_SIGNING': '1', 'DONTFORGET_ANDROID_CERT_SHA256': fixtures.CERT}), \
                patch('package_artifacts.verify_android_signatures', return_value=fixtures.CERT):
            manifest = package(self.root, 'android', fixtures.REV)
        import shutil
        for path in (self.root / 'dist').iterdir(): shutil.copy2(path, files / path.name)
        # Other platform checksums include versioned filenames.
        for platform in ('windows', 'linux'):
            path = files / (platform + '-SHA256SUMS.txt')
            path.write_text(path.read_text().replace('1.7.0', '1.8.3'))
        self.assertEqual(len(fixtures.validate_files(files, fixtures.REV, '1.8.3', '72', fixtures.CERT)), 3)
        self.assertEqual(len(list(files.iterdir())), 15)
        manifest_path = files / 'android-manifest.json'
        manifest['artifacts'] = manifest['artifacts'][:2]
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError): fixtures.validate_files(files, fixtures.REV, '1.8.3', '72', fixtures.CERT)

    def test_new_version_requires_three_packages_and_rechecks_inventory(self):
        with patch.dict(os.environ, {'DONTFORGET_REQUIRE_RELEASE_SIGNING': '0'}):
            manifest = package(self.root, 'android', 'a' * 40)
        self.assertEqual(len(manifest['artifacts']), 3)
        self.assertEqual(verify(self.root / 'dist', '1.8.3', '72', 'a' * 40, 'android'), 3)
        path = self.root / 'dist/android-manifest.json'
        manifest['android_variants']['arm64']['arm64-v8a'].append('libmissing.so')
        path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError): verify(self.root / 'dist', '1.8.3', '72', 'a' * 40, 'android')

    def test_missing_or_wrong_small_package_never_publishes_partial_set(self):
        self.small.unlink()
        with self.assertRaises(FileNotFoundError): package(self.root, 'android', 'a' * 40)
        self.assertEqual(list((self.root / 'dist').iterdir()), [])
        apk(self.small, ABIS)
        with self.assertRaises(ValueError): package(self.root, 'android', 'a' * 40)
        self.assertEqual(list((self.root / 'dist').iterdir()), [])

    def run_build(self, fail=None, metadata=('com.yarnway.dontforget', '72', '1.8.3', '24')):
        calls = []
        def flutter(args, **kwargs):
            calls.append(args)
            stage = len(calls)
            if stage == fail: raise subprocess.CalledProcessError(1, args)
            if stage < 3: apk(self.full, ABIS if stage == 1 else ['arm64-v8a'])
        with patch('build_android_variants.shutil.which', return_value='flutter'), \
                patch('build_android_variants.subprocess.run', side_effect=flutter), \
                patch('build_android_variants.metadata', return_value=metadata):
            build(self.root, disable_kotlin_incremental=True)
        return calls

    def test_build_preserves_universal_across_compact_and_bundle_builds(self):
        calls = self.run_build()
        verify_pair(self.full, self.small)
        self.assertEqual([args[3] for args in calls], ['apk', 'apk', 'appbundle'])
        self.assertTrue(all('--no-pub' in args and '--android-project-arg=kotlin.incremental=false' in args for args in calls))
        self.assertIn('--target-platform=android-arm64', calls[1])
        self.assertNotIn('--target-platform=android-arm64', calls[2])

    def test_failed_build_restores_universal_and_removes_stale_compact(self):
        for failure in [2, 3]:
            with self.subTest(failure=failure), self.assertRaises(subprocess.CalledProcessError): self.run_build(fail=failure)
            self.assertEqual(set(libraries(self.full, ABIS)), set(ABIS))
            self.assertFalse(self.small.exists())

    def test_metadata_drift_stops_before_bundle(self):
        with self.assertRaises(ValueError): self.run_build(metadata=('other.app', '72', '1.8.3', '24'))
        self.assertFalse(self.small.exists())
        libraries(self.full, ABIS)

    def test_additional_apk_signature_must_match_pinned_identity(self):
        for cert, code in [('a' * 64, 0), ('b' * 64, 0), ('a' * 64, 1)]:
            outputs = [subprocess.CompletedProcess([], 0, 'Signer #1 certificate SHA-256 digest: ' + 'a' * 64, ''),
                       subprocess.CompletedProcess([], code, 'Signer #1 certificate SHA-256 digest: ' + cert, ''),
                       subprocess.CompletedProcess([], 4, 'jar verified', ''),
                       subprocess.CompletedProcess([], 0, 'SHA256: ' + 'a' * 64, '')]
            with self.subTest(cert=cert, code=code), \
                    patch('android_release_signing.Path.glob', return_value=[Path('sdk/build-tools/36.0.0/apksigner')]), \
                    patch('android_release_signing.tool', return_value='java-tool'), \
                    patch('android_release_signing.subprocess.run', side_effect=outputs) as run:
                if cert == 'a' * 64 and not code:
                    verify_android_signatures(self.full, self.aab, 'a' * 64, {'ANDROID_HOME': 'sdk'}, additional_apks=[self.small])
                    self.assertEqual(run.call_count, 4)
                    self.assertIn(str(self.small), run.call_args_list[1].args[0])
                else:
                    with self.assertRaises(ValueError):
                        verify_android_signatures(self.full, self.aab, 'a' * 64, {'ANDROID_HOME': 'sdk'}, additional_apks=[self.small])
