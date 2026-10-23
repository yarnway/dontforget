#!/usr/bin/env bash
set -euo pipefail
RETRY_TRACE_ENABLED=false
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && "$1" == "--help" ]]; then
    echo 'Usage: bash scripts/build_macos_startup_measurement.sh [--retry-trace]'
    echo 'Builds the release product entrypoint with passive startup markers. Reports require an isolated acceptance container. Does not launch or seed data.'
    echo '--retry-trace also observes real foreground retries and pending IDs; writes dist/retry. Ordinary startup builds write dist/startup without retry tracing.'
    exit 0
  elif [[ $# -eq 1 && "$1" == "--retry-trace" ]]; then
    RETRY_TRACE_ENABLED=true
  else
    echo 'Unknown arguments. Use --help.' >&2
    exit 64
  fi
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'macOS with Xcode is required.' >&2
  exit 69
fi
STARTUP_REVISION="$(git rev-parse HEAD)"
flutter pub get --enforce-lockfile
flutter build macos --release --no-pub --target lib/main.dart --dart-define=DONTFORGET_STARTUP_TRACE=true --dart-define="DONTFORGET_RETRY_TRACE=$RETRY_TRACE_ENABLED" --dart-define="BENCHMARK_REVISION=$STARTUP_REVISION"
RETRY_TRACE_ENABLED="$RETRY_TRACE_ENABLED" python3 - <<'PY'
import json, os
from pathlib import Path
import subprocess, sys
sys.path.insert(0, 'scripts')
from package_artifacts import assert_clean, digest, require, version
root = Path.cwd()
app = require(root / 'build/macos/Build/Products/Release/dont_forget.app')
assert_clean(app)
retry = os.environ['RETRY_TRACE_ENABLED'] == 'true'
out = root / ('dist/retry' if retry else 'dist/startup')
out.mkdir(parents=True, exist_ok=True)
archive = out / ('DontForget_macOS_retry_measurement.zip' if retry else 'DontForget_macOS_startup_measurement.zip')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
release, build = version(root)
manifest = {'version': release, 'build_number': build, 'platform': 'macos',
            'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'signing': 'not-notarized', 'build_mode': 'release',
            'scope': 'PRODUCT_ENTRYPOINT_WITH_PASSIVE_RETRY_TRACE' if retry else 'PRODUCT_ENTRYPOINT_WITH_PASSIVE_STARTUP_TRACE',
            'entrypoint': 'lib/main.dart', 'native_transport': 'real',
            'artifacts': [{'file': archive.name, 'bytes': archive.stat().st_size, 'sha256': digest(archive)}]}
(out / 'macos-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(out / 'macos-SHA256SUMS.txt').write_text(f"{manifest['artifacts'][0]['sha256']}  {archive.name}\n")
PY
