import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_flutter_version

ROOT_DIR = Path(__file__).resolve().parent.parent.parent


class WindowsCIToolingTest(unittest.TestCase):
    def test_strict_version_check_rejects_drift_and_missing_sdk(self):
        for current, strict, expected in [
            ("3.44.9", True, 0),
            ("3.47.2", True, 1),
            ("3.47.2", False, 0),
            (None, True, 1),
        ]:
            with self.subTest(current=current, strict=strict), patch.object(
                check_flutter_version, "get_current_flutter_version", return_value=current
            ):
                self.assertEqual(check_flutter_version.verify_flutter_version(strict), expected)

    def test_local_sdk_query_is_bounded_and_skips_remote_update_check(self):
        with patch.object(check_flutter_version.shutil, "which", return_value="flutter"), patch.object(
            check_flutter_version.subprocess, "run",
            return_value=subprocess.CompletedProcess([], 0, stdout="Flutter 3.44.9"),
        ) as run:
            self.assertEqual(check_flutter_version.get_current_flutter_version(), "3.44.9")
            self.assertEqual(run.call_args.args[0], ["flutter", "--no-version-check", "--version"])
            self.assertEqual(run.call_args.kwargs["timeout"], 30)

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
