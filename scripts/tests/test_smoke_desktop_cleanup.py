import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import smoke_desktop


def windows_lock(code=32):
    error = PermissionError('isolated locked directory')
    error.winerror = code
    return error


class TemporaryWorkspaceTests(unittest.TestCase):
    def run_workspace(self, platform, failures, startup_failure=None):
        temporary = Mock(name='owned-temporary-directory')
        temporary.name = 'isolated-workspace'
        temporary.cleanup.side_effect = failures
        result = {'result': 'FAIL', 'startup_result': 'PASS'}
        with patch.object(smoke_desktop.tempfile, 'TemporaryDirectory',
                          return_value=temporary), \
                patch.object(smoke_desktop.time, 'sleep') as sleep:
            error = None
            try:
                with smoke_desktop.temporary_workspace(platform, result) as name:
                    self.assertEqual(name, temporary.name)
                    if startup_failure:
                        result['startup_result'] = 'FAIL'
                        raise startup_failure
            except Exception as caught:
                error = caught
        return result, temporary.cleanup.call_count, sleep.call_args_list, error

    def test_windows_releases_delayed_owned_handle(self):
        result, attempts, waits, error = self.run_workspace(
            'windows', [windows_lock(), windows_lock(5), None])
        self.assertIsNone(error)
        self.assertEqual(attempts, 3)
        self.assertEqual([call.args[0] for call in waits], [0.25, 0.5])
        self.assertEqual(result['cleanup_result'], 'PASS')
        # Cleanup alone cannot upgrade the caller's overall startup result.
        self.assertEqual(result['result'], 'FAIL')

    def test_windows_persistent_lock_fails_with_bounded_retries(self):
        failure = windows_lock()
        result, attempts, waits, error = self.run_workspace('windows', failure)
        self.assertIs(error, failure)
        self.assertEqual(attempts, 5)
        self.assertEqual(sum(call.args[0] for call in waits), 3.75)
        self.assertEqual(result['startup_result'], 'PASS')
        self.assertEqual(result['cleanup_result'], 'FAIL')
        self.assertEqual(result['result'], 'FAIL')

    def test_unrelated_errors_and_other_platforms_are_not_retried(self):
        for platform, failure in [('windows', OSError('disk error')),
                                  ('linux', windows_lock()),
                                  ('macos', windows_lock())]:
            with self.subTest(platform=platform):
                result, attempts, waits, error = self.run_workspace(platform, failure)
                self.assertIs(error, failure)
                self.assertEqual(attempts, 1)
                self.assertEqual(waits, [])
                self.assertEqual(result['cleanup_result'], 'FAIL')

    def test_cleanup_does_not_hide_startup_failure(self):
        startup_failure = RuntimeError('application exited early')
        result, attempts, _, error = self.run_workspace(
            'windows', [windows_lock(), None], startup_failure)
        self.assertIs(error, startup_failure)
        self.assertEqual(attempts, 2)
        self.assertEqual(result['startup_result'], 'FAIL')
        self.assertEqual(result['cleanup_result'], 'PASS')
        self.assertEqual(result['result'], 'FAIL')


if __name__ == '__main__':
    unittest.main()
