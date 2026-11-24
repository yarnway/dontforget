#!/usr/bin/env python3
"""Package existing native build outputs; never treat packaging as runtime acceptance."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from android_release_signing import verify_android_signatures
from android_apk_variants import requires_arm64, verify_pair

ROOT = Path(__file__).resolve().parents[1]
MACOS_ARCHITECTURES = {'arm64', 'x86_64'}
MACHO_MAGICS = {
    b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe',
    b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
    b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
    b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
}


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
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(directory.rglob('*')):
            if path.is_symlink():
                raise ValueError(f'Use the native macOS packager for symbolic links: {path}')
            if path.is_file():
                archive.write(path, str(Path(prefix) / path.relative_to(directory)))


def macos_architectures(app):
    """Check real binaries, including plugins, independently of runner CPU type."""
    entries = []
    for path in sorted(app.rglob('*')):
        # Framework aliases point to files already visited under Versions/.
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in MACHO_MAGICS:
            continue
        architectures = set(subprocess.check_output(
            ['lipo', '-archs', str(path)], text=True).split())
        relative = path.relative_to(app).as_posix()
        if not MACOS_ARCHITECTURES <= architectures:
            raise ValueError(f'macOS binary must support arm64 and x86_64: {relative}')
        entries.append({'file': relative, 'architectures': sorted(architectures)})
    if not any(entry['file'] == 'Contents/MacOS/dont_forget' for entry in entries):
        raise ValueError('macOS executable is not a verified Mach-O binary')
    return entries



def ios_extensions(app, release_version, build_number):
    """Verify the embedded extension versions, identities and extension points."""
    host = plistlib.loads(require(app / 'Info.plist').read_bytes())
    for key, expected in [('CFBundleShortVersionString', release_version),
                          ('CFBundleVersion', build_number)]:
        if host.get(key) != expected:
            raise ValueError(f'iOS host version mismatch: {key}')
    results = []
    for target, point in (('ReminderActivity', 'com.apple.widgetkit-extension'),
                          ('ShareExtension', 'com.apple.share-services')):
        bundle = f'PlugIns/{target}.appex'
        extension = require(app / bundle)
        info = plistlib.loads(require(extension / 'Info.plist').read_bytes())
        if any(info.get(key) != host.get(key) for key in ('CFBundleShortVersionString', 'CFBundleVersion')):
            raise ValueError(f'iOS {target} version mismatch')
        if info.get('CFBundleIdentifier') != host.get('CFBundleIdentifier', '') + '.' + target:
            raise ValueError(f'iOS {target} must belong to the host bundle')
        if info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != point:
            raise ValueError(f'iOS {target} extension point mismatch')
        if target == 'ShareExtension':
            validate_ios_share_group(host, info)
        executable = info.get('CFBundleExecutable')
        if not isinstance(executable, str) or executable in ('', '.', '..') or Path(executable).name != executable:
            raise ValueError(f'iOS {target} executable name is invalid')
        require(extension / executable)
        results.append({'bundle': bundle, 'version': release_version, 'build_number': build_number,
                        'extension_point': point})
    return results


def validate_ios_share_group(host, share):
    identity = host.get('CFBundleIdentifier', '')
    expected = 'group.' + identity
    if not identity or host.get('DontForgetShareGroup') != expected or share.get('DontForgetShareGroup') != expected:
        raise ValueError('iOS share group must match the host bundle')
    return expected


def embed_ios_share_entitlements(app, staging):
    """Carry the group request to personal re-signers using certificate-free signatures."""
    extension = app / 'PlugIns/ShareExtension.appex'
    host = plistlib.loads((app / 'Info.plist').read_bytes())
    share = plistlib.loads((extension / 'Info.plist').read_bytes())
    request = {'com.apple.security.application-groups': [validate_ios_share_group(host, share)]}
    entitlements = staging / 'share-entitlements.plist'
    entitlements.write_bytes(plistlib.dumps(request))

    nested = (path for path in app.rglob('*') if not path.is_symlink() and
              path.suffix in ('.framework', '.dylib', '.appex'))
    for path in [*sorted(nested, key=lambda child: (-len(child.parts), child.as_posix())), app]:
        args = ['--entitlements', str(entitlements)] if path in (app, extension) else []
        subprocess.run(['codesign', '--force', '--sign', '-', *args, str(path)], check=True)
        if args:
            result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)],
                                    check=True, capture_output=True)
            if plistlib.loads(result.stdout) != request:
                raise ValueError('iOS share entitlement request was not embedded')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def package(root, platform, revision=None):
    root = Path(root).resolve()
    release_version, build_number = version(root)
    dist = root / 'dist'
    dist.mkdir(exist_ok=True)
    revision = revision or subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    names = []
    signing = 'not-applicable'
    native_architectures = None
    native_extensions = None
    android_certificate = None
    android_variants = None
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
            distribution = os.environ.get('DONTFORGET_REQUIRE_RELEASE_SIGNING') == '1'
            apk = require(root / 'build/app/outputs/flutter-apk/app-release.apk')
            aab = require(root / 'build/app/outputs/bundle/release/app-release.aab')
            arm64 = None
            if requires_arm64(release_version):
                arm64 = require(root / 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk')
                android_variants = verify_pair(apk, arm64)
            if distribution:
                android_certificate = verify_android_signatures(
                    apk, aab, os.environ.get('DONTFORGET_ANDROID_CERT_SHA256', ''),
                    **({'additional_apks': [arm64]} if arm64 else {}),
                )
            label = '' if distribution else '_test-signed'
            sources = {f'DontForget_Android{label}_v{release_version}.apk': apk,
                       f'DontForget_Android{label}_v{release_version}.aab': aab}
            if arm64:
                sources[f'DontForget_Android_arm64{label}_v{release_version}.apk'] = arm64
            for name, source in sources.items():
                shutil.copy2(source, staging / name)
                names.append(name)
            signing = 'release-key' if distribution else 'test-key'
        elif platform == 'linux':
            bundle = require(root / 'build/linux/x64/release/bundle')
            require(bundle / 'dont_forget')
            require(bundle / 'lib/libflutter_linux_gtk.so')
            require(bundle / 'data/flutter_assets')
            assert_clean(bundle)
            name = f'DontForget_Linux_x64_v{release_version}.tar.gz'
            with tarfile.open(staging / name, 'w:gz', compresslevel=9) as archive:
                for path in sorted(bundle.iterdir()):
                    archive.add(path, arcname=path.name)
            names.append(name)
        elif platform == 'macos':
            app = require(root / 'build/macos/Build/Products/Release/dont_forget.app')
            require(app / 'Contents/MacOS/dont_forget')
            assert_clean(app)
            native_architectures = macos_architectures(app)
            name = f'DontForget_macOS_unnotarized_v{release_version}.zip'
            subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                            str(app), str(staging / name)], check=True)
            names.append(name)
            signing = 'not-notarized'
        elif platform == 'ios':
            app = require(root / 'build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app')
            require(app / 'Runner')
            native_extensions = ios_extensions(app, release_version, build_number)
            assert_clean(app)
            payload = staging / 'Payload'
            payload.mkdir()
            shutil.copytree(app, payload / app.name, symlinks=True)
            embed_ios_share_entitlements(payload / app.name, staging)
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
    if android_variants is not None:
        manifest['android_variants'] = android_variants
    if native_extensions is not None:
        manifest['native_extensions'] = native_extensions
    if android_certificate is not None:
        manifest['certificate_sha256'] = android_certificate
    if native_architectures is not None:
        manifest['native_architectures'] = native_architectures
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
