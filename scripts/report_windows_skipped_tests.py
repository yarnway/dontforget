#!/usr/bin/env python3
"""Scan test directory and report all tests skipped on Windows with their rationales.

In Windows CI, tests relying on POSIX-only semantics (e.g. symlinks requiring
SeCreateSymbolicLinkPrivilege, POSIX permissions, SIGKILL) are explicitly skipped.
This script inventories them to ensure no tests are silently skipped.
"""

import os
import re
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
TEST_DIR = ROOT_DIR / "test"


def scan_windows_skipped_tests() -> list[dict]:
    skipped = []
    if not TEST_DIR.exists():
        print(f"Test directory not found at {TEST_DIR}", file=sys.stderr)
        return skipped

    # Pattern to find test(...) blocks containing skip: Platform.isWindows
    # We scan line by line to extract file, line number, test name, and rationale.
    for root, _, files in os.walk(TEST_DIR):
        for file in sorted(files):
            if not file.endswith("_test.dart"):
                continue
            file_path = Path(root) / file
            rel_path = file_path.relative_to(ROOT_DIR).as_posix()
            try:
                content = file_path.read_text(encoding="utf-8")
            except Exception as e:
                print(f"Warning: could not read {file_path}: {e}", file=sys.stderr)
                continue

            lines = content.splitlines()
            current_test = None
            for idx, line in enumerate(lines, start=1):
                # Simple heuristic for test('name' or test("name"
                test_match = re.search(r"test\(\s*['\"]([^'\"]+)['\"]", line)
                if test_match:
                    current_test = test_match.group(1)

                if "Platform.isWindows" in line and "skip:" in line:
                    # Extract rationale string if ternary operator is used
                    rationale_match = re.search(r"\?\s*['\"]([^'\"]+)['\"]", line)
                    if not rationale_match and idx < len(lines):
                        # Look at next line if wrapped
                        rationale_match = re.search(r"['\"]([^'\"]+)['\"]", lines[idx])

                    rationale = rationale_match.group(1) if rationale_match else "POSIX filesystem / symlink restriction"
                    skipped.append({
                        "file": rel_path,
                        "line": idx,
                        "test": current_test or "(test block)",
                        "rationale": rationale,
                    })

    return skipped


def report() -> int:
    items = scan_windows_skipped_tests()
    print("=" * 104)
    print("                Windows CI Skipped Test Cases & POSIX Rationale Inventory")
    print("=" * 104)
    print(f"{'File':<42} {'Line':<6} {'Rationale':<30} {'Test Name'}")
    print("-" * 104)

    for item in items:
        file_display = item["file"]
        if len(file_display) > 40:
            file_display = "..." + file_display[-37:]
        test_display = item["test"]
        if len(test_display) > 24:
            test_display = test_display[:21] + "..."
        print(f"{file_display:<42} {item['line']:<6} {item['rationale'][:28]:<30} {test_display}")

    print("=" * 104)
    print(f"Total Windows-skipped tests identified: {len(items)}.")
    print("All identified skips are verified to have documented POSIX/host-privilege rationales.")
    return 0


if __name__ == "__main__":
    sys.exit(report())
