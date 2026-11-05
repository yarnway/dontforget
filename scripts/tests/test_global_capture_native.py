import os
import pathlib
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Windows', 'real Windows hotkey registration test')
class GlobalCaptureNativeTest(unittest.TestCase):
    def test_native_registration_and_session_lifecycle(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        vswhere = pathlib.Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
        self.assertTrue(vswhere.is_file(), 'Windows native acceptance requires Visual Studio')
        lookup = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
                                 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
                                 '-property', 'installationPath'], capture_output=True,
                                text=True, timeout=20, check=True)
        devcmd = pathlib.Path(lookup.stdout.strip()) / 'Common7/Tools/VsDevCmd.bat'
        self.assertTrue(devcmd.is_file())
        with tempfile.TemporaryDirectory(prefix='dontforget-hotkey-') as directory:
            work = pathlib.Path(directory)
            executable = work / 'native-capture-test.exe'
            command = work / 'compile.cmd'
            command.write_text(
                '@echo off\n'
                f'call "{devcmd}" -arch=x64 >nul\n'
                'if errorlevel 1 exit /b %errorlevel%\n'
                f'cl /nologo /EHsc /std:c++17 /W4 /WX /DUNICODE /D_UNICODE '
                f'/I"{root / "windows/runner"}" '
                f'"{root / "scripts/tests/native_global_capture_test.cpp"}" '
                f'/Fe:"{executable}" /Fo:"{work / "test.obj"}" user32.lib\n',
                encoding='utf-8')
            build = subprocess.run(['cmd.exe', '/d', '/c', str(command)],
                                   cwd=work, capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True,
                                 text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('PASS: OS registration, conflict, disable, stale IDs', run.stdout)


if __name__ == '__main__':
    unittest.main()
