#!/usr/bin/env python3
"""Relate native build intervals to same-thread GC scopes, without widget tracing."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path


def trace_spans(events):
    stacks = defaultdict(list)
    spans, incomplete = [], []
    ordered = []
    for index, event in enumerate(events):
        if event.get('ph') not in {'B', 'E', 'X'}:
            continue
        stamp = event.get('ts')
        if not isinstance(stamp, (int, float)) or not math.isfinite(stamp):
            raise ValueError('Invalid timeline timestamp')
        ordered.append((stamp, index, event))
    for stamp, _, event in sorted(ordered):
        key = (event.get('pid'), event.get('tid'), event.get('cat'))
        if event['ph'] == 'B':
            stacks[key].append(event)
            continue
        if event['ph'] == 'X':
            begin = event
            duration = event.get('dur')
            if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
                raise ValueError('Invalid timeline duration')
            finish = stamp + duration
        elif stacks[key]:
            begin = stacks[key].pop()
            if event.get('name') not in {None, begin.get('name')}:
                incomplete.extend([begin, event])
                continue
            finish = stamp
        else:
            incomplete.append(event)
            continue
        spans.append({'pid': key[0], 'tid': key[1], 'cat': key[2],
                      'name': begin.get('name'), 'start': begin['ts'], 'end': finish})
    for stack in stacks.values():
        incomplete.extend(stack)
    return spans, incomplete


def overlap(a, b, c, d):
    return max(0, min(b, d) - max(a, c))


def union_length(intervals):
    total, previous = 0, None
    for start, end in sorted(intervals):
        if previous is None or start > previous[1]:
            if previous is not None:
                total += previous[1] - previous[0]
            previous = (start, end)
        else:
            previous = (previous[0], max(previous[1], end))
    return total + (0 if previous is None else previous[1] - previous[0])


def distribution(values):
    if not values:
        return None
    values = sorted(values)
    return {'samples': len(values), 'p50_us': values[math.ceil(len(values) * .5) - 1],
            'p95_us': values[math.ceil(len(values) * .95) - 1], 'max_us': values[-1],
            'over_16667': sum(value > 16667 for value in values)}


def analyze(report):
    protocol = report.get('gc_observation_protocol')
    expected_tasks = 10000 if protocol == 'gc-only-deferred-30-v1' else report.get('gc_task_count')
    if (report.get('phase') != 'complete' or report.get('errors') != [] or
            report.get('restart_required') is not False or
            report.get('gc_observation') is not True or
            protocol not in {'gc-only-deferred-30-v1', 'gc-only-deferred-30-v2'} or
            report.get('focused_768_diagnostics') is not False or
            report.get('timing_comparable_to_baseline') is not False):
        raise ValueError('Expected a complete GC-only observation')
    if protocol.endswith('v2') and (expected_tasks not in {1000, 10000} or
            report.get('shell_theme_protocol') not in {
                'legacy-default-theme-v1', 'cached-default-theme-v2'}):
        raise ValueError('Expected an explicit fixture size and shell protocol')
    segments = report.get('segments', [])
    if not segments or not all(s.get('uninterrupted_foreground') is True for s in segments):
        raise ValueError('Observation was not entirely foreground')
    results = report['results']
    if len(results) != 1 or results[0]['tasks'] != expected_tasks or len(results[0]['views']) != 1:
        raise ValueError('Expected the single declared task viewport')
    view = results[0]['views'][0]
    mounts = view['sample_viewports']
    if (view['requested_width'] != 768 or len(mounts) != 31 or
            not all(m['width'] == 768 and m['height'] == 792 for m in mounts)):
        raise ValueError('Expected 31 mounts at 768 x 792')
    capture = view['gc_timeline_capture']
    if capture.get('profile_widgets') is not False or view['gc_timeline_reads'] != 1:
        raise ValueError('Widget tracing or per-frame reads contaminate this protocol')
    frames = view['observed_frames']
    if len(frames) != 30 or len(view['first_board_build_samples_us']) != 30:
        raise ValueError('Expected 30 measured native frames')
    spans, incomplete = trace_spans(capture['events'])
    rows = []
    recognized = {'CollectNewGeneration', 'CollectOldGeneration', 'Scavenge'}
    for i, frame in enumerate(frames):
        start, end = frame['build_start_us'], frame['build_finish_us']
        if (end < start or end - start != frame['build_us'] or
                frame['build_us'] != view['first_board_build_samples_us'][i] or
                not capture['from_us'] <= start <= end <= capture['to_us'] or
                not frame['install_start_us'] <= start <= frame['install_end_us']):
            raise ValueError('Native frame interval is inconsistent')
        threads = {(s['pid'], s['tid']) for s in spans if s['cat'] == 'Dart' and
                   s['name'] == 'BUILD' and overlap(start, end, s['start'], s['end'])}
        if len(threads) != 1:
            raise ValueError('Cannot establish the frame UI thread from BUILD scopes')
        thread = next(iter(threads))
        if any(e.get('cat') == 'GC' and (e.get('pid'), e.get('tid')) == thread
               for e in incomplete):
            raise ValueError('Unpaired UI-thread GC events make absence ambiguous')
        gc = [s for s in spans if s['cat'] == 'GC' and
              (s['pid'], s['tid']) == thread and s['name'] in recognized and
              overlap(start, end, s['start'], s['end'])]
        gc_us = union_length([(max(start, s['start']), min(end, s['end'])) for s in gc])
        rows.append({'sample': i + 1, 'build_us': frame['build_us'],
                     'gc_scope_union_us': gc_us, 'gc_names': sorted({s['name'] for s in gc}),
                     'pid': thread[0], 'ui_tid': thread[1]})
    return {
        'scope': 'Observed association only, not proof of GC causation. Same-thread recognized GC scopes are clipped to native build intervals and unioned, never added across nested scopes or worker threads. Timings are not an unobserved baseline.',
        'source_revision': report['source_revision'],
        **({'tasks': expected_tasks, 'shell_theme_protocol': report['shell_theme_protocol']}
           if protocol.endswith('v2') else {}),
        'task_rows_sha256': results[0]['task_rows_sha256'],
        'event_count': len(capture['events']), 'frames': rows,
        'with_gc': distribution([r['build_us'] for r in rows if r['gc_scope_union_us'] > 0]),
        'without_gc': distribution([r['build_us'] for r in rows if r['gc_scope_union_us'] == 0]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True,
                        help='complete GC-only results.json; reads only')
    args = parser.parse_args()
    print(json.dumps(analyze(json.loads(args.report.read_text())), indent=2))


if __name__ == '__main__':
    main()
