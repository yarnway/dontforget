import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_artifacts import package, version
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


if __name__ == '__main__':
    unittest.main()
