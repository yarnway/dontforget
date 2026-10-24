from contextlib import closing
from datetime import datetime
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_dst_acceptance_fixture import ROOT, TABLES, generate, table_evidence
from generate_reminder_acceptance_fixture import populate_and_verify, read_schema9


class DstAcceptanceFixtureTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dontforget-dst-test-')
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / 'fixtures'

    def test_gap_and_fold_use_distinct_utc_instants_with_correct_local_offsets(self):
        result = generate(self.output)
        expected = {
            'spring': ['2026-03-08T01:59:40-08:00', '2026-03-08T03:00:20-07:00'],
            'autumn': ['2026-11-01T01:59:40-07:00', '2026-11-01T01:00:20-08:00'],
        }
        for case, local in expected.items():
            tasks = result['cases'][case]['tasks']
            self.assertEqual([t['local_time'] for t in tasks], local)
            times = [datetime.fromisoformat(t['trigger_utc'].replace('Z', '+00:00')) for t in tasks]
            self.assertEqual((times[1] - times[0]).total_seconds(), 40)
            self.assertEqual([t['fold'] for t in tasks], [0, int(case == 'autumn')])

    def test_all_backups_round_trip_through_frozen_sqlite_schema_without_credentials(self):
        result = generate(self.output)
        sql, _ = read_schema9()
        identifiers = set()
        for case, count in [('spring', 2), ('autumn', 2), ('empty', 0)]:
            path = self.output / f'{case}-v9.json'
            data = json.loads(path.read_text())
            with closing(sqlite3.connect(':memory:')) as connection:
                populate_and_verify(connection, sql, data)
                connection.row_factory = sqlite3.Row
                rows = {key: [dict(row) for row in connection.execute(f'SELECT * FROM {table}')]
                        for table, key in TABLES.items()}
                self.assertEqual(table_evidence(rows), table_evidence(data))
            self.assertEqual(len(data['reminders']), count)
            self.assertEqual(data['settings'][0]['api_key'], '')
            self.assertEqual(data['settings'][0]['base_url'], '')
            for row in data['reminders']:
                self.assertNotIn(row['id'], identifiers)
                identifiers.add(row['id'])
                self.assertEqual((row['quadrant_level'], row['is_recurring']), (3, 0))
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), result['files'][path.name]['sha256'])
        self.assertEqual(result['boundaries']['native_acceptance'], 'NOT_PERFORMED')

    def test_existing_output_is_never_replaced(self):
        generate(self.output)
        original = {p.name: p.read_bytes() for p in self.output.iterdir()}
        with self.assertRaises(ValueError):
            generate(self.output)
        self.assertEqual(original, {p.name: p.read_bytes() for p in self.output.iterdir()})

    def test_cli_help_and_unknown_arguments_do_not_write(self):
        command = [sys.executable, str(ROOT / 'scripts/generate_dst_acceptance_fixture.py')]
        help_result = subprocess.run([*command, '--help'], capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0)
        self.assertIn('NOT native delivery evidence', help_result.stdout)
        invalid = subprocess.run([*command, '--output', str(self.output), '--change-host-clock'],
                                 capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
