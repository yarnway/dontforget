#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
flutter pub get --enforce-lockfile
share_test="$(mktemp -d)"
trap 'rm -f "$share_test/share-test"; rmdir "$share_test"' EXIT
xcrun swiftc -swift-version 5 ios/Shared/ShareHandoff.swift scripts/tests/ios_share_handoff_smoke.swift -o "$share_test/share-test"
"$share_test/share-test"
mkdir -p build/symbols/ios
flutter build ipa --release --no-codesign --no-pub --split-debug-info=build/symbols/ios
python3 scripts/package_artifacts.py --platform ios
