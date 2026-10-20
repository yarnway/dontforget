#!/usr/bin/env python3
"""Package existing native build outputs; never treat packaging as runtime acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def version(root):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                      (root / 'pubspec.yaml').read_text(), re.M)
    if not match:
        raise ValueError('pubspec.yaml must contain a semantic version and build number')
    return match.group(1), match.group(2)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def require(path):
    if not path.exists():
        raise FileNotFoundError(f'Missing native build output: {path}')
    return path


def assert_clean(directory):
    for path in directory.rglob('*'):
        if (path.name in {'.dart_tool', 'ha_snapshot.json'} or
                path.suffix.lower() in {'.db', '.sqlite', '.sqlite3', '.log'} or
                path.name.endswith(('-wal', '-shm'))):
            raise ValueError(f'Private/runtime data in build output: {path}')


def zip_tree(directory, target, prefix=''):
    assert_clean(directory)
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(directory.rglob('*')):
            if path.is_symlink():
                raise ValueError(f'Use the native macOS packager for symbolic links: {path}')
            if path.is_file():
                archive.write(path, str(Path(prefix) / path.relative_to(directory)))


def package(root, platform, revision=None):
    root = Path(root).resolve()
    release_version, build_number = version(root)
    dist = root / 'dist'
    dist.mkdir(exist_ok=True)
    revision = revision or subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    names = []
    signing = 'not-applicable'
    with tempfile.TemporaryDirectory(prefix=f'{platform}-', dir=dist) as work:
        staging = Path(work)
        if platform == 'windows':
            bundle = require(root / 'build/windows/x64/runner/Release')
            require(bundle / 'dont_forget.exe')
            require(bundle / 'flutter_windows.dll')
            require(bundle / 'data/flutter_assets')
            setup_name = f'DontForget_Setup_v{release_version}.exe'
            require(dist / setup_name)
            names.append(setup_name)
            archive_name = f'DontForget_Windows_Portable_v{release_version}.zip'
            zip_tree(bundle, staging / archive_name)
            names.append(archive_name)
            signing = 'unsigned'
        elif platform == 'android':
            # The repository deliberately uses the Android debug signing key.
            # These artifacts are for acceptance testing, not store distribution.
            for extension, source in {
                'apk': 'build/app/outputs/flutter-apk/app-release.apk',
                'aab': 'build/app/outputs/bundle/release/app-release.aab',
            }.items():
                name = f'DontForget_Android_test-signed_v{release_version}.{extension}'
                shutil.copy2(require(root / source), staging / name)
                names.append(name)
            signing = 'test-key'
        elif platform == 'linux':
            bundle = require(root / 'build/linux/x64/release/bundle')
            require(bundle / 'dont_forget')
            require(bundle / 'lib/libflutter_linux_gtk.so')
            require(bundle / 'data/flutter_assets')
            assert_clean(bundle)
            name = f'DontForget_Linux_x64_v{release_version}.tar.gz'
            with tarfile.open(staging / name, 'w:gz') as archive:
                for path in sorted(bundle.iterdir()):
                    archive.add(path, arcname=path.name)
            names.append(name)
        elif platform == 'macos':
            app = require(root / 'build/macos/Build/Products/Release/dont_forget.app')
            require(app / 'Contents/MacOS/dont_forget')
            assert_clean(app)
            name = f'DontForget_macOS_unnotarized_v{release_version}.zip'
            subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                            str(app), str(staging / name)], check=True)
            names.append(name)
            signing = 'not-notarized'
        elif platform == 'ios':
            app = require(root / 'build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app')
            require(app / 'Runner')
            assert_clean(app)
            payload = staging / 'Payload'
            payload.mkdir()
            shutil.copytree(app, payload / app.name, symlinks=True)
            name = f'DontForget_iOS_unsigned_v{release_version}.ipa'
            subprocess.run(['ditto', '-c', '-k', '--keepParent', str(payload),
                            str(staging / name)], check=True)
            names.append(name)
            signing = 'unsigned'
        else:
            raise ValueError(f'Unsupported platform: {platform}')
        # Do not publish partial output if packaging failed.
        for name in names:
            if (staging / name).exists():
                os.replace(staging / name, dist / name)

    entries = []
    for name in names:
        path = dist / name
        entries.append({'file': name, 'bytes': path.stat().st_size,
                        'sha256': digest(path)})
    manifest = {
        'version': release_version, 'build_number': build_number,
        'revision': revision, 'platform': platform, 'signing': signing,
        'runtime_acceptance': 'NOT_PERFORMED', 'artifacts': entries,
    }
    manifest_path = dist / f'{platform}-manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    (dist / f'{platform}-SHA256SUMS.txt').write_text(''.join(
        f"{entry['sha256']}  {entry['file']}\n" for entry in entries))
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['windows', 'android', 'linux', 'macos', 'ios'])
    parser.add_argument('--version-only', action='store_true')
    parser.add_argument('--check-clean', type=Path)
    args = parser.parse_args()
    if args.check_clean:
        assert_clean(require(args.check_clean))
    elif args.version_only:
        print(version(ROOT)[0])
    elif args.platform:
        print(json.dumps(package(ROOT, args.platform), indent=2))
    else:
        parser.error('--platform or --version-only is required')
