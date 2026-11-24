#!/usr/bin/env python3
"""Copy only transitively-imported MSVC CRT DLLs and prune unused desktop native shims."""
import argparse
import json
from pathlib import Path
import shutil
import struct


CRT_PREFIXES = ('msvcp', 'vcruntime', 'concrt', 'vccorlib')


def pe_imports(path: Path) -> set[str]:
    """Return lowercase DLL names from a Windows PE (x86/x64) import table."""
    data = path.read_bytes()
    if len(data) < 0x40 or data[:2] != b'MZ':
        return set()
    pe_off = struct.unpack_from('<I', data, 0x3C)[0]
    if pe_off + 24 > len(data) or data[pe_off:pe_off + 4] != b'PE\0\0':
        return set()
    num_sections = struct.unpack_from('<H', data, pe_off + 6)[0]
    opt_size = struct.unpack_from('<H', data, pe_off + 20)[0]
    opt_off = pe_off + 24
    if opt_off + opt_size > len(data) or opt_size < 2:
        return set()
    magic = struct.unpack_from('<H', data, opt_off)[0]
    # PE32+ (0x20B) data directories start at +112; PE32 (0x10B) at +96.
    dd_off = opt_off + (112 if magic == 0x20B else 96)
    if dd_off + 16 > len(data):
        return set()
    import_rva, _ = struct.unpack_from('<II', data, dd_off + 8)
    if import_rva == 0:
        return set()
    sec_off = opt_off + opt_size
    sections = []
    for i in range(num_sections):
        s = sec_off + i * 40
        if s + 40 > len(data):
            break
        vsz, vrva, rsz, rptr = struct.unpack_from('<IIII', data, s + 8)
        sections.append((vrva, max(vsz, rsz), rptr))

    def rva_to_offset(rva: int) -> int | None:
        for vrva, sz, rptr in sections:
            if vrva <= rva < vrva + sz:
                return rptr + (rva - vrva)
        return None

    off = rva_to_offset(import_rva)
    if off is None:
        return set()
    imports: set[str] = set()
    while off + 20 <= len(data):
        orig, ts, fwd, name_rva, ft = struct.unpack_from('<IIIII', data, off)
        if not (orig or ts or fwd or name_rva or ft):
            break
        name_off = rva_to_offset(name_rva)
        if name_off is not None:
            end = data.find(b'\0', name_off)
            if end != -1:
                imports.add(data[name_off:end].decode('ascii', errors='replace').lower())
        off += 20
    return imports


def _native_asset_filenames(release_dir: Path) -> set[str]:
    manifest = release_dir / 'data' / 'flutter_assets' / 'NativeAssetsManifest.json'
    if not manifest.is_file():
        return set()
    try:
        parsed = json.loads(manifest.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return set()
    names: set[str] = set()
    assets = parsed.get('native-assets', {})
    if isinstance(assets, dict):
        for target_map in assets.values():
            if isinstance(target_map, dict):
                for entry in target_map.values():
                    if isinstance(entry, list) and len(entry) >= 2 and isinstance(entry[1], str):
                        names.add(Path(entry[1]).name.lower())
    return names


def prune_and_stage_crt(release_dir: Path, redist_dir: Path) -> dict:
    """Prune unused dartjni.dll & stage only transitively-imported MSVC CRT DLLs."""
    release_dir = release_dir.resolve()
    redist_dir = redist_dir.resolve()
    if not release_dir.is_dir():
        raise FileNotFoundError(f'Missing Windows release dir: {release_dir}')
    if not redist_dir.is_dir():
        raise FileNotFoundError(f'Missing VC redist dir: {redist_dir}')

    redist_map = {
        p.name.lower(): p
        for p in redist_dir.iterdir()
        if p.is_file() and p.suffix.lower() == '.dll'
    }
    if not redist_map:
        raise ValueError(f'No redistributable DLLs found in {redist_dir}')

    native_assets = _native_asset_filenames(release_dir)

    # First remove stale CRT DLLs from any earlier incremental packaging run.
    removed_stale_crt: list[str] = []
    for p in list(release_dir.iterdir()):
        if not p.is_file():
            continue
        low = p.name.lower()
        if low.endswith('.dll') and (low in redist_map or low.startswith(CRT_PREFIXES)):
            p.unlink()
            removed_stale_crt.append(p.name)

    # Scan all remaining app/plugin binaries.
    app_binaries = {
        p.name.lower(): p
        for p in release_dir.iterdir()
        if p.is_file() and p.suffix.lower() in ('.exe', '.dll')
    }
    if 'dont_forget.exe' not in app_binaries or 'flutter_windows.dll' not in app_binaries:
        raise FileNotFoundError('Windows release directory is missing core binaries')

    # Drop Android-only dartjni.dll on Windows when nothing imports it and it is
    # absent from NativeAssetsManifest.json.
    removed_unused_shims: list[str] = []
    if 'dartjni.dll' in app_binaries and 'dartjni.dll' not in native_assets:
        other_imports: set[str] = set()
        for name, path in app_binaries.items():
            if name != 'dartjni.dll':
                other_imports |= pe_imports(path)
        if 'dartjni.dll' not in other_imports:
            app_binaries.pop('dartjni.dll').unlink()
            removed_unused_shims.append('dartjni.dll')

    # Compute exact transitive CRT closure imported by app binaries.
    needed_crt: set[str] = set()
    missing_crt: set[str] = set()
    queue: list[Path] = list(app_binaries.values())
    visited: set[Path] = set()
    while queue:
        current = queue.pop()
        if current in visited:
            continue
        visited.add(current)
        for dep in pe_imports(current):
            if dep in redist_map:
                if dep not in needed_crt:
                    needed_crt.add(dep)
                    queue.append(redist_map[dep])
            elif dep.startswith(CRT_PREFIXES):
                missing_crt.add(dep)

    if missing_crt:
        raise FileNotFoundError(
            f'Required CRT DLL(s) missing from {redist_dir}: {sorted(missing_crt)}'
        )
    if not needed_crt:
        raise ValueError('No MSVC CRT imports detected; refusing to strip all CRT DLLs')

    copied_crt: list[str] = []
    for name in sorted(needed_crt):
        src = redist_map[name]
        shutil.copy2(src, release_dir / src.name)
        copied_crt.append(src.name)

    skipped_crt = sorted(
        redist_map[n].name for n in redist_map if n not in needed_crt
    )
    removed_unused_assets: list[str] = []
    # Flutter tests can leave an absolute-path manifest beside the executable.
    # The release already provides data/flutter_assets/NativeAssetsManifest.json.
    test_manifest = release_dir / 'native_assets.json'
    if test_manifest.is_file():
        test_manifest.unlink()
        removed_unused_assets.append(test_manifest.name)
    record_web_dir = release_dir / 'data' / 'flutter_assets' / 'packages' / 'record_web'
    if record_web_dir.is_dir():
        shutil.rmtree(record_web_dir)
        removed_unused_assets.append('data/flutter_assets/packages/record_web')
        packages_dir = record_web_dir.parent
        if packages_dir.is_dir() and not any(packages_dir.iterdir()):
            packages_dir.rmdir()
    return {
        'copied_crt': copied_crt,
        'skipped_crt': skipped_crt,
        'removed_stale_crt': sorted(removed_stale_crt),
        'removed_unused_shims': sorted(removed_unused_shims),
        'removed_unused_assets': removed_unused_assets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-dir', type=Path, required=True)
    parser.add_argument('--redist-dir', type=Path, required=True)
    args = parser.parse_args()
    summary = prune_and_stage_crt(args.release_dir, args.redist_dir)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
