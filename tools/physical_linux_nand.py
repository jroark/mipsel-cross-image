#!/usr/bin/env python3
"""Offline Linux NAND encoding. Never opens a physical device.

Build helper:
  cc -O2 tools/nand_inventory.c board/casio-be300/nand_{boot,ecc}.c -o OUT
The inventory and transaction formats are compatible with Glaze's repair tools.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import zlib

PAGE, PAGES, BLOCK = 528, 32768, 32 * 528
DATA_BLOCK = 16384
FS_FIRST, FS_END = 320, 1004


def sha(data):
    return hashlib.sha256(data).hexdigest()


def native(helper, args, data=None):
    return subprocess.run([str(helper), *map(str, args)], input=data,
                          stdout=subprocess.PIPE, check=True).stdout


def inventory(helper, backup):
    raw = backup.read_bytes()
    if len(raw) != PAGE * PAGES:
        raise ValueError('backup must be exactly 32768 physical 512+16 pages')
    if raw[528:536] == b'GZNAND1\0':
        raise ValueError('initial installation requires a CE inventory; installed-image updates need their original inventory')
    bitmap = native(helper, [backup])
    if len(bitmap) != 128:
        raise ValueError('invalid inventory helper result')
    return dict(version=1, classification='CE tag/ECC; untrusted blocks quarantined',
                source_sha256=sha(raw),
                quarantined=[b for b in range(1024) if bitmap[b//8] & (1 << (b%8))])


def pack(helper, logical, backup, inv, filesystem):
    if len(logical) != 16 * 1024 * 1024 or len(backup) != PAGE * PAGES:
        raise ValueError('invalid logical image or backup geometry')
    if inv.get('version') != 1 or inv.get('source_sha256') != sha(backup):
        raise ValueError('inventory is not bound to the source backup')
    bad = inv['quarantined']
    if any(type(b) is not int or not 0 <= b < 1024 for b in bad) or len(set(bad)) != len(bad):
        raise ValueError('invalid quarantine')
    bad = set(bad)
    if 0 in bad:
        raise ValueError('physical boot block zero is quarantined')
    for i, (start, maximum) in enumerate(((0,32),(32,128),(160,10080))):
        sector, count = struct.unpack_from('<II', logical, i*16+8)
        if sector != start or not 0 < count <= maximum:
            raise ValueError('invalid boot partition extent')
    if b'BE300_PHYSICAL_NAND_V1' not in logical[0x14000:0x500000]:
        raise ValueError('kernel lacks physical NAND support; rebuild from updated board sources')
    if logical[0x4000:0x4007] != b'B000FF\n':
        raise ValueError('missing SPL container')
    good_fs = [b for b in range(FS_FIRST, FS_END) if b not in bad]
    if not good_fs:
        raise ValueError('no good filesystem blocks')
    # Require a separately rebuilt, padded image; never silently truncate one.
    if len(filesystem) != len(good_fs) * DATA_BLOCK:
        raise ValueError(f'fresh JFFS2 image must be padded to {len(good_fs)*DATA_BLOCK} bytes')
    pool = iter(b for b in range(FS_END,1024) if b not in bad)
    mapping = {}
    for b in range(FS_FIRST):
        try:
            mapping[b] = next(pool) if b in bad else b
        except StopIteration:
            raise ValueError('boot replacement pool exhausted') from None
    digest = sha(json.dumps(inv, sort_keys=True, separators=(',', ':')).encode())
    manifest = bytearray(b'\xff'*512)
    manifest[:8] = b'GZNAND1\0'
    struct.pack_into('<5I', manifest,8,1,FS_FIRST,FS_END-FS_FIRST,FS_END,len(bad))
    manifest[28:156] = bytes(128)
    for b in bad:
        manifest[28+b//8] |= 1 << (b%8)
    manifest[156:188] = bytes.fromhex(digest)
    manifest[188:196] = b'LINUX1\0\0'
    struct.pack_into('<I',manifest,508,zlib.crc32(manifest[:508]))
    source = bytearray(logical)
    source[512:1024] = manifest
    struct.pack_into('<II',source,3*16+8,FS_FIRST*32,(FS_END-FS_FIRST)*32)
    raw = bytearray(backup)
    for b in range(1024):
        if b not in bad:
            raw[b*BLOCK:(b+1)*BLOCK] = b'\xff'*BLOCK
    pages = bytearray()
    for b in range(FS_FIRST):
        tag = b'\xaa\x55\x0f\xff'+struct.pack('<I',b)
        for p in range(32):
            at = (b*32+p)*512
            pages.extend(source[at:at+512]+tag)
    encoded = native(helper, ['--encode'], pages)
    if len(encoded) != FS_FIRST*BLOCK:
        raise ValueError('incomplete boot encoding')
    for b,phys in mapping.items():
        raw[phys*BLOCK:(phys+1)*BLOCK] = encoded[b*BLOCK:(b+1)*BLOCK]
    # Filesystem OOB 0..7 stays FF, including the NAND bad-block marker.
    # Fully erased pages stay erased; programmed pages receive RS parity.
    pages, destinations = bytearray(), []
    for i,b in enumerate(good_fs):
        for p in range(32):
            data = filesystem[(i*32+p)*512:(i*32+p+1)*512]
            if data == b'\xff'*512:
                continue
            pages.extend(data+b'\xff'*8)
            destinations.append((b*32+p)*PAGE)
    encoded = native(helper,['--encode'],pages)
    if len(encoded) != len(destinations)*PAGE:
        raise ValueError('incomplete filesystem encoding')
    for i,at in enumerate(destinations):
        raw[at:at+PAGE] = encoded[i*PAGE:(i+1)*PAGE]
    plan = dict(version=1, artifact='Linux offline candidate; not a flash command',
                backup_sha256=sha(backup), inventory_sha256=digest,
                logical_sha256=sha(logical), filesystem_sha256=sha(filesystem),
                physical_sha256=sha(raw), raw_page_bytes=PAGE,
                fs_first=FS_FIRST, fs_blocks=FS_END-FS_FIRST, reserve_first=FS_END,
                preserve_blocks=sorted(bad), erase_blocks=[b for b in range(1024) if b not in bad],
                boot_replacements={str(b):p for b,p in mapping.items() if b != p})
    return raw,plan


def write_new(path,data):
    # Refuse replacement, including a leftover partial publication.
    partial = Path(str(path)+'.partial')
    fd = os.open(partial,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'wb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.link(partial,path)
    partial.unlink()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--helper',type=Path,required=True)
    commands = ap.add_subparsers(dest='command',required=True)
    inv = commands.add_parser('inventory')
    inv.add_argument('--backup',type=Path,required=True)
    inv.add_argument('--out',type=Path,required=True)
    packer = commands.add_parser('pack')
    for name in ('logical','backup','inventory','rootfs','out','plan'):
        packer.add_argument('--'+name,type=Path,required=True)
    args = ap.parse_args()
    try:
        observed = inventory(args.helper,args.backup)
        if args.command == 'inventory':
            write_new(args.out,(json.dumps(observed,indent=2)+'\n').encode())
            return
        if args.out.exists() or args.plan.exists():
            raise ValueError('choose new output and plan paths')
        inv = json.loads(args.inventory.read_text())
        if inv != observed:
            raise ValueError('inventory differs from fresh backup scan')
        raw,plan = pack(args.helper,args.logical.read_bytes(),args.backup.read_bytes(),inv,args.rootfs.read_bytes())
        # The helper checks all boot pages using the production strict reader.
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            candidate = Path(tmp)/'candidate.raw'
            candidate.write_bytes(raw)
            native(args.helper,['--check-boot',candidate])
        write_new(args.out,raw)
        write_new(args.plan,(json.dumps(plan,indent=2)+'\n').encode())
        print(f'Offline candidate {args.out}: {plan["physical_sha256"]}')
    except (ValueError,OSError,KeyError,subprocess.CalledProcessError) as exc:
        ap.exit(1,f'physical-linux-nand: {exc}\n')


if __name__ == '__main__':
    main()
