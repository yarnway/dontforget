#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
flutter pub get --enforce-lockfile
mkdir -p build/symbols/macos
flutter build macos --release --no-pub --split-debug-info=build/symbols/macos
python3 scripts/package_artifacts.py --platform macos
