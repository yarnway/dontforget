#!/usr/bin/env python3
"""Generate synthetic inputs for a macOS guest crossing a real 2026 DST boundary.

Example:
  python3 scripts/generate_dst_acceptance_fixture.py \
    --output /tmp/dontforget-dst-001

Writes a NEW temporary directory only. Never launches an app, reads app data,
changes a clock, or accesses the network. Both cases use America/Los_Angeles:
spring skips 02:00; autumn repeats 01:00. Each v9 backup has two silent, once-only
tasks 20 seconds before/after the transition, with explicit UTC triggers.
Import one case into a verified disposable macOS guest, position its clock at
the manifest's start_at, then let the guest cross the boundary naturally.
The empty backup is for cleanup. These are inputs, NOT native delivery evidence.
"""
import argparse
from contextlib import closing
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from generate_recovery_acceptance_fixture import (
    ROOT, TABLES, digest_bytes, iso, reminder, table_evidence, validate_output,
)
from generate_reminder_acceptance_fixture import (
    NOTICE_DEFAULTS, populate_and_verify, read_schema9,
)


ZONE = 'America/Los_Angeles'
CASES = {
    'spring': (datetime(2026, 3, 8, 10, tzinfo=timezone.utc), -28800, -25200),
    'autumn': (datetime(2026, 11, 1, 9, tzinfo=timezone.utc), -25200, -28800),
}


def fixture_data(case):
    boundary, before_offset, after_offset = CASES[case]
    zone = ZoneInfo(ZONE)
    before = (boundary - timedelta(seconds=1)).astimezone(zone)
    after = boundary.astimezone(zone)
    if (before.utcoffset().total_seconds(), after.utcoffset().total_seconds()) != (
            before_offset, after_offset):
        raise ValueError('Installed timezone rules do not match this frozen acceptance case')
    start = boundary - timedelta(minutes=10)
    data = {
        'version': 9, 'timestamp': iso(start),
        'settings': [{'id': 'default', 'api_key': '', 'base_url': '',
                      'model_name': 'isolated-dst-no-service', 'language': 'en'}],
        'media_records': [{'id': f'qa-dst-{case}-text', 'type': 'text',
                           'content_or_path': 'Synthetic DST acceptance; no credentials or media.',
                           'created_at': iso(start)}],
        'reminders': [],
    }
    expectations = []
    for label, seconds in [('before', -20), ('after', 20)]:
        instant = boundary + timedelta(seconds=seconds)
        row = reminder(f'qa-dst-{case}-{label}', data['media_records'][0]['id'],
                       f'QA DST {case.upper()} {label.upper()}', start, instant)
        row.update(NOTICE_DEFAULTS)
        row['task_summary'] = 'Synthetic isolated macOS DST boundary acceptance.'
        data['reminders'].append(row)
        local = instant.astimezone(zone)
        expectations.append({'id': row['id'], 'trigger_utc': iso(instant),
                             'local_time': local.isoformat(), 'fold': local.fold,
                             'expected_deliveries': 1})
    expected = {
        'time_zone': ZONE, 'start_at': iso(start), 'boundary_utc': iso(boundary),
        'boundary_local_before': before.isoformat(),
        'boundary_local_after': after.isoformat(),
        'tasks': expectations, 'tables': table_evidence(data),
    }
    return data, expected


def generate(output, root=ROOT):
    output = validate_output(output)
    sql, fields = read_schema9(root)
    fixtures, expectations = {}, {}
    for case in CASES:
        fixtures[case], expectations[case] = fixture_data(case)
    fixtures['empty'] = {**fixtures['spring'], 'media_records': [], 'reminders': []}
    # Validate every schema/value before creating the output directory.
    for data in fixtures.values():
        for key in TABLES.values():
            if any(set(row) != fields[key] for row in data[key]):
                raise ValueError(f'Fixture fields differ from frozen schema v9: {key}')
        with closing(sqlite3.connect(':memory:')) as connection:
            populate_and_verify(connection, sql, data)
    output.mkdir(mode=0o700)
    files = {}
    for case, data in fixtures.items():
        target = output / f'{case}-v9.json'
        with target.open('x', encoding='utf-8') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        content = target.read_bytes()
        files[target.name] = {'bytes': len(content), 'sha256': digest_bytes(content)}
    manifest = {
        'purpose': 'isolated macOS 2026 DST boundary acceptance inputs',
        'schema_version': 9, 'cases': expectations, 'files': files,
        'empty_tables': table_evidence(fixtures['empty']),
        'requirements': [
            'Use a new macOS guest with synthetic data and a verified isolated app identity.',
            'Disable guest network time AND VM host time/timezone synchronization; never change the host clock.',
            'Read back guest time zone, UTC time and both native pending IDs before starting observation.',
            'Let time advance naturally across the boundary; retain host-monotonic and guest-wall-clock observations.',
            'Independently read OS deliveries for each ID and verify exactly once, timing and local offset.',
            'Restore the empty backup; verify pending=0 and retained=0, then restore guest clock/synchronization.',
        ],
        'boundaries': {'synthetic_only': True, 'contains_credentials': False,
                       'app_data_access': 'NEVER', 'clock_changes': 'NEVER',
                       'native_acceptance': 'NOT_PERFORMED',
                       'recurring_gap_and_fold_acceptance': 'NOT_COVERED',
                       'host_reboot_acceptance': 'NOT_COVERED'},
    }
    with (output / 'manifest.json').open('x', encoding='utf-8') as stream:
        json.dump(manifest, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--output', type=Path, required=True,
                        help='New leaf directory under the system temporary directory')
    args = parser.parse_args()
    try:
        result = generate(args.output)
    except (OSError, ValueError, sqlite3.Error, ZoneInfoNotFoundError) as error:
        parser.exit(1, f'Fixture generation failed: {error}\n')
    print(json.dumps({'output': str(args.output.absolute()), 'files': result['files'],
                      'native_acceptance': result['boundaries']['native_acceptance']}, indent=2))


if __name__ == '__main__':
    main()
