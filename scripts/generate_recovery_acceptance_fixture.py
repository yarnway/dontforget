#!/usr/bin/env python3
"""Create synthetic recovery inputs in a NEW temporary directory; never open app data.

Example:
  python3 scripts/generate_recovery_acceptance_fixture.py \
    --output /tmp/dontforget-recovery-fixture-001 \
    --start-at 2026-10-21T10:00:00+08:00 --due-minutes 12

Only the frozen v8 SQL fixture and the explicitly requested output are read.
The generated v8 inputs remain compatible with the fd74ad9 native candidate
even after the application schema advances; they do not validate new schemas.
No app is launched, no network is used, and existing outputs are never replaced.
The generated Q3 reminders are silent under the current notification policy.
The baseline reminder is due at start-at + due-minutes; the candidate reminder
is due one minute later. Candidate JSON and SQLite contain the same three-table
contents, including one completed task without a trigger. invalid.json has an
invalid boolean for rejection checks. manifest.json records file and logical
table SHA-256 hashes, counts and expected reminder IDs; these are fixture
expectations, not evidence of native delivery. Keep the source files unchanged
and copy the baseline into a separately isolated app data directory as needed.
"""
import argparse
from contextlib import closing
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile


ROOT = Path(__file__).resolve().parents[1]
TABLES = {'Settings': 'settings', 'MediaRecords': 'media_records', 'Reminders': 'reminders'}


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def canonical_rows(rows):
    """Stable logical table encoding, shared by JSON and SQLite readback."""
    return json.dumps(sorted(rows, key=lambda row: row['id']), ensure_ascii=False,
                      sort_keys=True, separators=(',', ':')).encode('utf-8')


def table_evidence(data):
    return {key: {'count': len(data[key]), 'sha256': digest_bytes(canonical_rows(data[key]))}
            for key in TABLES.values()}


def read_schema(root=ROOT):
    """Keep native v8 acceptance reproducible after application migrations."""
    fixture = root / 'test/fixtures/schema_v8.sql'
    try:
        source = fixture.read_text(encoding='utf-8')
    except OSError as error:
        raise ValueError('Frozen schema v8 fixture is unavailable') from error
    source = '\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('--'))
    sql = [item.strip() for item in source.split(';') if item.strip()]
    names = [re.fullmatch(r'CREATE TABLE (\w+)\s*\(.*\)', item, re.S) for item in sql]
    if (len(sql) != 3 or any(match is None for match in names) or
            [match.group(1) for match in names] != list(TABLES)):
        raise ValueError('Frozen schema v8 must contain exactly three business tables')
    with closing(sqlite3.connect(':memory:')) as connection:
        for statement in sql:
            connection.execute(statement)
        whitelist = {key: {row[1] for row in connection.execute(f'PRAGMA table_info({table})')}
                     for table, key in TABLES.items()}
    return sql, whitelist


def parse_start(value):
    try:
        start = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError as error:
        raise argparse.ArgumentTypeError('start-at must be an ISO timestamp with timezone') from error
    if start.tzinfo is None or start.utcoffset() is None:
        raise argparse.ArgumentTypeError('start-at must include Z or an explicit timezone offset')
    return start.astimezone(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def reminder(identifier, record_id, title, start, trigger=None, completed=False):
    return {
        'id': identifier, 'record_id': record_id, 'task_title': title,
        'task_summary': 'Synthetic isolated recovery acceptance data.',
        'quadrant_level': 3, 'urgency_level': None, 'importance_level': None,
        'trigger_time': iso(trigger) if trigger else None,
        'is_completed': int(completed), 'is_recurring': 0, 'recurrence_rule': 'none',
        'recurrence_description': None, 'is_emotion_filtered': 0, 'sub_tasks': '[]',
        'created_at': iso(start), 'review_level': 0, 'next_review_at': None,
        'original_quadrant_level': 3, 'is_dynamically_promoted': 0,
        'linked_task_ids': '[]', 'context_trigger': None,
    }


def fixture_data(start, due_minutes, candidate):
    label = 'new' if candidate else 'old'
    record_id = f'only-{label}-text'
    data = {
        'version': 8, 'timestamp': iso(start),
        'settings': [{'id': 'default', 'api_key': '', 'base_url': '',
                      'model_name': f'isolated-{label}-model', 'language': 'en'}],
        'media_records': [{'id': record_id, 'type': 'text',
                           'content_or_path': f'Only {label} synthetic text record.',
                           'created_at': iso(start)}],
        'reminders': [reminder(f'only-{label}', record_id, f'ONLY {label.upper()} - silent Q3',
                               start, start + timedelta(minutes=due_minutes + int(candidate)))],
    }
    if candidate:
        data['reminders'].append(reminder('new-completed', None, 'NEW completed - no reminder',
                                          start, completed=True))
    return data


def validate_output(output):
    output = Path(os.path.abspath(output))
    if os.path.lexists(output):
        raise ValueError('Output must be a new directory; existing files and directories are never replaced')
    parent = output.parent.resolve(strict=True)
    temporary_roots = {Path(tempfile.gettempdir()).resolve(), Path('/tmp').resolve()}
    if not parent.is_dir() or not any(parent == root or root in parent.parents for root in temporary_roots):
        raise ValueError('Output parent must be an existing system temporary directory')
    return parent / output.name


def generate(output, start, due_minutes=12, root=ROOT):
    if not isinstance(start, datetime) or start.tzinfo is None or start.utcoffset() is None:
        raise ValueError('start must be a timezone-aware datetime')
    if not isinstance(due_minutes, int) or isinstance(due_minutes, bool) or not 1 <= due_minutes <= 1440:
        raise ValueError('due-minutes must be an integer between 1 and 1440')
    output = validate_output(output)
    sql, whitelist = read_schema(root)
    baseline = fixture_data(start, due_minutes, candidate=False)
    candidate = fixture_data(start, due_minutes, candidate=True)
    for data in [baseline, candidate]:
        for key in TABLES.values():
            if any(set(row) != whitelist[key] for row in data[key]):
                raise ValueError(f'Fixture fields no longer match the backup whitelist: {key}')
    # Schema/fixture compatibility is checked entirely in memory before any output is created.
    with closing(sqlite3.connect(':memory:')) as check:
        for statement in sql:
            check.execute(statement)
        for table, key in TABLES.items():
            if {row[1] for row in check.execute(f'PRAGMA table_info({table})')} != whitelist[key]:
                raise ValueError(f'Application SQL and backup whitelist disagree: {table}')
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

    write_json('baseline.json', baseline)
    write_json('candidate.json', candidate)
    invalid = json.loads(json.dumps(candidate))
    invalid['reminders'][0]['is_completed'] = 2
    write_json('invalid.json', invalid)
    target = output / 'candidate.sqlite'
    # Exclusive reservation protects against accidentally reopening a pre-existing database.
    with target.open('xb'):
        pass
    with closing(sqlite3.connect(target)) as connection:
        connection.execute('PRAGMA journal_mode = DELETE')
        connection.execute('PRAGMA foreign_keys = ON')
        connection.execute('PRAGMA user_version = 8')
        for statement in sql:
            connection.execute(statement)
        for table, key in TABLES.items():
            for row in candidate[key]:
                fields = ','.join(row)
                placeholders = ','.join('?' for _ in row)
                connection.execute(f'INSERT INTO {table} ({fields}) VALUES ({placeholders})', tuple(row.values()))
        connection.commit()
        if connection.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise ValueError('Generated database failed integrity check')
        if connection.execute('PRAGMA foreign_key_check').fetchall():
            raise ValueError('Generated database has unresolved references')
        connection.row_factory = sqlite3.Row
        readback = {key: [dict(row) for row in connection.execute(f'SELECT * FROM {table}')]
                    for table, key in TABLES.items()}
        if table_evidence(readback) != table_evidence(candidate):
            raise ValueError('SQLite and JSON logical contents differ')
    record_file('candidate.sqlite')
    if any(Path(str(target) + suffix).exists() for suffix in ['-wal', '-journal', '-shm']):
        raise ValueError('Generated database has unexpected SQLite sidecars')
    manifest = {
        'purpose': 'synthetic isolated native recovery acceptance',
        'schema_version': 8, 'start_at': iso(start), 'due_minutes': due_minutes,
        'baseline_trigger_time': baseline['reminders'][0]['trigger_time'],
        'candidate_trigger_time': candidate['reminders'][0]['trigger_time'],
        'schema_source': 'test/fixtures/schema_v8.sql',
        'schema_sha256': digest_bytes(('\n'.join(sql) + '\n').encode('utf-8')),
        'table_hash_encoding': 'UTF-8 JSON; rows sorted by id; keys sorted; compact separators; literal Unicode',
        'baseline': {'tables': table_evidence(baseline), 'expected_pending_ids': ['only-old']},
        'candidate': {'tables': table_evidence(candidate), 'expected_pending_ids': ['only-new']},
        'invalid': {'expected_inspection_error': 'invalidData', 'reason': 'is_completed must be 0 or 1'},
        'files': files,
        'boundaries': {'synthetic_only': True, 'contains_credentials': False, 'external_endpoints': False,
                       'audio_playback_acceptance': 'SKIPPED', 'runtime_acceptance': 'NOT_PERFORMED'},
    }
    write_json('manifest.json', manifest, record=False)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--output', type=Path, required=True, help='New leaf directory under the system temporary directory')
    parser.add_argument('--start-at', type=parse_start, required=True, help='ISO timestamp including Z or offset')
    parser.add_argument('--due-minutes', type=int, default=12, help='Old Q3 due minutes after start-at; new Q3 is one minute later (1..1440; default: 12)')
    args = parser.parse_args()
    try:
        manifest = generate(args.output, args.start_at, args.due_minutes)
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f'Fixture generation failed: {error}\n')
    print(json.dumps({'output': str(args.output.absolute()),
                      'baseline_trigger_time': manifest['baseline_trigger_time'],
                      'candidate_trigger_time': manifest['candidate_trigger_time'],
                      'baseline': manifest['baseline'], 'candidate': manifest['candidate']}, indent=2))


if __name__ == '__main__':
    main()
