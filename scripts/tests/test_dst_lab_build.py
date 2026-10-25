import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == 'posix', 'macOS controller CLI needs a POSIX shell')
class DSTLabBuildTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.acceptance = self.root / 'acceptance'
        (self.acceptance / 'dst-stage30-materials').mkdir(parents=True)
        (self.acceptance / 'dst-stage30-share').mkdir()
        self.output = self.root / 'Lab.app'
        self.script = Path(__file__).resolve().parents[1] / 'build_macos_dst_lab.sh'

    def run_cli(self, *args, env=None):
        return subprocess.run(['bash', str(self.script), *map(str, args)],
                              capture_output=True, text=True, timeout=15, env=env)

    def arguments(self, output=None):
        return ['--acceptance-root', self.acceptance, '--output', output or self.output]

    def test_help_does_not_build(self):
        result = self.run_cli('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Building does not start', result.stdout)
        self.assertFalse(self.output.exists())

    def test_invalid_arguments_do_not_create_output(self):
        for args in ([], ['--output'], ['--acceptance-root', '--output'],
                     ['--unknown'], ['--acceptance-root', self.acceptance,
                                     '--output', 'relative.app']):
            with self.subTest(args=args):
                self.assertEqual(self.run_cli(*args).returncode, 64)
                self.assertFalse(self.output.exists())
                self.assertFalse(list(self.root.glob('.dst-lab-build.*')))

    def test_existing_bundle_or_symlink_is_preserved(self):
        self.output.mkdir()
        marker = self.output / 'preserve.txt'
        marker.write_text('existing app data')
        link = self.root / 'Linked.app'
        link.symlink_to(self.output, target_is_directory=True)
        for output in (self.output, link):
            with self.subTest(output=output):
                result = self.run_cli(*self.arguments(output))
                self.assertEqual(result.returncode, 64)
                self.assertIn('Refusing to overwrite', result.stderr)
                self.assertEqual(marker.read_text(), 'existing app data')
                self.assertTrue(link.is_symlink())

    def test_compiler_failure_removes_only_its_staging_directory(self):
        fake_bin = self.root / 'bin'
        fake_bin.mkdir()
        for name, script in {
            'uname': '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; *) exit 1;; esac\n',
            'swiftc': '#!/bin/sh\nexit 42\n',
        }.items():
            target = fake_bin / name
            target.write_text(script)
            target.chmod(0o755)
        marker = self.acceptance / 'preserve.txt'
        marker.write_text('guest state')
        env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'])
        result = self.run_cli(*self.arguments(), env=env)
        self.assertEqual(result.returncode, 42)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob('.dst-lab-build.*')))
        self.assertEqual(marker.read_text(), 'guest state')


if __name__ == '__main__':
    unittest.main()
