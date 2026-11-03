#!/usr/bin/env python3
"""Check whether the active Flutter SDK matches the repository's CI baseline (3.44.9).

The repository locks dependencies in pubspec.lock against Flutter 3.44.9.
When running with newer Flutter SDKs (e.g. 3.47.2+), the bundled SDK packages
(meta, matcher, test_api, vector_math, intl) drift from the lockfile, causing
`flutter pub get --enforce-lockfile` to report changes.
"""

import argparse
import re
import shutil
import subprocess
import sys

CI_BASELINE_FLUTTER_VERSION = "3.44.9"


def get_current_flutter_version() -> str | None:
    try:
        flutter_exe = shutil.which("flutter") or "flutter"
        result = subprocess.run(
            [flutter_exe, "--no-version-check", "--version"],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            check=True,
            timeout=30,
        )
        match = re.search(r"Flutter\s+([0-9]+\.[0-9]+\.[0-9]+)", result.stdout)
        if match:
            return match.group(1)
    except Exception as exc:
        print(f"Failed to query flutter --version: {exc}", file=sys.stderr)
    return None


def verify_flutter_version(strict: bool = False) -> int:
    current = get_current_flutter_version()
    if not current:
        print("ERROR: Flutter CLI is not available on PATH.", file=sys.stderr)
        return 1

    print(f"Current Flutter version : {current}")
    print(f"CI baseline Flutter ver : {CI_BASELINE_FLUTTER_VERSION}")

    if current == CI_BASELINE_FLUTTER_VERSION:
        print("OK: Flutter version exactly matches CI baseline. `pubspec.lock` is fully consistent.")
        return 0

    msg = (
        f"NOTICE: Local Flutter version ({current}) differs from CI baseline ({CI_BASELINE_FLUTTER_VERSION}).\n"
        f"The pubspec.lock file is strictly pinned to Flutter {CI_BASELINE_FLUTTER_VERSION}.\n"
        f"On newer Flutter versions, `flutter pub get --enforce-lockfile` may detect SDK internal package drift.\n"
        f"For packaging on newer SDKs, `scripts/package_windows.ps1` automatically resolves this via fallback.\n"
        f"To achieve 100% CI parity, please switch to Flutter {CI_BASELINE_FLUTTER_VERSION} (e.g. via FVM)."
    )
    print(msg)

    if strict:
        return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Check Flutter version against CI baseline.")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with non-zero code if current version differs from baseline.",
    )
    args = parser.parse_args()
    sys.exit(verify_flutter_version(strict=args.strict))


if __name__ == "__main__":
    main()
