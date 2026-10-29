import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent.parent


class WindowsCIToolingTest(unittest.TestCase):
    def test_check_flutter_version_script_runs_and_reports(self):
        script = ROOT_DIR / "scripts" / "check_flutter_version.py"
        self.assertTrue(script.exists(), "check_flutter_version.py must exist")

        proc = subprocess.run(
            [sys.executable, str(script)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Current Flutter version", proc.stdout)
        self.assertIn("CI baseline Flutter ver : 3.44.9", proc.stdout)

    def test_report_windows_skipped_tests_identifies_all_skips(self):
        script = ROOT_DIR / "scripts" / "report_windows_skipped_tests.py"
        self.assertTrue(script.exists(), "report_windows_skipped_tests.py must exist")

        proc = subprocess.run(
            [sys.executable, str(script)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Total Windows-skipped tests identified:", proc.stdout)
        self.assertIn("All identified skips are verified", proc.stdout)


if __name__ == "__main__":
    unittest.main()
