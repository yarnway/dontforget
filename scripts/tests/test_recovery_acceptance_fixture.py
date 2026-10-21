import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_recovery_acceptance_fixture import ROOT, TABLES, generate, parse_start, read_schema, table_evidence


class RecoveryAcceptanceFixtureTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dontforget-fixture-test-')
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / 'new-fixture'
        self.start = datetime(2026, 10, 21, 9, 30, tzinfo=timezone(timedelta(hours=8)))

    def test_json_and_sqlite_have_identical_frozen_v8_schema_and_contents(self):
        manifest = generate(self.output, self.start)
        baseline = json.loads((self.output / 'baseline.json').read_text())
        candidate = json.loads((self.output / 'candidate.json').read_text())
        with sqlite3.connect(self.output / 'candidate.sqlite') as connection:
            connection.row_factory = sqlite3.Row
            self.assertEqual(connection.execute('PRAGMA user_version').fetchone()[0], 8)
            self.assertEqual(connection.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            self.assertEqual(connection.execute('PRAGMA foreign_key_check').fetchall(), [])
            rows = {key: [dict(row) for row in connection.execute(f'SELECT * FROM {table}')]
                    for table, key in TABLES.items()}
            self.assertEqual(table_evidence(rows), table_evidence(candidate))
            schema, _ = read_schema()
            for table, statement in zip(TABLES, schema):
                self.assertEqual(connection.execute('SELECT sql FROM sqlite_master WHERE name=?', (table,)).fetchone()[0], statement)
        self.assertEqual(manifest['baseline']['tables'], table_evidence(baseline))
        self.assertEqual(manifest['candidate']['tables'], table_evidence(candidate))
        self.assertEqual([len(candidate[key]) for key in TABLES.values()], [1, 1, 2])
        self.assertEqual([len(baseline[key]) for key in TABLES.values()], [1, 1, 1])
        self.assertEqual((self.output / 'candidate.sqlite').read_bytes()[18:20], b'\x01\x01')
        self.assertEqual(sorted(path.name for path in self.output.iterdir()),
                         ['baseline.json', 'candidate.json', 'candidate.sqlite', 'invalid.json', 'manifest.json'])

    def test_all_data_is_synthetic_text_with_empty_credentials_and_silent_reminders(self):
        manifest = generate(self.output, self.start, 17)
        for name, expected in [('baseline.json', 'only-old'), ('candidate.json', 'only-new')]:
            data = json.loads((self.output / name).read_text())
            self.assertEqual(data['settings'][0]['api_key'], '')
            self.assertEqual(data['settings'][0]['base_url'], '')
            self.assertTrue(all(row['type'] == 'text' for row in data['media_records']))
            pending = [row for row in data['reminders'] if not row['is_completed']]
            self.assertEqual([row['id'] for row in pending], [expected])
            self.assertEqual(pending[0]['quadrant_level'], 3)
            self.assertEqual(pending[0]['trigger_time'],
                             '2026-10-21T01:47:00.000Z' if name == 'baseline.json' else '2026-10-21T01:48:00.000Z')
            self.assertEqual(pending[0]['is_recurring'], 0)
            for row in data['reminders']:
                if row['is_completed']:
                    self.assertIsNone(row['trigger_time'])
        self.assertEqual(manifest['boundaries']['runtime_acceptance'], 'NOT_PERFORMED')

    def test_manifest_hashes_match_files_and_table_hashes_ignore_row_key_order(self):
        manifest = generate(self.output, self.start)
        saved = json.loads((self.output / 'manifest.json').read_text())
        self.assertEqual(set(saved['files']), {'baseline.json', 'candidate.json', 'candidate.sqlite', 'invalid.json'})
        for name, expected in saved['files'].items():
            content = (self.output / name).read_bytes()
            self.assertEqual(hashlib.sha256(content).hexdigest(), expected['sha256'])
            self.assertEqual(len(content), expected['bytes'])
        candidate = json.loads((self.output / 'candidate.json').read_text())
        reversed_data = {key: [dict(reversed(list(row.items()))) for row in reversed(candidate[key])]
                         for key in TABLES.values()}
        self.assertEqual(table_evidence(reversed_data), manifest['candidate']['tables'])

    def test_invalid_input_changes_only_boolean_value(self):
        generate(self.output, self.start)
        candidate = json.loads((self.output / 'candidate.json').read_text())
        invalid = json.loads((self.output / 'invalid.json').read_text())
        self.assertEqual(invalid['reminders'][0]['is_completed'], 2)
        invalid['reminders'][0]['is_completed'] = 0
        self.assertEqual(invalid, candidate)

    def test_existing_directory_file_and_symlink_are_never_overwritten(self):
        generate(self.output, self.start)
        before = {path.name: path.read_bytes() for path in self.output.iterdir()}
        with self.assertRaises(ValueError):
            generate(self.output, self.start)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.output.iterdir()})
        existing = Path(self.temp.name) / 'existing-file'
        existing.write_bytes(b'preserve')
        link = Path(self.temp.name) / 'link'
        link.symlink_to(self.output)
        for target in [existing, link]:
            with self.assertRaises(ValueError):
                generate(target, self.start)
        self.assertEqual(existing.read_bytes(), b'preserve')

    def test_invalid_time_due_and_non_temporary_paths_fail_before_output(self):
        for minutes in [0, -1, 1441, 1.2, True]:
            with self.assertRaises(ValueError):
                generate(self.output, self.start, minutes)
            self.assertFalse(self.output.exists())
        with self.assertRaises(ValueError):
            generate(self.output, datetime(2026, 10, 21))
        with self.assertRaises(ValueError):
            generate(ROOT / 'do-not-create-fixture-here', self.start)
        self.assertFalse((ROOT / 'do-not-create-fixture-here').exists())
        self.assertEqual(parse_start('2026-10-21T09:30:00+08:00'), self.start)
        self.assertEqual(parse_start('2026-10-21T01:30:00Z'), self.start)
        for value in ['2026-10-21T09:30:00', 'not-a-date']:
            with self.assertRaises(argparse.ArgumentTypeError):
                parse_start(value)

    def test_schema_drift_fails_before_creating_output(self):
        fake_root = Path(self.temp.name) / 'repository'
        source = fake_root / 'test/fixtures/schema_v8.sql'
        source.parent.mkdir(parents=True)
        source.write_text((ROOT / 'test/fixtures/schema_v8.sql').read_text().replace('task_title TEXT', 'changed_title TEXT'))
        with self.assertRaises(ValueError):
            generate(self.output, self.start, root=fake_root)
        self.assertFalse(self.output.exists())

    def test_cli_help_and_argument_errors_create_no_output(self):
        script = ROOT / 'scripts/generate_recovery_acceptance_fixture.py'
        help_result = subprocess.run([sys.executable, str(script), '--help'], capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0)
        self.assertIn('--start-at', help_result.stdout)
        self.assertIn('--due-minutes', help_result.stdout)
        invalid = subprocess.run([sys.executable, str(script), '--output', str(self.output),
                                  '--start-at', '2026-10-21T09:30:00'], capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
