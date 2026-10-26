#!/usr/bin/env python3
"""Validate package inventory, provenance and hashes; this is not runtime acceptance."""
import argparse
import json
from pathlib import Path
from package_artifacts import ROOT, digest, version

PLATFORMS = {'windows', 'android', 'linux', 'macos', 'ios'}


def verify_tag(tag, release_version, build):
    # A numbered candidate cannot be mistaken for a final stable tag.
    if tag not in {f'v{release_version}', f'v{release_version}-rc.{build}'}:
        raise ValueError('Tag does not match pubspec version and build number')


def verify(directory, expected_version, expected_build, revision, platform=None):
    directory = Path(directory)
    expected = {platform} if platform else PLATFORMS
    seen_files = set()
    for name in sorted(expected):
        manifest = json.loads((directory / f'{name}-manifest.json').read_text())
        if (manifest.get('platform'), manifest.get('version'), manifest.get('build_number'),
                manifest.get('revision')) != (name, expected_version, expected_build, revision):
            raise ValueError(f'Package identity mismatch: {name}')
        entries = manifest.get('artifacts', [])
        if len(entries) != (2 if name in {'android', 'windows'} else 1):
            raise ValueError(f'Incomplete artifact set: {name}')
        checksum_lines = []
        for entry in entries:
            filename = entry['file']
            if Path(filename).name != filename or filename in seen_files:
                raise ValueError('Unsafe or duplicated artifact filename')
            seen_files.add(filename)
            artifact = directory / filename
            if artifact.is_symlink() or not artifact.is_file():
                raise ValueError(f'Invalid artifact: {filename}')
            if artifact.stat().st_size != entry['bytes'] or digest(artifact) != entry['sha256']:
                raise ValueError(f'Artifact integrity mismatch: {filename}')
            checksum_lines.append(f"{entry['sha256']}  {filename}\n")
        if (directory / f'{name}-SHA256SUMS.txt').read_text() != ''.join(checksum_lines):
            raise ValueError(f'Checksum manifest mismatch: {name}')
    return len(seen_files)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--platform', choices=sorted(PLATFORMS))
    parser.add_argument('--revision', required=True)
    parser.add_argument('--tag', help='vVERSION or vVERSION-rc.BUILD from pubspec.yaml')
    args = parser.parse_args()
    release_version, build = version(ROOT)
    if args.tag:
        try:
            verify_tag(args.tag, release_version, build)
        except ValueError as error:
            parser.error(str(error))
    count = verify(args.directory, release_version, build, args.revision, args.platform)
    print(f'Verified {count} package files; runtime and signing acceptance are separate.')
