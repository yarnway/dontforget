#!/usr/bin/env python3
"""Read back the public release, exact tag source, notes and every asset hash."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.request
from prepare_platform_release import Github, verify_existing_tag
from package_artifacts import digest


def verify_release(github, tag, revision, directory, notes):
    release = github.get('releases/tags/' + tag)
    if release.get('draft') is not False or release.get('prerelease') is not False or release.get('tag_name') != tag:
        raise ValueError('Release is not the requested published stable version')
    verify_existing_tag(github, tag, revision, required=True)
    if release.get('body', '').replace('\r\n', '\n').strip() != Path(notes).read_text().replace('\r\n', '\n').strip():
        raise ValueError('Published release notes differ')
    files = {p.name: p for p in Path(directory).iterdir() if p.is_file()}
    assets = release.get('assets', [])
    if len(assets) != len(files) or {a['name'] for a in assets} != set(files):
        raise ValueError('Published asset inventory differs')
    verified = []
    for asset in assets:
        file = files[asset['name']]
        expected = digest(file)
        if asset.get('state') != 'uploaded' or asset['size'] != file.stat().st_size:
            raise ValueError('Published asset size or state differs')
        remote = asset.get('digest')
        if remote is None:
            request = github.request('releases/assets/' + str(asset['id']))
            request.add_header('Accept', 'application/octet-stream')
            checksum = hashlib.sha256()
            total = 0
            with github.opener.open(request, timeout=90) as stream:
                while block := stream.read(1024 * 1024):
                    checksum.update(block)
                    total += len(block)
                    if total > asset['size']: raise ValueError('Published download exceeds expected size')
            if total != asset['size']: raise ValueError('Published download is incomplete')
            remote = 'sha256:' + checksum.hexdigest()
        if remote != 'sha256:' + expected:
            raise ValueError('Published asset checksum differs')
        verified.append({'file': file.name, 'bytes': asset['size'], 'sha256': expected})
    return {'url': release['html_url'], 'tag': tag, 'revision': revision, 'published': True,
            'prerelease': False, 'body_verified': True, 'assets': verified}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--notes', type=Path, required=True)
    args = parser.parse_args()
    receipt = verify_release(Github(os.environ.get('GH_TOKEN', '')), args.tag, args.revision, args.directory, args.notes)
    Path('published-release-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'url': receipt['url'], 'verified_assets': len(receipt['assets'])}))
