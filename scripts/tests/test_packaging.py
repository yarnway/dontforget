import json
from pathlib import Path
import sys
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_artifacts import macos_architectures, package, version
from verify_artifacts import verify, verify_tag


class PackagingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'pubspec.yaml').write_text('version: 1.5.1+2\n')
        self.revision = 'a' * 40

    def write(self, relative, content=b'fixture'):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def android(self):
        self.write('build/app/outputs/flutter-apk/app-release.apk')
        self.write('build/app/outputs/bundle/release/app-release.aab')
        return package(self.root, 'android', self.revision)

    def test_release_tags_match_version_and_candidate_build(self):
        verify_tag('v1.7.0', '1.7.0', '14')
        verify_tag('v1.7.0-rc.14', '1.7.0', '14')
        for tag in ['v1.7.1', 'v1.7.0-rc.13', 'v1.7.0-rc.014', 'v1.7.0+14', 'v1.7.0-rc.14-extra']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                verify_tag(tag, '1.7.0', '14')

    def test_version_requires_build_number(self):
        self.assertEqual(version(self.root), ('1.5.1', '2'))
        (self.root / 'pubspec.yaml').write_text('version: 1.5.1\n')
        with self.assertRaises(ValueError):
            version(self.root)

    def test_android_candidates_mark_test_signature_and_verify(self):
        manifest = self.android()
        self.assertEqual(manifest['signing'], 'test-key')
        self.assertEqual(manifest['runtime_acceptance'], 'NOT_PERFORMED')
        self.assertEqual(verify(self.root / 'dist', '1.5.1', '2', self.revision, 'android'), 2)

    def test_incomplete_android_build_produces_no_deliverables(self):
        self.write('build/app/outputs/flutter-apk/app-release.apk')
        with self.assertRaises(FileNotFoundError):
            package(self.root, 'android', self.revision)
        self.assertEqual(list((self.root / 'dist').iterdir()), [])

    def test_modified_archive_is_rejected(self):
        manifest = self.android()
        (self.root / 'dist' / manifest['artifacts'][0]['file']).write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            verify(self.root / 'dist', '1.5.1', '2', self.revision, 'android')

    def test_wrong_source_or_version_is_rejected(self):
        self.android()
        for release, revision in [('1.6.0', self.revision), ('1.5.1', 'b' * 40)]:
            with self.assertRaises(ValueError):
                verify(self.root / 'dist', release, '2', revision, 'android')

    def test_missing_platform_rejects_release(self):
        self.android()
        with self.assertRaises(FileNotFoundError):
            verify(self.root / 'dist', '1.5.1', '2', self.revision)

    def test_archive_path_escape_is_rejected(self):
        self.android()
        path = self.root / 'dist/android-manifest.json'
        manifest = json.loads(path.read_text())
        manifest['artifacts'][0]['file'] = '../outside.apk'
        path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            verify(self.root / 'dist', '1.5.1', '2', self.revision, 'android')

    def linux_fixture(self):
        self.write('build/linux/x64/release/bundle/dont_forget')
        self.write('build/linux/x64/release/bundle/lib/libflutter_linux_gtk.so')
        self.write('build/linux/x64/release/bundle/data/flutter_assets/AssetManifest.bin')

    def test_linux_bundle_layout(self):
        self.linux_fixture()
        manifest = package(self.root, 'linux', self.revision)
        with tarfile.open(self.root / 'dist' / manifest['artifacts'][0]['file']) as archive:
            self.assertIn('dont_forget', archive.getnames())
            self.assertIn('lib/libflutter_linux_gtk.so', archive.getnames())
        self.assertEqual(verify(self.root / 'dist', '1.5.1', '2', self.revision, 'linux'), 1)

    def test_private_runtime_files_stop_packaging_without_deletion(self):
        self.linux_fixture()
        private = self.write('build/linux/x64/release/bundle/data/ha_snapshot.json')
        with self.assertRaises(ValueError):
            package(self.root, 'linux', self.revision)
        self.assertTrue(private.exists())
        self.assertEqual(list((self.root / 'dist').iterdir()), [])

    def test_windows_requires_installer_and_engine(self):
        self.write('build/windows/x64/runner/Release/dont_forget.exe')
        self.write('build/windows/x64/runner/Release/flutter_windows.dll')
        self.write('build/windows/x64/runner/Release/data/flutter_assets/AssetManifest.bin')
        with self.assertRaises(FileNotFoundError):
            package(self.root, 'windows', self.revision)
        self.write('dist/DontForget_Setup_v1.5.1.exe')
        manifest = package(self.root, 'windows', self.revision)
        with zipfile.ZipFile(self.root / 'dist' / manifest['artifacts'][1]['file']) as archive:
            self.assertIn('dont_forget.exe', archive.namelist())
        self.assertEqual(verify(self.root / 'dist', '1.5.1', '2', self.revision, 'windows'), 2)

    def macos_fixture(self):
        app = 'build/macos/Build/Products/Release/dont_forget.app'
        self.write(f'{app}/Contents/MacOS/dont_forget', b'\xca\xfe\xba\xbe')
        self.write(f'{app}/Contents/Frameworks/Plugin.framework/Versions/A/Plugin',
                   b'\xcf\xfa\xed\xfe')
        self.write(f'{app}/Contents/Resources/asset', b'ordinary asset')
        return self.root / app

    @staticmethod
    def fake_ditto(args, **kwargs):
        # Archive contents are verified separately; these tests exercise the gate.
        Path(args[-1]).write_bytes(b'archive fixture')

    def test_macos_checks_main_and_framework_before_publishing(self):
        app = self.macos_fixture()
        with patch('package_artifacts.subprocess.check_output',
                   return_value='x86_64 arm64\n') as lipo, \
                patch('package_artifacts.subprocess.run', side_effect=self.fake_ditto):
            manifest = package(self.root, 'macos', self.revision)
        self.assertEqual(lipo.call_count, 2)
        self.assertEqual({x['file'] for x in manifest['native_architectures']}, {
            'Contents/MacOS/dont_forget',
            'Contents/Frameworks/Plugin.framework/Versions/A/Plugin',
        })
        self.assertTrue(all(x['architectures'] == ['arm64', 'x86_64']
                            for x in manifest['native_architectures']))
        self.assertTrue(all(Path(call.args[0][-1]).is_relative_to(app.resolve())
                            for call in lipo.call_args_list))
        self.assertEqual(verify(self.root / 'dist', '1.5.1', '2', self.revision, 'macos'), 1)

    def test_macos_thin_plugin_stops_before_archive(self):
        self.macos_fixture()
        def architectures(args, **kwargs):
            return 'x86_64\n' if args[-1].endswith('/Plugin') else 'x86_64 arm64\n'
        with patch('package_artifacts.subprocess.check_output', side_effect=architectures), \
                patch('package_artifacts.subprocess.run') as ditto, \
                self.assertRaisesRegex(ValueError, 'Plugin'):
            package(self.root, 'macos', self.revision)
        ditto.assert_not_called()
        self.assertEqual(list((self.root / 'dist').iterdir()), [])

    def test_macos_unreadable_binary_stops_before_archive(self):
        self.macos_fixture()
        with patch('package_artifacts.subprocess.check_output',
                   side_effect=subprocess.CalledProcessError(1, ['lipo'])), \
                patch('package_artifacts.subprocess.run') as ditto, \
                self.assertRaises(subprocess.CalledProcessError):
            package(self.root, 'macos', self.revision)
        ditto.assert_not_called()
        self.assertEqual(list((self.root / 'dist').iterdir()), [])

    def test_macos_missing_macho_executable_rejects(self):
        app = self.macos_fixture()
        (app / 'Contents/MacOS/dont_forget').write_bytes(b'not a binary')
        with patch('package_artifacts.subprocess.check_output', return_value='arm64 x86_64'), \
                self.assertRaisesRegex(ValueError, 'executable'):
            macos_architectures(app)

    def test_macos_framework_alias_is_not_checked_twice(self):
        app = self.macos_fixture()
        alias = app / 'Contents/Frameworks/Plugin.framework/Plugin'
        try:
            alias.symlink_to('Versions/A/Plugin')
        except OSError:
            self.skipTest('Platform does not allow unprivileged symlinks')
        with patch('package_artifacts.subprocess.check_output', return_value='arm64 x86_64') as lipo:
            self.assertEqual(len(macos_architectures(app)), 2)
        self.assertEqual(lipo.call_count, 2)

    def test_macos_release_verification_rejects_incomplete_architecture_evidence(self):
        self.macos_fixture()
        with patch('package_artifacts.subprocess.check_output', return_value='arm64 x86_64'), \
                patch('package_artifacts.subprocess.run', side_effect=self.fake_ditto):
            manifest = package(self.root, 'macos', self.revision)
        path = self.root / 'dist/macos-manifest.json'
        valid = manifest['native_architectures']
        for evidence in [[], [{'file': 'Contents/MacOS/dont_forget', 'architectures': ['x86_64']}],
                         valid + [valid[0]],
                         valid + [{'file': 'Contents/../outside', 'architectures': ['arm64', 'x86_64']}]]:
            with self.subTest(evidence=evidence), self.assertRaises(ValueError):
                manifest['native_architectures'] = evidence
                path.write_text(json.dumps(manifest))
                verify(self.root / 'dist', '1.5.1', '2', self.revision, 'macos')


if __name__ == '__main__':
    unittest.main()
