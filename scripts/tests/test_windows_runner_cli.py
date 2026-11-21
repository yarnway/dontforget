from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER_MAIN = ROOT / 'windows' / 'runner' / 'main.cpp'
FLUTTER_WINDOW_CPP = ROOT / 'windows' / 'runner' / 'flutter_window.cpp'
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


if __name__ == '__main__':
    unittest.main()
