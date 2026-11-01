#!/usr/bin/env python3
"""Stage the pinned upstream MTD/JFFS2 snapshot into a physical-only 2.4 tree."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile
import tempfile

SHA256='1ee1bb3338b9ec13037eedb03920b92d4d6336d936a581e0262d8687ddab9940'
URL='https://archive.debian.org/debian/pool/main/m/mtd/mtd_20050122.orig.tar.gz'


def compatibility(tree):
    board=Path(__file__).resolve().parents[1]/'board/casio-be300'
    source=board/'mtd24_compat.h'
    inode=tree/'fs/inode.c'
    text=inode.read_text()
    if 'struct inode *ilookup(' not in text:
        inode.write_text(text+'\n'+(board/'mtd24_ilookup.c.inc').read_text())
    (tree/'include/linux/be300_mtd24_compat.h').write_bytes(source.read_bytes())
    header=tree/'include/linux/mtd/compatmac.h'
    text=header.read_text()
    line='#include <linux/be300_mtd24_compat.h>\n'
    if line not in text:
        header.write_text(text.replace('#include <linux/version.h>', '#include <linux/version.h>\n'+line))


def install(tree,archive):
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=SHA256:
        raise ValueError('MTD snapshot checksum mismatch')
    # patchin creates this via include/asm before oldconfig selects MIPS.
    # Stage it in the architecture directory so that selection cannot lose it.
    bug=tree/'include/asm-mips/bug.h'
    if not bug.exists():
        bug.write_text('/* BUG is supplied by the Linux 2.4 MIPS headers. */\n')
    marker=tree/'.be300-mtd-20050122'
    if marker.exists():
        if marker.read_text().strip()!=SHA256:
            raise ValueError('different backport already staged; use a fresh physical tree')
        compatibility(tree)
        return
    with tempfile.TemporaryDirectory(prefix='be300-mtd-') as tmp:
        root=Path(tmp)
        with tarfile.open(archive) as tar:
            for member in tar:
                rel=Path(member.name)
                if rel.is_absolute() or '..' in rel.parts:
                    raise ValueError('unsafe archive path')
                if member.isfile():
                    target=root/rel
                    target.parent.mkdir(parents=True,exist_ok=True)
                    target.write_bytes(tar.extractfile(member).read())
        snapshot=root/'mtd-20050122.orig'
        subprocess.run(['bash',str(snapshot/'patches/patchin.sh'),'-2','-c','-y',str(tree.resolve())],check=True)
        # Preserve the snapshot's licence alongside the installed filesystem.
        (tree/'fs/jffs2/LICENCE').write_bytes((snapshot/'fs/jffs2/LICENCE').read_bytes())
    compatibility(tree)
    marker.write_text(SHA256+'\n')


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('tree',type=Path)
    ap.add_argument('--archive',type=Path,required=True)
    args=ap.parse_args()
    install(args.tree,args.archive)
