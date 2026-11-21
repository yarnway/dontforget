#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
flutter pub get --enforce-lockfile
mkdir -p build/symbols/ios
flutter build ipa --release --no-codesign --no-pub --split-debug-info=build/symbols/ios
python3 scripts/package_artifacts.py --platform ios
