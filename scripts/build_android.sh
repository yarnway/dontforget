#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
flutter pub get --enforce-lockfile
flutter build apk --release --no-pub
flutter build appbundle --release --no-pub
python3 scripts/package_artifacts.py --platform android
