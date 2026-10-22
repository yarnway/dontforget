#!/usr/bin/env python3
"""Summarize opt-in synthetic frame traces; inclusive spans are not CPU shares."""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path
import re


def summarize_frame(frame):
    start, end = frame['from_us'], frame['to_us']
    if end <= start:
        raise ValueError('Invalid frame interval')
    stacks = defaultdict(list)
    totals = defaultdict(lambda: {'count': 0, 'inclusive_us': 0})
    incomplete = 0

    def add(event, begin, finish):
        if finish < begin:
            raise ValueError('Negative event duration')
        duration = max(0, min(end, finish) - max(start, begin))
        if not duration:
            return
        key = (event.get('pid'), event.get('tid'), event.get('name', 'unnamed'))
        totals[key]['count'] += 1
        totals[key]['inclusive_us'] += duration

    events = []
    for index, event in enumerate(frame['events']):
        if event.get('ph') not in {'X', 'B', 'E'}:
            continue
        stamp = event.get('ts')
        if not isinstance(stamp, (float, int)) or not math.isfinite(stamp):
            raise ValueError('Missing event timestamp')
        events.append((stamp, index, event))
    for stamp, _, event in sorted(events):
        key = (event.get('pid'), event.get('tid'))
        if event['ph'] == 'X':
            duration = event.get('dur')
            if not isinstance(duration, (float, int)) or not math.isfinite(duration):
                raise ValueError('Missing event duration')
            add(event, stamp, stamp + duration)
        elif event['ph'] == 'B':
            stacks[key].append(event)
        elif stacks[key]:
            begin = stacks[key].pop()
            if event.get('name') not in {None, begin.get('name')}:
                incomplete += 2
            else:
                add(begin, begin['ts'], stamp)
        else:
            incomplete += 1
    incomplete += sum(map(len, stacks.values()))
    rows = [{'pid': key[0], 'tid': key[1], 'name': key[2], **value}
            for key, value in totals.items()]
    rows.sort(key=lambda row: row['inclusive_us'], reverse=True)
    return {
        'interval_us': end - start,
        'incomplete_boundary_pairs': incomplete,
        'top_inclusive_spans': rows[:30],
        'gc_name_matches': [row for row in rows if re.search(
            r'\bGC\b|Scavenge|Collect(?:New|Old)Generation|MarkSweep',
            row['name'], re.IGNORECASE)],
    }


def analyze(report):
    if (report.get('phase') != 'complete' or report.get('errors') != [] or
            report.get('focused_768_diagnostics') is not True or
            report.get('timing_comparable_to_baseline') is not False):
        raise ValueError('A completed focused diagnostic report is required')
    segments = report.get('segments', [])
    if not segments or not all(s['uninterrupted_foreground'] for s in segments):
        raise ValueError('The entire diagnostic must stay foreground')
    results = report['results']
    if len(results) != 1 or results[0]['tasks'] != 10000:
        raise ValueError('Expected the single 10000-task fixture')
    views = results[0]['views']
    if len(views) != 1 or views[0]['requested_width'] != 768:
        raise ValueError('Expected the single 768-pixel viewport')
    viewports = views[0].get('sample_viewports', [])
    if len(viewports) != 6 or not all(
            v['width'] == 768 and v['height'] == 792 for v in viewports):
        raise ValueError('Expected six mounts at the fixed 768 x 792 viewport')
    frames = views[0]['diagnostic_frames']
    if len(frames) != 5 or any(not frame.get('events') for frame in frames):
        raise ValueError('Expected five measured frame captures')
    return {
        'scope': 'Instrumented synthetic replacement frames; inclusive nested spans are not additive CPU shares; GC name matches are a heuristic, not proof of causation',
        'source_revision': report['source_revision'],
        'task_rows_sha256': results[0]['task_rows_sha256'],
        'native_acceptance': 'Trace analysis only; does not establish old/new performance improvement or OS notification acceptance',
        'frames': [summarize_frame(frame) for frame in frames],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True,
                        help='completed focused 768px results.json; reads only')
    args = parser.parse_args()
    print(json.dumps(analyze(json.loads(args.report.read_text())), indent=2,
                     ensure_ascii=False))


if __name__ == '__main__':
    main()
