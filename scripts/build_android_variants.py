#!/usr/bin/env python3
"""Build universal APK, ARM64 APK and AAB without overwriting the universal output."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from android_apk_variants import verify_pair
from package_artifacts import ROOT, version


def metadata(apk, environment):
    sdk = environment.get('ANDROID_SDK_ROOT') or environment.get('ANDROID_HOME')
    tools = list((Path(sdk) / 'build-tools').glob('*/aapt' + ('.exe' if os.name == 'nt' else ''))) if sdk else []
    tools = [p for p in tools if re.fullmatch(r'\d+\.\d+\.\d+', p.parent.name)]
    if not tools:
        raise ValueError('Android SDK metadata verifier is required')
    tool = next((p for p in tools if p.parent.name == '36.0.0'),
                max(tools, key=lambda p: tuple(map(int, p.parent.name.split('.')))))
    output = subprocess.check_output([str(tool), 'dump', 'badging', str(apk)],
                                     env=environment, text=True, timeout=60)
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", output, re.M)
    sdk_match = re.search(r"^sdkVersion:'(\d+)'", output, re.M)
    if not package or not sdk_match:
        raise ValueError('APK metadata is incomplete')
    return (*package.groups(), sdk_match.group(1))


def build(root=ROOT, disable_kotlin_incremental=False):
    root = Path(root).resolve()
    release, number = version(root)
    output = root / 'build/app/outputs/flutter-apk'
    bundle = root / 'build/app/outputs/bundle/release/app-release.aab'
    root.joinpath('build').mkdir(exist_ok=True)
    flutter = shutil.which('flutter')
    if not flutter:
        raise ValueError('Flutter SDK is required')
    common = ['--release', '--no-pub']
    if disable_kotlin_incremental:
        common += ['--android-project-arg=kotlin.incremental=false']
    def run(kind, extra=()):
        subprocess.run([flutter, '--no-version-check', 'build', kind, *common, *extra],
                       cwd=root, check=True)
    (output / 'app-arm64-v8a-release.apk').unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix='android-variants-', dir=root / 'build') as directory:
        staging = Path(directory)
        run('apk')
        shutil.copy2(output / 'app-release.apk', staging / 'universal.apk')
        try:
            run('apk', ['--target-platform=android-arm64'])
            shutil.copy2(output / 'app-release.apk', staging / 'arm64.apk')
            verify_pair(staging / 'universal.apk', staging / 'arm64.apk')
            expected = ('com.yarnway.dontforget', number, release, '24')
            for name in ('universal.apk', 'arm64.apk'):
                if metadata(staging / name, os.environ) != expected:
                    raise ValueError('APK package, version or minimum SDK mismatch')
            run('appbundle')
            if not bundle.is_file():
                raise FileNotFoundError('Missing Android App Bundle')
            shutil.copy2(staging / 'arm64.apk', output / 'app-arm64-v8a-release.apk')
        finally:
            shutil.copy2(staging / 'universal.apk', output / 'app-release.apk')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disable-kotlin-incremental', action='store_true')
    args = parser.parse_args()
    build(disable_kotlin_incremental=args.disable_kotlin_incremental)
