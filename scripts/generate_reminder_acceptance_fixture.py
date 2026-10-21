#!/usr/bin/env python3
"""Generate synthetic v8/v9 inputs for isolated native reminder acceptance.

Example:
  python3 scripts/generate_reminder_acceptance_fixture.py \
    --output /tmp/dontforget-reminder-fixture-001 \
    --start-at 2026-10-21T18:00:00+08:00 --due-minutes 2

The output MUST be a new directory below the system temporary directory.
This script never opens app data, launches apps, changes the clock, or uses
the network. It reads only frozen schema fixtures and writes synthetic inputs.
baseline-v8.sqlite is intended for an in-place 8 -> 9 upgrade, not a restore:
an operator must first verify a NEW isolated QA bundle/container, quit the QA
app, and then install a copy of that baseline. Never use a real user container.
candidate-v9.json and candidate-v9.sqlite have identical business contents.
Four text-only Q3 tasks cover due acknowledgement/restart, five-minute snooze,
daily advancement, and two early month-end completions (31 -> short month -> 31).
Q3 is silent under the candidate policy. The manifest records expected data,
timestamps, hashes and the minimal UI sequence; it is not runtime evidence.
Generate close to acceptance time. A due notice appears for 15 minutes after
its trigger; use a recent earlier --start-at if the notice should already be due.
"""
import argparse
from calendar import monthrange
from contextlib import closing
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import sqlite3

from generate_recovery_acceptance_fixture import (
    ROOT, TABLES, digest_bytes, iso, parse_start, read_schema,
    reminder, table_evidence, validate_output,
)


NOTICE_DEFAULTS = {
    'notice_revision': 0,
    'notice_acknowledged_at': None,
    'upcoming_dismissed_at': None,
    'snoozed_at': None,
    'recurrence_anchor_time': None,
}


def read_schema9(root=ROOT):
    fixture = root / 'test/fixtures/schema_v9.sql'
    try:
        source = fixture.read_text(encoding='utf-8')
    except OSError as error:
        raise ValueError('Frozen schema v9 fixture is unavailable') from error
    source = '\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('--'))
    sql = [item.strip() for item in source.split(';') if item.strip()]
    matches = [re.fullmatch(r'CREATE TABLE (\w+)\s*\(.*\)', item, re.S) for item in sql]
    if (len(sql) != 3 or any(match is None for match in matches) or
            [match.group(1) for match in matches] != list(TABLES)):
        raise ValueError('Frozen schema v9 must contain exactly three business tables')
    with closing(sqlite3.connect(':memory:')) as connection:
        for statement in sql:
            connection.execute(statement)
        whitelist = {key: {row[1] for row in connection.execute(f'PRAGMA table_info({table})')}
                     for table, key in TABLES.items()}
    return sql, whitelist


def month_step(anchor, months):
    ordinal = anchor.year * 12 + anchor.month - 1 + months
    year, zero_month = divmod(ordinal, 12)
    month = zero_month + 1
    return anchor.replace(year=year, month=month,
                          day=min(anchor.day, monthrange(year, month)[1]))


def next_month_end_anchor(start):
    """A future UTC noon on the 31st followed by a shorter month."""
    start = start.astimezone(timezone.utc)
    for offset in range(13):
        year, zero_month = divmod(start.year * 12 + start.month - 1 + offset, 12)
        month = zero_month + 1
        if monthrange(year, month)[1] != 31:
            continue
        candidate = datetime(year, month, 31, 12, tzinfo=timezone.utc)
        if candidate > start and month_step(candidate, 1).day < 31:
            return candidate
    raise ValueError('No future month-end acceptance date is available')


def fixture_data(start, due_minutes):
    start = start.astimezone(timezone.utc)
    settings = [{'id': 'default', 'api_key': '', 'base_url': '',
                 'model_name': 'isolated-schema9-model', 'language': 'en'}]
    records = [{'id': 'qa-synthetic-text', 'type': 'text',
                'content_or_path': 'Synthetic native reminder acceptance. No media or credentials.',
                'created_at': iso(start)}]
    baseline = {
        'version': 8, 'timestamp': iso(start), 'settings': settings,
        'media_records': records,
        'reminders': [reminder('qa-upgrade-keep', records[0]['id'],
                               'QA UPGRADE KEEP', start, start + timedelta(days=1))],
    }
    definitions = [
        ('qa-ack-due', 'QA 1 ACK DUE', start + timedelta(minutes=due_minutes), 'none'),
        ('qa-snooze-daily', 'QA 2 SNOOZE DAILY', start + timedelta(minutes=due_minutes + 1), 'daily'),
        ('qa-daily-early', 'QA 3 DAILY EARLY', start + timedelta(days=1), 'daily'),
        ('qa-month-end', 'QA 4 MONTH END', next_month_end_anchor(start), 'monthly'),
    ]
    reminders = []
    for identifier, title, trigger, rule in definitions:
        row = reminder(identifier, records[0]['id'], title, start, trigger)
        row.update(NOTICE_DEFAULTS)
        row.update(is_recurring=int(rule != 'none'), recurrence_rule=rule)
        reminders.append(row)
    candidate = {
        'version': 9, 'timestamp': iso(start), 'settings': settings,
        'media_records': records, 'reminders': reminders,
    }
    upgraded = json.loads(json.dumps(baseline))
    upgraded['version'] = 9
    for row in upgraded['reminders']:
        row.update(NOTICE_DEFAULTS)
    return baseline, candidate, upgraded


def populate_and_verify(connection, sql, data):
    connection.execute('PRAGMA foreign_keys = ON')
    connection.execute(f'PRAGMA user_version = {data["version"]}')
    for statement in sql:
        connection.execute(statement)
    for table, key in TABLES.items():
        for row in data[key]:
            connection.execute(
                f'INSERT INTO {table} ({",".join(row)}) VALUES ({",".join("?" for _ in row)})',
                tuple(row.values()))
    connection.commit()
    if connection.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
        raise ValueError('Generated database failed integrity check')
    if connection.execute('PRAGMA foreign_key_check').fetchall():
        raise ValueError('Generated database has unresolved references')
    connection.row_factory = sqlite3.Row
    readback = {key: [dict(row) for row in connection.execute(f'SELECT * FROM {table}')]
                for table, key in TABLES.items()}
    if table_evidence(readback) != table_evidence(data):
        raise ValueError('SQLite and JSON logical contents differ')


def acceptance_matrix(candidate):
    rows = {row['id']: row for row in candidate['reminders']}
    daily = parse_start(rows['qa-daily-early']['trigger_time'])
    monthly = parse_start(rows['qa-month-end']['trigger_time'])
    snooze = parse_start(rows['qa-snooze-daily']['trigger_time'])
    return [
        {'step': 1, 'action': 'Install a COPY of baseline-v8.sqlite into the verified new QA container while QA app is closed, then launch.',
         'expected': 'user_version=9; original business fields retained; the five notice columns equal upgrade_defaults.',
         'boundary': 'This must be an in-place upgrade. Restoring a backup does not prove startup migration.'},
        {'step': 2, 'action': 'Use the native restore confirmation UI to restore candidate-v9.json or candidate-v9.sqlite.',
         'expected': 'Exactly four QA tasks; SQLite/JSON business rows match candidate table hashes.'},
        {'step': 3, 'id': 'qa-ack-due', 'action': 'After due, choose acknowledgement (not completion), quit normally, then relaunch.',
         'expected': {'is_completed': 0, 'notice_revision': 0, 'notice_acknowledged_at': 'non-null and unchanged after restart',
                      'trigger_time': rows['qa-ack-due']['trigger_time'], 'upcoming_dismissed_at': None,
                      'native_request': 'cancelled; not rescheduled on restart'}},
        {'step': 4, 'id': 'qa-snooze-daily', 'action': 'After due, choose Snooze 5 min. Read back immediately and after restart.',
         'expected': {'is_completed': 0, 'notice_revision': 1, 'notice_acknowledged_at': None,
                      'upcoming_dismissed_at': None, 'snoozed_at': 'actual action time',
                      'trigger_time': 'snoozed_at + exactly 5 minutes',
                      'recurrence_anchor_time': rows['qa-snooze-daily']['trigger_time'],
                      'native_request': 'old occurrence cancelled; new occurrence scheduled'}},
        {'step': 5, 'id': 'qa-snooze-daily', 'action': 'Complete the snoozed occurrence early using its task card.',
         'expected': {'is_completed': 0, 'notice_revision': 2, 'snoozed_at': None,
                      'notice_acknowledged_at': None, 'upcoming_dismissed_at': None,
                      'trigger_time': iso(snooze + timedelta(days=1)),
                      'recurrence_anchor_time': iso(snooze)},
         'precondition': 'Perform during the same acceptance session, before the next daily occurrence.'},
        {'step': 6, 'id': 'qa-daily-early', 'action': 'Complete the future daily task early using its task card.',
         'expected': {'is_completed': 0, 'notice_revision': 1,
                      'trigger_time': iso(daily + timedelta(days=1)), 'recurrence_anchor_time': iso(daily)}},
        {'step': 7, 'id': 'qa-month-end', 'action': 'Complete the future monthly task early twice; inspect after each completion.',
         'expected_after_first': {'is_completed': 0, 'notice_revision': 1,
                                  'trigger_time': iso(month_step(monthly, 1)), 'recurrence_anchor_time': iso(monthly)},
         'expected_after_second': {'is_completed': 0, 'notice_revision': 2,
                                   'trigger_time': iso(month_step(monthly, 2)), 'recurrence_anchor_time': iso(monthly)},
         'boundary': 'No system-clock changes are required; early completion advances beyond the current future trigger.'},
        {'step': 8, 'action': 'Quit normally and relaunch; read back all changed task rows and native requests.',
         'expected': 'Acknowledgement remains suppressed; snooze/recurrence revisions and times survive restart.'},
    ]


def generate(output, start, due_minutes=2, root=ROOT):
    if not isinstance(start, datetime) or start.tzinfo is None or start.utcoffset() is None:
        raise ValueError('start must be a timezone-aware datetime')
    if not isinstance(due_minutes, int) or isinstance(due_minutes, bool) or not 1 <= due_minutes <= 1440:
        raise ValueError('due-minutes must be an integer between 1 and 1440')
    output = validate_output(output)
    sql8, fields8 = read_schema(root)
    sql9, fields9 = read_schema9(root)
    baseline, candidate, upgraded = fixture_data(start, due_minutes)
    for data, sql, fields in [(baseline, sql8, fields8), (candidate, sql9, fields9), (upgraded, sql9, fields9)]:
        for key in TABLES.values():
            if any(set(row) != fields[key] for row in data[key]):
                raise ValueError(f'Fixture fields no longer match frozen schema v{data["version"]}: {key}')
        # All schemas and row values are validated before any output is created.
        with closing(sqlite3.connect(':memory:')) as connection:
            populate_and_verify(connection, sql, data)
    output.mkdir(mode=0o700)
    files = {}

    def record_file(name):
        content = (output / name).read_bytes()
        files[name] = {'bytes': len(content), 'sha256': digest_bytes(content)}

    def write_json(name, data, record=True):
        with (output / name).open('x', encoding='utf-8') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        if record:
            record_file(name)

    for prefix, data, sql in [('baseline-v8', baseline, sql8), ('candidate-v9', candidate, sql9)]:
        write_json(f'{prefix}.json', data)
        target = output / f'{prefix}.sqlite'
        with target.open('xb'):
            pass
        with closing(sqlite3.connect(target)) as connection:
            connection.execute('PRAGMA journal_mode = DELETE')
            populate_and_verify(connection, sql, data)
        if any(Path(str(target) + suffix).exists() for suffix in ['-wal', '-journal', '-shm']):
            raise ValueError('Generated database has unexpected SQLite sidecars')
        record_file(target.name)
    write_json('expected-upgraded-v9.json', upgraded)
    manifest = {
        'purpose': 'synthetic isolated native schema 9 upgrade and reminder acceptance',
        'start_at': iso(start), 'due_minutes': due_minutes,
        'schema_sources': {
            str(version): {'path': f'test/fixtures/schema_v{version}.sql',
                           'sha256': digest_bytes(('\n'.join(sql) + '\n').encode('utf-8'))}
            for version, sql in [(8, sql8), (9, sql9)]
        },
        'table_hash_encoding': 'UTF-8 JSON; rows sorted by id; keys sorted; compact separators; literal Unicode',
        'baseline': {'schema_version': 8, 'tables': table_evidence(baseline), 'expected_ids': ['qa-upgrade-keep']},
        'expected_upgrade': {'schema_version': 9, 'tables': table_evidence(upgraded), 'upgrade_defaults': NOTICE_DEFAULTS},
        'candidate': {'schema_version': 9, 'tables': table_evidence(candidate),
                      'expected_ids': [row['id'] for row in candidate['reminders']],
                      'trigger_times': {row['id']: row['trigger_time'] for row in candidate['reminders']}},
        'acceptance_matrix': acceptance_matrix(candidate),
        'files': files,
        'boundaries': {'synthetic_only': True, 'contains_credentials': False, 'external_endpoints': False,
                       'app_data_access': 'NEVER', 'app_launch': 'NEVER',
                       'audio_playback_acceptance': 'SKIPPED', 'runtime_acceptance': 'NOT_PERFORMED'},
    }
    write_json('manifest.json', manifest, record=False)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--output', type=Path, required=True, help='New leaf directory under the system temporary directory')
    parser.add_argument('--start-at', type=parse_start, required=True, help='ISO timestamp including Z or offset')
    parser.add_argument('--due-minutes', type=int, default=2,
                        help='ACK due minutes after start; SNOOZE one minute later (1..1440; default: 2)')
    args = parser.parse_args()
    try:
        manifest = generate(args.output, args.start_at, args.due_minutes)
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f'Fixture generation failed: {error}\n')
    print(json.dumps({'output': str(args.output.absolute()), 'candidate': manifest['candidate'],
                      'baseline': manifest['baseline'], 'expected_upgrade': manifest['expected_upgrade']}, indent=2))


if __name__ == '__main__':
    main()
