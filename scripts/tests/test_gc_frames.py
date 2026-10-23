import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'gc_frames', Path(__file__).resolve().parents[1] / 'analyze_gc_frames.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def report():
    frames = [{'install_start_us': i * 100, 'install_end_us': i * 100 + 50,
               'build_start_us': i * 100 + 10, 'build_finish_us': i * 100 + 40,
               'build_us': 30} for i in range(30)]
    events = [{'ph': 'X', 'cat': 'Dart', 'name': 'BUILD', 'pid': 1, 'tid': 2,
               'ts': f['build_start_us'], 'dur': 30} for f in frames]
    return {'phase': 'complete', 'errors': [], 'restart_required': False,
            'gc_observation': True, 'focused_768_diagnostics': False,
            'gc_observation_protocol': 'gc-only-deferred-30-v1',
            'timing_comparable_to_baseline': False, 'source_revision': 'synthetic',
            'segments': [{'uninterrupted_foreground': True}],
            'results': [{'tasks': 10000, 'task_rows_sha256': 'synthetic', 'views': [{
                'requested_width': 768,
                'sample_viewports': [{'width': 768, 'height': 792}] * 31,
                'gc_timeline_reads': 1, 'observed_frames': frames,
                'first_board_build_samples_us': [30] * 30,
                'gc_timeline_capture': {'profile_widgets': False, 'from_us': 0,
                                        'to_us': 3000, 'events': events}}]}]}


class GCFramesTest(unittest.TestCase):
    def test_v2_requires_declared_fixture_and_shell(self):
        r = report()
        r.update(gc_observation_protocol='gc-only-deferred-30-v2',
                 gc_task_count=1000, shell_theme_protocol='cached-default-theme-v2')
        r['results'][0]['tasks'] = 1000
        self.assertEqual(module.analyze(r)['tasks'], 1000)
        for field, value in [('gc_task_count', 10000), ('shell_theme_protocol', 'unknown')]:
            bad = copy.deepcopy(r)
            bad[field] = value
            with self.assertRaises(ValueError):
                module.analyze(bad)

    def test_nested_scopes_union_and_clip_to_native_build(self):
        r = report()
        events = r['results'][0]['views'][0]['gc_timeline_capture']['events']
        events.extend([
            {'ph': 'B', 'cat': 'GC', 'name': 'CollectNewGeneration', 'pid': 1, 'tid': 2, 'ts': 5},
            {'ph': 'B', 'cat': 'GC', 'name': 'Scavenge', 'pid': 1, 'tid': 2, 'ts': 12},
            {'ph': 'E', 'cat': 'GC', 'name': 'Scavenge', 'pid': 1, 'tid': 2, 'ts': 18},
            {'ph': 'E', 'cat': 'GC', 'name': 'CollectNewGeneration', 'pid': 1, 'tid': 2, 'ts': 20},
        ])
        a = module.analyze(r)
        self.assertEqual(a['frames'][0]['gc_scope_union_us'], 10)
        self.assertEqual(a['with_gc']['samples'], 1)
        self.assertEqual(a['without_gc']['samples'], 29)

    def test_worker_gc_and_same_name_non_gc_do_not_count(self):
        r = report()
        r['results'][0]['views'][0]['gc_timeline_capture']['events'].extend([
            {'ph': 'X', 'cat': 'GC', 'name': 'Scavenge', 'pid': 1, 'tid': 3, 'ts': 10, 'dur': 30},
            {'ph': 'X', 'cat': 'Dart', 'name': 'Scavenge', 'pid': 1, 'tid': 2, 'ts': 10, 'dur': 30},
        ])
        a = module.analyze(r)
        self.assertIsNone(a['with_gc'])
        self.assertEqual(a['without_gc']['samples'], 30)

    def test_missing_gc_pair_or_ui_thread_is_rejected(self):
        for event in [
            {'ph': 'B', 'cat': 'GC', 'name': 'Scavenge', 'pid': 1, 'tid': 2, 'ts': 12},
            {'ph': 'X', 'cat': 'Dart', 'name': 'BUILD', 'pid': 1, 'tid': 7, 'ts': 10, 'dur': 30},
        ]:
            r = report()
            r['results'][0]['views'][0]['gc_timeline_capture']['events'].append(event)
            with self.assertRaises(ValueError):
                module.analyze(r)

    def test_native_duration_or_capture_boundary_mismatch_is_rejected(self):
        r = report()
        r['results'][0]['views'][0]['observed_frames'][0]['build_finish_us'] = 41
        with self.assertRaises(ValueError):
            module.analyze(r)
        r = report()
        r['results'][0]['views'][0]['gc_timeline_capture']['from_us'] = 11
        with self.assertRaises(ValueError):
            module.analyze(r)

    def test_contaminated_and_nonforeground_protocols_are_rejected(self):
        for mutation in ['widgets', 'reads', 'foreground', 'baseline']:
            r = copy.deepcopy(report())
            view = r['results'][0]['views'][0]
            if mutation == 'widgets':
                view['gc_timeline_capture']['profile_widgets'] = True
            elif mutation == 'reads':
                view['gc_timeline_reads'] = 30
            elif mutation == 'foreground':
                r['segments'][0]['uninterrupted_foreground'] = False
            else:
                r['gc_observation'] = False
            with self.assertRaises(ValueError):
                module.analyze(r)


if __name__ == '__main__':
    unittest.main()
