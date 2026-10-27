from contextlib import closing
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_reminder_acceptance_fixture import (
    NOTICE_DEFAULTS, ROOT, TABLES, generate, month_step, next_month_end_anchor,
    parse_start, read_schema9, table_evidence,
)


class ReminderAcceptanceFixtureTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dontforget-reminder-fixture-test-')
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / 'new-fixture'
        self.start = datetime(2026, 10, 21, 18, tzinfo=timezone(timedelta(hours=8)))

    def read_json(self, name):
        return json.loads((self.output / name).read_text(encoding='utf-8'))

    def test_both_sqlite_files_match_json_schema_and_logical_rows(self):
        manifest = generate(self.output, self.start)
        for prefix, version, count, evidence_key in [
            ('baseline-v8', 8, 1, 'baseline'), ('candidate-v9', 9, 4, 'candidate'),
        ]:
            data = self.read_json(f'{prefix}.json')
            target = self.output / f'{prefix}.sqlite'
            with closing(sqlite3.connect(f'file:{target}?mode=ro', uri=True)) as connection:
                self.assertEqual(connection.execute('PRAGMA user_version').fetchone()[0], version)
                self.assertEqual(connection.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
                self.assertEqual(connection.execute('PRAGMA foreign_key_check').fetchall(), [])
                self.assertEqual({row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}, set(TABLES))
                connection.row_factory = sqlite3.Row
                rows = {key: [dict(row) for row in connection.execute(f'SELECT * FROM {table}')]
                        for table, key in TABLES.items()}
                self.assertEqual(table_evidence(rows), table_evidence(data))
                self.assertEqual(table_evidence(rows), manifest[evidence_key]['tables'])
                fields = {row[1] for row in connection.execute('PRAGMA table_info(Reminders)')}
                self.assertEqual(bool(fields & set(NOTICE_DEFAULTS)), version == 9)
            self.assertEqual([len(data[key]) for key in TABLES.values()], [1, 1, count])
            self.assertEqual(target.read_bytes()[18:20], b'\x01\x01')
        self.assertEqual(sorted(path.name for path in self.output.iterdir()), [
            'baseline-v8.json', 'baseline-v8.sqlite', 'candidate-v9.json',
            'candidate-v9.sqlite', 'expected-upgraded-v9.json', 'manifest.json',
        ])

    def test_upgrade_expectations_preserve_every_legacy_value_and_supply_v9_defaults(self):
        manifest = generate(self.output, self.start)
        old = self.read_json('baseline-v8.json')
        expected = self.read_json('expected-upgraded-v9.json')
        self.assertEqual(manifest['expected_upgrade']['tables'], table_evidence(expected))
        self.assertEqual(expected['version'], 9)
        for key in ['settings', 'media_records']:
            self.assertEqual(old[key], expected[key])
        self.assertEqual(expected['reminders'][0], {**old['reminders'][0], **NOTICE_DEFAULTS})
        # Exercise SQLite's actual ADD COLUMN defaults on a disposable in-memory copy.
        with closing(sqlite3.connect(self.output / 'baseline-v8.sqlite')) as source:
            with closing(sqlite3.connect(':memory:')) as connection:
                source.backup(connection)
                connection.execute('ALTER TABLE Reminders ADD COLUMN notice_revision INTEGER NOT NULL DEFAULT 0')
                for name in NOTICE_DEFAULTS.keys() - {'notice_revision'}:
                    connection.execute(f'ALTER TABLE Reminders ADD COLUMN {name} TEXT')
                connection.execute('PRAGMA user_version = 9')
                connection.row_factory = sqlite3.Row
                migrated = {key: [dict(row) for row in connection.execute(f'SELECT * FROM {table}')]
                            for table, key in TABLES.items()}
                self.assertEqual(table_evidence(migrated), table_evidence(expected))

    def test_fixture_is_synthetic_silent_and_has_no_external_configuration(self):
        manifest = generate(self.output, self.start)
        for name in ['baseline-v8.json', 'candidate-v9.json', 'expected-upgraded-v9.json']:
            data = self.read_json(name)
            self.assertEqual(data['settings'][0]['api_key'], '')
            self.assertEqual(data['settings'][0]['base_url'], '')
            self.assertEqual(data['settings'][0]['language'], 'en')
            self.assertTrue(all(row['type'] == 'text' for row in data['media_records']))
            self.assertTrue(all(row['quadrant_level'] == 3 for row in data['reminders']))
            self.assertTrue(all(row['context_trigger'] is None for row in data['reminders']))
            self.assertTrue(all(row['is_dynamically_promoted'] == 0 for row in data['reminders']))
            self.assertTrue(all(row['task_title'].startswith('QA ') for row in data['reminders']))
        self.assertEqual(manifest['boundaries']['runtime_acceptance'], 'NOT_PERFORMED')
        self.assertEqual(manifest['boundaries']['audio_playback_acceptance'], 'SKIPPED')
        self.assertEqual(manifest['boundaries']['app_data_access'], 'NEVER')

    def test_due_times_follow_explicit_start_and_offset(self):
        manifest = generate(self.output, self.start, 7)
        times = manifest['candidate']['trigger_times']
        self.assertEqual(times['qa-ack-due'], '2026-10-21T10:07:00.000Z')
        self.assertEqual(times['qa-snooze-daily'], '2026-10-21T10:08:00.000Z')
        self.assertEqual(times['qa-daily-early'], '2026-10-22T10:00:00.000Z')
        self.assertEqual(times['qa-month-end'], '2026-10-31T12:00:00.000Z')

    def test_snooze_and_daily_acceptance_preserve_original_recurrence_anchor(self):
        manifest = generate(self.output, self.start)
        rows = {row['id']: row for row in self.read_json('candidate-v9.json')['reminders']}
        matrix = {row['step']: row for row in manifest['acceptance_matrix']}
        snooze = matrix[4]['expected']
        self.assertEqual(snooze['notice_revision'], 1)
        self.assertEqual(snooze['trigger_time'], 'snoozed_at + exactly 5 minutes')
        self.assertEqual(snooze['recurrence_anchor_time'], rows['qa-snooze-daily']['trigger_time'])
        after_snooze = matrix[5]['expected']
        self.assertEqual(after_snooze['notice_revision'], 2)
        self.assertEqual(after_snooze['recurrence_anchor_time'], '2026-10-21T10:03:00.000Z')
        self.assertEqual(after_snooze['trigger_time'], '2026-10-22T10:03:00.000Z')
        self.assertEqual(matrix[6]['expected']['trigger_time'], '2026-10-23T10:00:00.000Z')
        self.assertIsNone(after_snooze['snoozed_at'])
        for row in rows.values():
            self.assertEqual({key: row[key] for key in NOTICE_DEFAULTS}, NOTICE_DEFAULTS)

    def test_month_end_matrix_returns_to_original_day_after_short_month(self):
        manifest = generate(self.output, self.start)
        monthly = manifest['acceptance_matrix'][6]
        self.assertEqual(monthly['expected_after_first']['trigger_time'], '2026-11-30T12:00:00.000Z')
        self.assertEqual(monthly['expected_after_second']['trigger_time'], '2026-12-31T12:00:00.000Z')
        for key, revision in [('expected_after_first', 1), ('expected_after_second', 2)]:
            self.assertEqual(monthly[key]['recurrence_anchor_time'], '2026-10-31T12:00:00.000Z')
            self.assertEqual(monthly[key]['notice_revision'], revision)

    def test_month_end_anchor_is_future_across_year_and_leap_boundaries(self):
        for instant in ['2027-01-30T23:00:00Z', '2028-01-31T12:00:00Z',
                        '2027-12-31T22:00:00Z', '2026-07-31T13:00:00Z']:
            start = parse_start(instant)
            anchor = next_month_end_anchor(start)
            self.assertGreater(anchor, start)
            self.assertEqual(anchor.day, 31)
            self.assertLess(month_step(anchor, 1).day, 31)
            self.assertEqual(month_step(anchor, 2).day, 31)
        leap_anchor = next_month_end_anchor(parse_start('2028-01-01T00:00:00Z'))
        self.assertEqual(month_step(leap_anchor, 1).day, 29)

    def test_manifest_hashes_cover_every_input_and_expected_upgrade(self):
        manifest = generate(self.output, self.start)
        self.assertEqual(manifest, self.read_json('manifest.json'))
        self.assertEqual(set(manifest['files']), {
            'baseline-v8.json', 'baseline-v8.sqlite', 'candidate-v9.json',
            'candidate-v9.sqlite', 'expected-upgraded-v9.json',
        })
        for name, expected in manifest['files'].items():
            content = (self.output / name).read_bytes()
            self.assertEqual(hashlib.sha256(content).hexdigest(), expected['sha256'])
            self.assertEqual(len(content), expected['bytes'])
        data = self.read_json('candidate-v9.json')
        reversed_data = {key: [dict(reversed(list(row.items()))) for row in reversed(data[key])]
                         for key in TABLES.values()}
        self.assertEqual(table_evidence(reversed_data), manifest['candidate']['tables'])

    def test_frozen_v11_schema_matches_candidate_creation_sql(self):
        source = (ROOT / 'lib/data/database_helper.dart').read_text(encoding='utf-8')
        creation = re.findall(r"await db.execute\('''\n(CREATE TABLE .*?)\n'''\)", source, re.S)
        schema = (ROOT / 'test/fixtures/schema_v11.sql').read_text(encoding='utf-8')
        schema = '\n'.join(line for line in schema.splitlines() if not line.lstrip().startswith('--'))
        sql = [item.strip() for item in schema.split(';') if item.strip()]
        self.assertIn('schemaVersion = 11;', source)
        self.assertEqual(len(creation), 3)
        self.assertEqual(len(sql), 3)
        for fixture, statement in zip(sql, creation):
            for token, definition in [('idType', 'TEXT PRIMARY KEY'), ('textType', 'TEXT NOT NULL'),
                                      ('integerType', 'INTEGER NOT NULL'), ('boolType', 'BOOLEAN NOT NULL')]:
                statement = statement.replace('$' + token, definition)
            self.assertEqual(' '.join(statement.split()), ' '.join(fixture.split()))

    def test_existing_directory_file_and_symlink_are_never_overwritten(self):
        generate(self.output, self.start)
        before = {path.name: path.read_bytes() for path in self.output.iterdir()}
        existing = Path(self.temp.name) / 'existing-file'
        existing.write_bytes(b'preserve')
        link = Path(self.temp.name) / 'existing-link'
        link.symlink_to(self.output)
        dangling = Path(self.temp.name) / 'dangling'
        dangling.symlink_to(Path(self.temp.name) / 'absent')
        for output in [self.output, existing, link, dangling]:
            with self.assertRaises(ValueError):
                generate(output, self.start)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.output.iterdir()})
        self.assertEqual(existing.read_bytes(), b'preserve')

    def test_invalid_time_due_and_output_locations_create_nothing(self):
        for minutes in [0, -1, 1441, 1.2, True]:
            with self.assertRaises(ValueError):
                generate(self.output, self.start, minutes)
            self.assertFalse(self.output.exists())
        with self.assertRaises(ValueError):
            generate(self.output, datetime(2026, 10, 21))
        with self.assertRaises(ValueError):
            generate(ROOT / 'do-not-create-reminder-fixture', self.start)
        self.assertFalse((ROOT / 'do-not-create-reminder-fixture').exists())
        with self.assertRaises(FileNotFoundError):
            generate(Path(self.temp.name) / 'absent' / 'new', self.start)

    def test_schema_drift_and_extra_sql_fail_before_creating_output(self):
        fake_root = Path(self.temp.name) / 'repository'
        directory = fake_root / 'test/fixtures'
        directory.mkdir(parents=True)
        (directory / 'schema_v8.sql').write_bytes((ROOT / 'test/fixtures/schema_v8.sql').read_bytes())
        original = (ROOT / 'test/fixtures/schema_v9.sql').read_text()
        for invalid in [original.replace('notice_revision INTEGER', 'changed_revision INTEGER'),
                        original + '\nDROP TABLE Reminders;']:
            (directory / 'schema_v9.sql').write_text(invalid)
            with self.assertRaises(ValueError):
                generate(self.output, self.start, root=fake_root)
            self.assertFalse(self.output.exists())

    def test_cli_help_argument_validation_and_success(self):
        script = ROOT / 'scripts/generate_reminder_acceptance_fixture.py'
        help_result = subprocess.run([sys.executable, str(script), '--help'], capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0)
        self.assertIn('--start-at', help_result.stdout)
        self.assertIn('--due-minutes', help_result.stdout)
        self.assertIn('in-place 8 -> 9', help_result.stdout)
        for tail in [['--start-at', '2026-10-21T18:00:00'],
                     ['--start-at', '2026-10-21T18:00:00+08:00', '--due-minutes', '0']]:
            invalid = subprocess.run([sys.executable, str(script), '--output', str(self.output), *tail],
                                     capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertFalse(self.output.exists())
        valid = subprocess.run([sys.executable, str(script), '--output', str(self.output),
                                '--start-at', '2026-10-21T18:00:00+08:00'], capture_output=True, text=True)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(json.loads(valid.stdout)['candidate']['schema_version'], 9)


if __name__ == '__main__':
    unittest.main()
