import pathlib
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Darwin', 'real Darwin storage-lock test')
class DSTStorageNativeTest(unittest.TestCase):
    def test_real_locks_and_read_only_failure_boundaries(self):
        scripts = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix='dst-lock-build-') as directory:
            executable = pathlib.Path(directory) / 'storage-test'
            build = subprocess.run([
                'swiftc', '-swift-version', '5', '-parse-as-library',
                str(scripts / 'macos_dst_storage.swift'),
                str(scripts / 'tests/native_dst_storage_test.swift'),
                '-o', str(executable),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(executable)], capture_output=True,
                                 text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn('PASS: unlocked, competing owner', run.stdout)


if __name__ == '__main__':
    unittest.main()
