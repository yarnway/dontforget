#!/usr/bin/env python3
"""准备具有独立沙箱和通知身份的 iOS 派生验收工程；支持自动化改写与还原。"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sys


ORIGINAL_ID = 'com.yarnway.dontforget'
ACCEPTANCE_PREFIX = ORIGINAL_ID + '.acceptance.'
ORIGINAL_DISPLAY_NAME = '别忘了'


def sha256(data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    return hashlib.sha256(data).hexdigest()


def validate_run_id(value):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,47}', value):
        raise ValueError('run ID 必须为 1–48 个小写字母、数字或连字符，首位不能是连字符')
    return value


def rewrite_pbxproj(content, run_id):
    validate_run_id(run_id)
    acceptance_base = f'{ACCEPTANCE_PREFIX}{run_id}'

    # First revert any existing acceptance prefix to avoid nesting
    content = revert_pbxproj(content)

    # 1. Main host bundle identifier
    content = re.sub(
        r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*' + re.escape(ORIGINAL_ID) + r';',
        f'PRODUCT_BUNDLE_IDENTIFIER = {acceptance_base};',
        content,
    )
    # 2. ReminderActivity widget extension
    content = re.sub(
        r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*' + re.escape(f'{ORIGINAL_ID}.ReminderActivity') + r';',
        f'PRODUCT_BUNDLE_IDENTIFIER = {acceptance_base}.ReminderActivity;',
        content,
    )
    # 3. RunnerTests target
    content = re.sub(
        r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*' + re.escape(f'{ORIGINAL_ID}.RunnerTests') + r';',
        f'PRODUCT_BUNDLE_IDENTIFIER = {acceptance_base}.RunnerTests;',
        content,
    )
    return content


def revert_pbxproj(content):
    # Match any acceptance pattern with optional target suffix
    pattern = (
        r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*'
        + re.escape(ACCEPTANCE_PREFIX)
        + r'[a-z0-9-]+(\.[A-Za-z0-9_-]+)?;'
    )

    def _replace(match):
        suffix = match.group(1) or ''
        return f'PRODUCT_BUNDLE_IDENTIFIER = {ORIGINAL_ID}{suffix};'

    return re.sub(pattern, _replace, content)


def rewrite_info_plist(plist_bytes, run_id):
    validate_run_id(run_id)
    data = plistlib.loads(plist_bytes)
    data['CFBundleDisplayName'] = f'{ORIGINAL_DISPLAY_NAME}·验收 {run_id}'

    # Handle URL schemes
    url_types = data.get('CFBundleURLTypes', [])
    live_scheme = f'dontforget-live-{run_id}'
    found = False
    for entry in url_types:
        schemes = entry.get('CFBundleURLSchemes', [])
        if any(s.startswith('dontforget') for s in schemes):
            # Clean old acceptance schemes and add current
            schemes = [s for s in schemes if not re.match(r'^dontforget-live-[a-z0-9-]+$', s)]
            if 'dontforget' not in schemes:
                schemes.append('dontforget')
            if 'dontforget-live' not in schemes:
                schemes.append('dontforget-live')
            if live_scheme not in schemes:
                schemes.append(live_scheme)
            entry['CFBundleURLSchemes'] = schemes
            found = True
            break
    if not found:
        url_types.append({'CFBundleURLSchemes': ['dontforget', 'dontforget-live', live_scheme]})
    data['CFBundleURLTypes'] = url_types
    return plistlib.dumps(data)


def revert_info_plist(plist_bytes):
    data = plistlib.loads(plist_bytes)
    data['CFBundleDisplayName'] = ORIGINAL_DISPLAY_NAME
    url_types = data.get('CFBundleURLTypes', [])
    for entry in url_types:
        schemes = entry.get('CFBundleURLSchemes', [])
        cleaned = [s for s in schemes if not re.match(r'^dontforget-live-[a-z0-9-]+$', s)]
        entry['CFBundleURLSchemes'] = cleaned
    data['CFBundleURLTypes'] = url_types
    return plistlib.dumps(data)


def prepare(root, run_id, dry_run=False):
    root = Path(root).resolve()
    pbxproj_path = root / 'ios/Runner.xcodeproj/project.pbxproj'
    plist_path = root / 'ios/Runner/Info.plist'

    if not pbxproj_path.is_file() or not plist_path.is_file():
        raise FileNotFoundError(f'iOS 工程文件未在路径中找到: {root}')

    old_pbxproj = pbxproj_path.read_text(encoding='utf-8')
    new_pbxproj = rewrite_pbxproj(old_pbxproj, run_id)

    old_plist = plist_path.read_bytes()
    new_plist = rewrite_info_plist(old_plist, run_id)

    host_bundle_id = f'{ACCEPTANCE_PREFIX}{run_id}'
    widget_bundle_id = f'{host_bundle_id}.ReminderActivity'

    report = {
        'schema': 1,
        'action': 'prepare',
        'run_id': run_id,
        'host_bundle_id': host_bundle_id,
        'widget_bundle_id': widget_bundle_id,
        'dry_run': dry_run,
        'files': {
            'project.pbxproj': {
                'original_sha256': sha256(old_pbxproj),
                'prepared_sha256': sha256(new_pbxproj),
                'changed': old_pbxproj != new_pbxproj,
            },
            'Info.plist': {
                'original_sha256': sha256(old_plist),
                'prepared_sha256': sha256(new_plist),
                'changed': old_plist != new_plist,
            },
        },
    }

    if not dry_run:
        pbxproj_path.write_text(new_pbxproj, encoding='utf-8')
        plist_path.write_bytes(new_plist)

    return report


def revert(root, dry_run=False):
    root = Path(root).resolve()
    pbxproj_path = root / 'ios/Runner.xcodeproj/project.pbxproj'
    plist_path = root / 'ios/Runner/Info.plist'

    if not pbxproj_path.is_file() or not plist_path.is_file():
        raise FileNotFoundError(f'iOS 工程文件未在路径中找到: {root}')

    old_pbxproj = pbxproj_path.read_text(encoding='utf-8')
    new_pbxproj = revert_pbxproj(old_pbxproj)

    old_plist = plist_path.read_bytes()
    new_plist = revert_info_plist(old_plist)

    report = {
        'schema': 1,
        'action': 'revert',
        'dry_run': dry_run,
        'files': {
            'project.pbxproj': {
                'reverted_sha256': sha256(new_pbxproj),
                'changed': old_pbxproj != new_pbxproj,
            },
            'Info.plist': {
                'reverted_sha256': sha256(new_plist),
                'changed': old_plist != new_plist,
            },
        },
    }

    if not dry_run:
        pbxproj_path.write_text(new_pbxproj, encoding='utf-8')
        plist_path.write_bytes(new_plist)

    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1],
                        help='仓库根目录 (默认根据脚本位置解析)')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--run-id', type=str, help='验收 run ID (小写字母/数字/连字符，1–48位)')
    group.add_argument('--revert', action='store_true', help='还原工程身份至基线状态')
    parser.add_argument('--dry-run', action='store_true', help='仅计算变更而不写盘')

    args = parser.parse_args(argv)

    try:
        if args.revert:
            result = revert(args.root, dry_run=args.dry_run)
            action_desc = 'Reverted'
        else:
            result = prepare(args.root, args.run_id, dry_run=args.dry_run)
            action_desc = f'Prepared acceptance {result["host_bundle_id"]}'

        print(json.dumps(result, ensure_ascii=False, indent=2))
        print(f'{action_desc} (dry_run={args.dry_run})')
        return 0
    except Exception as error:
        print(f'Error: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
