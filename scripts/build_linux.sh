#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
flutter pub get --enforce-lockfile
mkdir -p build/symbols/linux
rm -rf build/flutter_assets build/linux/x64/release/bundle/data/flutter_assets
flutter build linux --release --no-pub --split-debug-info=build/symbols/linux
# Work around Flutter 3.44.9 tool_backend.dart quoting -dTreeShakeIcons="true"
# which silently disables MaterialIcons tree-shaking on desktop builds.
SHAKE_OUT="build/linux/tree_shaken_assets"
rm -rf "$SHAKE_OUT"
flutter --no-version-check assemble \
  --output="$SHAKE_OUT" \
  -dTargetPlatform=linux-x64 \
  -dBuildMode=release \
  -dTargetFile=lib/main.dart \
  -dTreeShakeIcons=true \
  release_bundle_linux-x64_assets
SHAKEN_FONT="$SHAKE_OUT/flutter_assets/fonts/MaterialIcons-Regular.otf"
TARGET_FONT="build/linux/x64/release/bundle/data/flutter_assets/fonts/MaterialIcons-Regular.otf"
test -s "$SHAKEN_FONT"
SHAKEN_SIZE=$(wc -c < "$SHAKEN_FONT")
if [ "$SHAKEN_SIZE" -ge 200000 ]; then
  echo "MaterialIcons font was not tree-shaken ($SHAKEN_SIZE bytes)" >&2
  exit 1
fi
cp -f "$SHAKEN_FONT" "$TARGET_FONT"
rm -rf "$SHAKE_OUT"
# Drop Android-only dartjni shim if present and unreferenced by NativeAssetsManifest.json.
DARTJNI="build/linux/x64/release/bundle/lib/libdartjni.so"
MANIFEST="build/linux/x64/release/bundle/data/flutter_assets/NativeAssetsManifest.json"
if [ -f "$DARTJNI" ] && ! grep -q "libdartjni.so" "$MANIFEST" 2>/dev/null; then
  rm -f "$DARTJNI"
fi
# Drop Windows-only tray ICO and Web-only record_web JS assets from Linux bundle.
rm -f build/linux/x64/release/bundle/data/flutter_assets/assets/app_icon.ico
rm -rf build/linux/x64/release/bundle/data/flutter_assets/packages/record_web
rmdir build/linux/x64/release/bundle/data/flutter_assets/packages 2>/dev/null || true
python3 scripts/package_artifacts.py --platform linux
