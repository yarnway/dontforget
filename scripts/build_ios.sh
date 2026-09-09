#!/usr/bin/env bash
set -e

echo "============================================="
echo "  DontForget - iOS Build & Packaging"
echo "============================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"

echo "[1/2] Building Flutter iOS Release..."
flutter build ipa --release --no-codesign

IPA_DIR="$ROOT_DIR/build/ios/archive/Runner.xcarchive"
OUTPUT_IPA="$DIST_DIR/DontForget_iOS_v1.0.0.ipa"

if [ -d "$IPA_DIR" ]; then
    echo "[2/2] Packaging xcarchive into IPA structure..."
    PAYLOAD_DIR="$DIST_DIR/Payload"
    rm -rf "$PAYLOAD_DIR"
    mkdir -p "$PAYLOAD_DIR"
    cp -R "$IPA_DIR/Products/Applications/Runner.app" "$PAYLOAD_DIR/"
    cd "$DIST_DIR"
    zip -r -y "$OUTPUT_IPA" Payload
    rm -rf "$PAYLOAD_DIR"
    echo "[OK] iOS package created: $OUTPUT_IPA"
else
    echo "Notice: xcarchive generated at $ROOT_DIR/build/ios/archive"
fi

echo "============================================="
