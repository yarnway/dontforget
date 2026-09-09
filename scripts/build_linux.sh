#!/usr/bin/env bash
set -e

echo "============================================="
echo "  DontForget - Linux Build & Packaging"
echo "============================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"

echo "[1/3] Building Flutter Linux Release..."
flutter build linux --release

RELEASE_DIR="$ROOT_DIR/build/linux/x64/release/bundle"

if [ ! -d "$RELEASE_DIR" ]; then
    echo "Error: Release directory not found at $RELEASE_DIR"
    exit 1
fi

echo "[2/3] Cleaning dev cache and logs..."
rm -f "$RELEASE_DIR"/*.log "$RELEASE_DIR"/error_log.txt "$RELEASE_DIR"/*.db
rm -rf "$RELEASE_DIR/.dart_tool"

echo "[3/3] Creating Linux portable tarball archive..."
TAR_TARGET="$DIST_DIR/DontForget_Linux_x64_v1.0.0.tar.gz"
tar -czf "$TAR_TARGET" -C "$RELEASE_DIR" .

echo "[OK] Linux deliverable created: $TAR_TARGET"
echo "============================================="
