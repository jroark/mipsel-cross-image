#!/usr/bin/env python3
"""Prepare Linux installs from fresh snapshots after JFFS2 has changed.

Uses Glaze's transaction format and writer. No device access. The original CE
inventory remains authoritative; a used Linux snapshot must match the installed
reference outside its filesystem, preserve quarantine, and contain no newly
marked filesystem bad blocks. Such blocks require inventory reconciliation.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

import physical_linux_nand as linux


def snapshot_binding(source, reference, factory, inventory, installed):
    if any(len(x)!=linux.PAGE*linux.PAGES for x in (source,reference,factory)):
        raise ValueError('all images must be exact physical snapshots')
    bad=inventory['quarantined']
    if (not isinstance(bad,list) or any(type(b) is not int or not 0<=b<1024 for b in bad) or
        len(set(bad))!=len(bad)):
        raise ValueError('invalid factory quarantine')
    if (inventory.get('version')!=1 or inventory.get('source_sha256')!=linux.sha(factory) or
        installed.get('backup_sha256')!=linux.sha(factory) or
        installed.get('physical_sha256')!=linux.sha(reference) or
        installed.get('preserve_blocks')!=sorted(bad) or
        set(installed.get('erase_blocks',[]))!=set(range(1024))-set(bad)):
        raise ValueError('installed placement is not bound to the reference and factory inventory')
    if reference[528+188:528+196]!=b'LINUX1\0\0':
        raise ValueError('installed reference is not a Linux physical image')
    first,end=linux.FS_FIRST*linux.BLOCK,linux.FS_END*linux.BLOCK
    if source[:first]!=reference[:first] or source[end:]!=reference[end:]:
        raise ValueError('snapshot changed outside the installed filesystem')
    for b in bad:
        at=b*linux.BLOCK
        if source[at:at+linux.BLOCK]!=factory[at:at+linux.BLOCK]:
            raise ValueError('snapshot changed a quarantined block')
    for b in range(linux.FS_FIRST,linux.FS_END):
        if b in bad:
            continue
        if any(source[(b*32+p)*528+517]!=255 for p in (0,1)):
            raise ValueError('new runtime bad block requires inventory reconciliation before a full reinstall')
    # This binding is derived only after proving the allowed JFFS2 changes.
    return dict(installed,physical_sha256=linux.sha(source),
                snapshot_of_sha256=linux.sha(reference),
                source_policy='fresh Linux snapshot; immutable regions and quarantine verified')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--glaze-root',type=Path,required=True)
    ap.add_argument('--helper',type=Path,required=True)
    for name in ('source','target','factory-backup','inventory','out'):
        ap.add_argument('--'+name,type=Path,required=True)
    for name in ('placement','installed','installed-image'):
        ap.add_argument('--'+name,type=Path)
    ap.add_argument('--restore',action='store_true')
    args=ap.parse_args()
    try:
        path=args.glaze_root.resolve()/'tools/nand_transaction.py'
        spec=importlib.util.spec_from_file_location('glaze_transaction',path)
        transaction=importlib.util.module_from_spec(spec);spec.loader.exec_module(transaction)
        inventory=json.loads(args.inventory.read_text())
        if inventory!=linux.inventory(args.helper,args.factory_backup):
            raise ValueError('factory inventory differs from the original backup scan')
        source,target,factory=(p.read_bytes() for p in (args.source,args.target,args.factory_backup))
        placement=json.loads(args.placement.read_text()) if args.placement else None
        binding=None
        if source!=factory and not args.restore:
            if not args.installed or not args.installed_image:
                raise ValueError('used Linux source needs --installed and --installed-image')
            binding=snapshot_binding(source,args.installed_image.read_bytes(),factory,inventory,
                                     json.loads(args.installed.read_text()))
        if not args.restore:
            linux.native(args.helper,['--check-boot',args.target])
        plan,review=transaction.prepare(source,target,factory,inventory,placement,args.restore,binding)
        if binding:
            review['source_binding']=binding
        review_path=Path(str(args.out)+'.review.json')
        if args.out.exists() or review_path.exists():
            raise ValueError('choose new plan and review paths')
        linux.write_new(args.out,plan)
        linux.write_new(review_path,(json.dumps(review,indent=2)+'\n').encode())
        print(f'Prepared {review["operation"]}: {len(review["write_order"])} blocks; no device access')
    except (ValueError,OSError,KeyError,TypeError,subprocess.CalledProcessError) as exc:
        ap.exit(1,f'linux-nand-transaction: {exc}\n')


if __name__=='__main__':
    main()
