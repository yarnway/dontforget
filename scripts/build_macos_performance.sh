#!/usr/bin/env bash
set -euo pipefail
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && "$1" == "--help" ]]; then
    echo 'Usage: bash scripts/build_macos_performance.sh'
    echo 'Builds a separate macOS profile harness with an explicit single-task real OS failure probe; does not run it or touch application data.'
    echo 'The idle UI also offers focused 10000-task/768px build-layout-GC diagnostics. Instrumented timings must not be mixed with baseline profiles.'
    echo 'A separate 30-mount GC observation keeps widget profiling off and reads the timeline once after all mounts.'
    exit 0
  fi
  echo 'Unknown arguments. Use --help.' >&2
  exit 64
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'macOS with Xcode is required.' >&2
  exit 69
fi
BENCHMARK_REVISION="$(git rev-parse HEAD)"
flutter pub get --enforce-lockfile
flutter build macos --profile --no-pub --target benchmark/workspace_profile.dart --dart-define="BENCHMARK_REVISION=$BENCHMARK_REVISION"
python3 - <<'PY'
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, 'scripts')
from package_artifacts import assert_clean, digest, require, version
root = Path.cwd()
app = require(root / 'build/macos/Build/Products/Profile/dont_forget.app')
assert_clean(app)
out = root / 'dist/performance'
out.mkdir(parents=True, exist_ok=True)
archive = out / 'DontForget_macOS_profile_benchmark.zip'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
release, build = version(root)
manifest = {'version': release, 'build_number': build, 'platform': 'macos',
            'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'signing': 'not-notarized', 'build_mode': 'profile',
            'scope': 'ISOLATED_PERFORMANCE_HARNESS_NOT_PRODUCT_CANDIDATE',
            'entrypoint': 'benchmark/workspace_profile.dart',
            'native_failure_probe': 'MANUAL_SINGLE_SYNTHETIC_TASK_REAL_OS_CALLBACK_ONLY',
            'frame_diagnostics': 'OPT_IN_SELF_VM_LOOPBACK_10000_TASKS_768PX_NOT_BASELINE',
            'gc_observation': '30_MOUNTS_WIDGET_PROFILING_OFF_ONE_DEFERRED_TIMELINE_READ',
            'artifacts': [{'file': archive.name, 'bytes': archive.stat().st_size, 'sha256': digest(archive)}]}
(out / 'macos-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(out / 'macos-SHA256SUMS.txt').write_text(f"{manifest['artifacts'][0]['sha256']}  {archive.name}\n")
PY
