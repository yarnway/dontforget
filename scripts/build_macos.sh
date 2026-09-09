#!/usr/bin/env bash
set -e

echo "============================================="
echo "  DontForget - macOS Build & Packaging"
echo "============================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"

echo "[1/3] Building Flutter macOS Release..."
flutter build macos --release

APP_PATH="$ROOT_DIR/build/macos/Build/Products/Release/dont_forget.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: macOS app bundle not found at $APP_PATH"
    exit 1
fi

echo "[2/3] Renaming bundle to display name..."
FINAL_APP="$DIST_DIR/别忘了.app"
rm -rf "$FINAL_APP"
cp -R "$APP_PATH" "$FINAL_APP"

echo "[3/3] Creating macOS portable zip archive..."
ZIP_TARGET="$DIST_DIR/DontForget_macOS_v1.0.0.zip"
rm -f "$ZIP_TARGET"
cd "$DIST_DIR"
zip -r -y "DontForget_macOS_v1.0.0.zip" "别忘了.app"

# If create-dmg is installed, create DMG as well
if command -v create-dmg &> /dev/null; then
    echo "Creating macOS DMG installer..."
    create-dmg \
      --volname "别忘了 Installer" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 100 \
      --app-drop-link 420 185 \
      "$DIST_DIR/DontForget_macOS_v1.0.0.dmg" \
      "$FINAL_APP" || true
fi

echo "[OK] macOS deliverable created: $ZIP_TARGET"
echo "============================================="
