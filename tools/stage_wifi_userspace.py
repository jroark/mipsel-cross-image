#!/usr/bin/env python3
"""Optionally install verified MIPS Wi-Fi tools; never generate credentials."""
import argparse
import shutil
import struct
from pathlib import Path


def stage(source, root):
    files = ('wpa_supplicant', 'wpa_cli', 'COPYING', 'README', 'SOURCE',
             'SOURCE_NOTICES')
    for name in files:
        if not (source / name).is_file():
            raise ValueError(f'missing Wi-Fi userspace input: {source / name}')
    for name in files[:2]:
        data = (source / name).read_bytes()
        if (len(data) < 52 or data[:6] != b'\x7fELF\x01\x01' or
                struct.unpack_from('<H', data, 18)[0] != 8):
            raise ValueError(f'{name} must be ELF32 little-endian MIPS')
    (root / 'sbin').mkdir(parents=True, exist_ok=True)
    license_dir = root / 'usr/share/licenses/wpa_supplicant'
    license_dir.mkdir(parents=True, exist_ok=True)
    for name in files[:2]:
        dest = root / 'sbin' / name
        shutil.copyfile(source / name, dest)
        dest.chmod(0o755)
    for name in files[2:]:
        dest = license_dir / name
        shutil.copyfile(source / name, dest)
        dest.chmod(0o644)
    print(f'Installed Wi-Fi tools and notices in {root}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    try:
        stage(args.source.resolve(), args.root.resolve())
    except (OSError, ValueError) as error:
        parser.exit(1, f'Wi-Fi userspace staging failed: {error}\n')
