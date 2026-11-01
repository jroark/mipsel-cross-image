#!/usr/bin/env python3
"""Rehearse a complete install and restore through the emulator NAND model.

Requires the sibling Glaze checkout and its built host/libwolfssl.a. Runs the
production host writer, kernel repair state machine and NAND driver against
the independent controller model; checks every data/OOB byte and block order.
"""
import argparse
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile

ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--glaze-root',type=Path,required=True)
ap.add_argument('--emulator-root',type=Path,required=True)
for name in ('source','target','install-plan','restore-plan'):
    ap.add_argument('--'+name,type=Path,required=True)
ap.add_argument('--cc',default='clang')
ap.add_argument('--log',type=Path)
args=ap.parse_args()
r=args.glaze_root.resolve()
e=args.emulator_root.resolve()
lib=r/'host/libwolfssl.a'
flags=[]
if platform.system()=='Darwin':
    arches=subprocess.check_output(['lipo','-archs',str(lib)],text=True).split()
    arch=platform.machine() if platform.machine() in arches else arches[0]
    flags+=['-arch',arch]
usb=shlex.split(subprocess.check_output(['pkg-config','--cflags','libusb-1.0'],text=True))
with tempfile.TemporaryDirectory(prefix='linux-nand-transaction-') as tmp:
    tmp=Path(tmp)
    binary=tmp/'transaction'
    command=[args.cc,*flags,'-std=gnu11','-O1','-g','-Wall','-Wextra',
             '-Wno-unused-parameter','-Wno-return-type','-fsanitize=address,undefined',
             '-DWOLFSSL_USER_SETTINGS',
             '-DGLAZE_CLIENT_HEADER="'+str(r/'host/glaze_usb/client.h')+'"',
             '-DGLAZE_NAND_PROGRAM_TEST="'+str(r/'tests/nand_program.c')+'"',
             *['-I'+str(r/p) for p in ('lib/include','host','third_party/wolfssl','apps/browser/tls')],
             '-I'+str(e/'src'),*usb,str(Path(__file__).with_suffix('.c')),
             str(r/'host/glaze_usb/nand_write.c'),str(lib),
             str(e/'src/hw/nand.c'),str(e/'src/hw/nand_restore.c'),'-o',str(binary)]
    subprocess.run(command,check=True)
    log=args.log or tmp/'transaction.log'
    with log.open('wb') as output:
        result=subprocess.run([str(binary),str(args.source),str(args.target),
                               str(args.install_plan),str(args.restore_plan)],
                              stdout=output,stderr=subprocess.STDOUT)
    lines=log.read_text(errors='replace').splitlines()
    print('\n'.join(lines[-30:] if result.returncode else lines[-1:]))
    result.check_returncode()
