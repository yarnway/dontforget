from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER_MAIN = ROOT / 'windows' / 'runner' / 'main.cpp'
FLUTTER_WINDOW_H = ROOT / 'windows' / 'runner' / 'flutter_window.h'
FLUTTER_WINDOW_CPP = ROOT / 'windows' / 'runner' / 'flutter_window.cpp'
INSTALLER_ISS = ROOT / 'windows_installer' / 'installer.iss'
DART_MAIN = ROOT / 'lib' / 'main.dart'


class WindowsRunnerCliTests(unittest.TestCase):
    def test_runner_uses_exact_cli_argv_matching_not_substring(self):
        source = RUNNER_MAIN.read_text(encoding='utf-8')
        self.assertIn('CommandLineToArgvW', source)
        self.assertIn('wcscmp', source)
        self.assertNotIn('wcsstr(command_line', source)

    def test_runner_preserves_redirected_std_handles_and_guards_resync(self):
        source = RUNNER_MAIN.read_text(encoding='utf-8')
        self.assertIn('HasValidStdHandle', source)
        self.assertIn('IsRedirectedFileOrPipe', source)
        self.assertIn('GetFileType', source)
        self.assertIn('if (attached_console_output && !any_redirected_output)', source)
        self.assertIn('FlutterDesktopResyncOutputStreams()', source)

    def test_runner_hides_window_on_cli_invocation(self):
        main_source = RUNNER_MAIN.read_text(encoding='utf-8')
        window_source = FLUTTER_WINDOW_CPP.read_text(encoding='utf-8')
        self.assertIn('FlutterWindow window(project, !is_cli);', main_source)
        self.assertIn('if (show_on_create_)', window_source)

    def test_dart_cli_flushes_output_and_rejects_empty_add(self):
        source = DART_MAIN.read_text(encoding='utf-8')
        self.assertIn('await stdout.flush();', source)
        self.assertIn('await stderr.flush();', source)
        self.assertIn('return 2;', source)

    def test_runner_supports_tray_safe_graceful_upgrade_exit_event(self):
        header = FLUTTER_WINDOW_H.read_text(encoding='utf-8')
        cpp = FLUTTER_WINDOW_CPP.read_text(encoding='utf-8')
        self.assertIn('kUpgradeExitMessage', header)
        self.assertIn('upgrade_exit_event_', header)
        self.assertIn('upgrade_exit_wait_', header)
        self.assertIn(r'L"Local\\DontForget.GracefulUpgradeExit"', cpp)
        self.assertIn('::ResetEvent(upgrade_exit_event_);', cpp)
        self.assertIn('::RegisterWaitForSingleObject(', cpp)
        self.assertIn('::PostMessageW(hwnd, kUpgradeExitMessage, 0, 0);', cpp)
        self.assertIn('::UnregisterWaitEx(upgrade_exit_wait_, INVALID_HANDLE_VALUE);', cpp)
        self.assertIn('protocol_channel_->InvokeMethod("onUpgradeExit", nullptr);', cpp)

    def test_installer_signals_graceful_exit_without_force_kill(self):
        iss = INSTALLER_ISS.read_text(encoding='utf-8')
        self.assertIn('PrepareToInstall(var NeedsRestart: Boolean): String;', iss)
        self.assertIn("Local\\DontForget.GracefulUpgradeExit", iss)
        self.assertIn("Local\\DontForget.SingleInstance", iss)
        self.assertIn("'/NOCLOSEAPPLICATIONS'", iss)
        for forbidden in ('TerminateProcess', 'taskkill', 'Stop-Process', 'WM_DESTROY'):
            self.assertNotIn(forbidden, iss)


if __name__ == '__main__':
    unittest.main()
