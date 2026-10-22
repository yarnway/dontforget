import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'frame_diagnostics', Path(__file__).resolve().parents[1] / 'analyze_frame_diagnostics.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FrameDiagnosticsTest(unittest.TestCase):
    def test_pairs_are_thread_local_and_intervals_are_clipped(self):
        frame = {'from_us': 100, 'to_us': 130, 'events': [
            {'ph': 'B', 'name': 'Layout', 'pid': 1, 'tid': 1, 'ts': 95},
            {'ph': 'B', 'name': 'Other', 'pid': 1, 'tid': 2, 'ts': 105},
            {'ph': 'E', 'pid': 1, 'tid': 1, 'ts': 115},
            {'ph': 'E', 'pid': 1, 'tid': 2, 'ts': 125},
            {'ph': 'X', 'name': 'Scavenger', 'pid': 1, 'tid': 3, 'ts': 120, 'dur': 20},
        ]}
        result = module.summarize_frame(frame)
        self.assertEqual(result['incomplete_boundary_pairs'], 0)
        self.assertEqual({x['name']: x['inclusive_us'] for x in result['top_inclusive_spans']},
                         {'Layout': 15, 'Other': 20, 'Scavenger': 10})
        self.assertEqual(result['gc_name_matches'][0]['name'], 'Scavenger')

    def test_unmatched_boundary_events_are_reported_not_invented(self):
        frame = {'from_us': 0, 'to_us': 10, 'events': [
            {'ph': 'E', 'pid': 1, 'tid': 1, 'ts': 1},
            {'ph': 'B', 'name': 'Layout', 'pid': 1, 'tid': 1, 'ts': 2},
        ]}
        result = module.summarize_frame(frame)
        self.assertEqual(result['incomplete_boundary_pairs'], 2)
        self.assertEqual(result['top_inclusive_spans'], [])

    def test_invalid_durations_fail_closed(self):
        with self.assertRaises(ValueError):
            module.summarize_frame({'from_us': 0, 'to_us': 10,
                                    'events': [{'ph': 'X', 'ts': 1, 'dur': -1}]})

    def test_baseline_and_nonforeground_reports_are_rejected(self):
        with self.assertRaises(ValueError):
            module.analyze({'phase': 'complete', 'errors': []})
        with self.assertRaises(ValueError):
            module.analyze({'phase': 'complete', 'errors': [],
                            'focused_768_diagnostics': True,
                            'timing_comparable_to_baseline': False,
                            'segments': [{'uninterrupted_foreground': False}]})

    def test_complete_fixed_viewport_report_keeps_scope_and_five_frames(self):
        report = {
            'phase': 'complete', 'errors': [], 'source_revision': 'synthetic',
            'focused_768_diagnostics': True, 'timing_comparable_to_baseline': False,
            'segments': [{'uninterrupted_foreground': True}],
            'results': [{'tasks': 10000, 'task_rows_sha256': 'synthetic',
                         'views': [{'requested_width': 768,
                                    'sample_viewports': [{'width': 768, 'height': 792}] * 6,
                                    'diagnostic_frames': [{'from_us': 0, 'to_us': 10,
                                                           'events': [{'ph': 'X', 'name': 'Layout',
                                                                       'ts': 1, 'dur': 5}]}] * 5}]}],
        }
        result = module.analyze(report)
        self.assertEqual(len(result['frames']), 5)
        self.assertIn('not additive CPU shares', result['scope'])
        report['results'][0]['views'][0]['sample_viewports'][0]['height'] = 800
        with self.assertRaises(ValueError):
            module.analyze(report)
        report['results'][0]['views'][0]['sample_viewports'][0]['height'] = 792
        report['results'][0]['views'][0]['diagnostic_frames'][0]['events'] = []
        with self.assertRaises(ValueError):
            module.analyze(report)


if __name__ == '__main__':
    unittest.main()
