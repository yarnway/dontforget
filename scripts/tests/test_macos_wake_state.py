import contextlib
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import read_macos_wake_state as wake


BOOT = b'FF981FC2-B426-4F29-8AC2-0E0BE38157D8\n'


def registry(**values):
    return plistlib.dumps([{'IORegistryEntryName': 'IOPMrootDomain', **values}])


def runner(root=None, schedule=b''):
    outputs = iter([BOOT, schedule, registry() if root is None else root, BOOT])
    return lambda command, **kwargs: subprocess.CompletedProcess(
        command, 0, next(outputs), b'')


class MacOSWakeStateTest(unittest.TestCase):
    def test_empty_schedule_and_missing_property_are_not_clearance(self):
        result = wake.collect(runner())
        self.assertEqual(result['collectionStatus'], 'COLLECTED')
        self.assertTrue(result['scheduledEvents']['emptyOutput'])
        self.assertEqual(result['relativeWakeSoftwareProperty'],
                         {'propertyPublished': False, 'seconds': None})
        self.assertEqual(result['relativeWakeVerdict'], 'UNCONFIRMED')
        self.assertFalse(result['hardwareReadbackAvailable'])

    def test_software_zero_and_nonzero_remain_distinct_from_hardware(self):
        for seconds in (0, 180):
            with self.subTest(seconds=seconds):
                result = wake.collect(runner(registry(WakeRelativeToSleep=seconds)))
                self.assertEqual(result['relativeWakeSoftwareProperty']['seconds'], seconds)
                self.assertEqual(result['relativeWakeVerdict'], 'UNCONFIRMED')

    def test_invalid_registry_and_invalid_relative_values_fail_closed(self):
        for raw in (b'', b'garbage', b'<?xml version="1.0"?><plist><dict>',
                    plistlib.dumps([]), plistlib.dumps([{}, {}]),
                    plistlib.dumps([{'IORegistryEntryName': 'other'}]),
                    registry(WakeRelativeToSleep=False),
                    registry(WakeRelativeToSleep='0'),
                    registry(WakeRelativeToSleep=-1),
                    registry(WakeRelativeToSleep=2**32),
                    registry(SleepDisabled='false')):
            with self.subTest(raw=raw):
                result = wake.collect(runner(raw))
                self.assertEqual(result['collectionStatus'], 'INCOMPLETE')
                self.assertEqual(result['relativeWakeVerdict'], 'UNCONFIRMED')

    def test_schedule_is_preserved_without_guessing_event_count(self):
        raw = b"Scheduled power events:\n [0] wake by 'another application'\n"
        result = wake.collect(runner(schedule=raw))
        self.assertFalse(result['scheduledEvents']['emptyOutput'])
        self.assertEqual(result['scheduledEvents']['raw'], raw.decode())

    def test_failed_command_with_empty_stdout_is_not_empty_schedule(self):
        def run(command, **kwargs):
            if command[0].endswith('sysctl'):
                return subprocess.CompletedProcess(command, 0, BOOT, b'')
            return subprocess.CompletedProcess(command, 1, b'', b'permission denied')
        result = wake.collect(run)
        self.assertEqual(result['collectionStatus'], 'INCOMPLETE')
        self.assertNotIn('scheduledEvents', result)

    def test_timeout_warning_and_missing_binary_fail_closed(self):
        for failure in (subprocess.TimeoutExpired('ioreg', 15), FileNotFoundError('ioreg')):
            with self.subTest(failure=failure):
                def run(*args, **kwargs):
                    raise failure
                self.assertEqual(wake.collect(run)['collectionStatus'], 'INCOMPLETE')
        def warned(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, BOOT, b'warning')
        self.assertEqual(wake.collect(warned)['collectionStatus'], 'INCOMPLETE')

    def test_boot_change_invalidates_snapshot(self):
        values = iter([BOOT, b'', registry(), b'00000000-0000-0000-0000-000000000000'])
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, next(values), b'')
        self.assertEqual(wake.collect(run)['collectionStatus'], 'INCOMPLETE')

    def test_existing_file_and_symlink_are_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / 'original.json'
            original.write_text('keep')
            link = Path(directory) / 'link.json'
            link.symlink_to(original)
            for output in (original, link):
                with patch.object(wake.platform, 'system', return_value='Darwin'), \
                        patch.object(wake, 'collect') as collect, \
                        contextlib.redirect_stderr(io.StringIO()), \
                        self.assertRaises(SystemExit):
                    wake.main(['--output', str(output)])
                collect.assert_not_called()
            self.assertEqual(original.read_text(), 'keep')

    def test_partial_result_is_saved_privately_with_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'evidence.json'
            with patch.object(wake.platform, 'system', return_value='Darwin'), \
                    patch.object(wake, 'collect', return_value={
                        'collectionStatus': 'INCOMPLETE', 'error': 'timeout'}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(wake.main(['--output', str(output)]), 2)
            self.assertIn('INCOMPLETE', output.read_text())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
