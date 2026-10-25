#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build_macos_dst_lab.sh --acceptance-root ABSOLUTE_DIRECTORY --output ABSOLUTE_NEW_APP

Build the isolated macOS DST acceptance controller (Apple silicon, macOS 14+).
The acceptance root must contain the existing dst-stage30-materials and
dst-stage30-share directories. Existing app bundles are never overwritten.
Building does not start, install, stop, or modify the guest.
USAGE
}

task_acceptance_root=''
task_output=''
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --acceptance-root|--output)
      if (($# < 2)) || [[ "$2" == --* ]]; then
        echo "Missing value for $1" >&2; exit 64
      fi
      case "$1" in
        --acceptance-root) task_acceptance_root="$2" ;;
        --output) task_output="$2" ;;
      esac
      shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
if [[ "$task_acceptance_root" != /* || "$task_output" != /*.app ]]; then
  usage >&2; exit 64
fi
if [[ ! -d "$task_acceptance_root/dst-stage30-materials" || ! -d "$task_acceptance_root/dst-stage30-share" ]]; then
  echo 'Acceptance materials and synthetic share directories are required.' >&2; exit 64
fi
if [[ -e "$task_output" || -L "$task_output" ]]; then
  echo 'Refusing to overwrite an existing app.' >&2; exit 64
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'This controller requires Apple silicon macOS.' >&2; exit 69
fi
task_script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
task_parent="$(dirname -- "$task_output")"
[[ -d "$task_parent" ]] || { echo 'Output parent must already exist.' >&2; exit 64; }
task_temp="$(mktemp -d "$task_parent/.dst-lab-build.XXXXXX")"
trap 'rm -rf -- "$task_temp"' EXIT
mkdir -p "$task_temp/Lab.app/Contents/MacOS"
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  "$task_script_dir/macos_dst_lab.swift" "$task_script_dir/macos_dst_storage.swift" \
  -framework Cocoa -framework Virtualization \
  -o "$task_temp/Lab.app/Contents/MacOS/DSTLab"
python3 - "$task_temp" "$task_acceptance_root" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
info = {
    'CFBundleIdentifier': 'org.dontforget.acceptance.dstlab32',
    'CFBundleName': 'DontForget DST Lab',
    'CFBundleDisplayName': 'DontForget DST Lab',
    'CFBundleExecutable': 'DSTLab',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '32',
    'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True,
    'DSTAcceptanceRoot': sys.argv[2],
}
(root / 'Lab.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
(root / 'entitlements.plist').write_bytes(plistlib.dumps({'com.apple.security.virtualization': True}))
PY
codesign --force --sign - --entitlements "$task_temp/entitlements.plist" "$task_temp/Lab.app"
codesign --verify --deep --strict "$task_temp/Lab.app"
# Publish only after compile/signature verification; never replace another bundle.
python3 - "$task_temp/Lab.app" "$task_output" <<'PY'
import ctypes, os, pathlib, sys
source, destination = map(pathlib.Path, sys.argv[1:])
rename = ctypes.CDLL(None, use_errno=True).renamex_np
rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
rename.restype = ctypes.c_int
if rename(os.fsencode(source), os.fsencode(destination), 0x00000004):  # RENAME_EXCL
    code = ctypes.get_errno()
    raise OSError(code, os.strerror(code), str(destination))
print(destination)
PY
