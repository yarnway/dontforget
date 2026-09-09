#!/usr/bin/env bash
set -e

echo "============================================="
echo "  DontForget - Android Build & Packaging"
echo "============================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/../dist"
mkdir -p "$DIST_DIR"

echo "[1/2] Building Android Release APK..."
flutter build apk --release

APK_SRC="$SCRIPT_DIR/../build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK_SRC" ]; then
    cp "$APK_SRC" "$DIST_DIR/DontForget_Android_v1.0.0.apk"
    echo "[OK] Release APK created: $DIST_DIR/DontForget_Android_v1.0.0.apk"
fi

echo "[2/2] Building Android App Bundle (AAB)..."
flutter build appbundle --release

AAB_SRC="$SCRIPT_DIR/../build/app/outputs/bundle/release/app-release.aab"
if [ -f "$AAB_SRC" ]; then
    cp "$AAB_SRC" "$DIST_DIR/DontForget_Android_v1.0.0.aab"
    echo "[OK] Release AAB created: $DIST_DIR/DontForget_Android_v1.0.0.aab"
fi

echo "============================================="
echo "Android deliverables ready in dist directory."
