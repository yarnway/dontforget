import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('startup_measurement', Path(__file__).resolve().parents[1] / 'read_macos_startup_measurement.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StartupMeasurementTest(unittest.TestCase):
    def sample(self):
        return {'dart_entry_utc': '2026-10-22T06:00:00+00:00',
                'milestones_us': {'storage_ready': 100, 'notifications_ready': 900},
                'elapsed_to_outcome_us': 1000, 'outcome': 'timeout'}

    def test_process_join_keeps_failure_and_excludes_reader_latency(self):
        entry = 1792648800000000
        joined = module.merge(self.sample(), entry - 500)
        self.assertEqual(joined['process_to_milestones_us']['notifications_ready'], 1400)
        self.assertEqual(joined['process_to_outcome_us'], 1500)
        self.assertEqual(joined['outcome'], 'timeout')
        self.assertEqual(self.sample()['milestones_us']['notifications_ready'], 900)

    def test_clock_mismatch_and_unzoned_report_fail(self):
        for start in [1792648800000001, 1792648800000000 - 181000000]:
            with self.assertRaises(ValueError): module.merge(self.sample(), start)
        data = self.sample()
        data['dart_entry_utc'] = '2026-10-22T06:00:00'
        with self.assertRaises(ValueError): module.merge(data, 1792648800000000)

    def test_invalid_milestone_fails(self):
        for value in [-1, True, '100']:
            data = self.sample()
            data['milestones_us']['storage_ready'] = value
            with self.assertRaises(ValueError): module.merge(data, 1792648800000000)
