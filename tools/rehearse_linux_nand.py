#!/usr/bin/env python3
"""Run Glaze's native USB transaction test with a Unix emulator transport.

This changes only local test IPC, avoiding TCP delayed acknowledgements on
64-byte USB packets. The production CLI, kernel writer and NAND model are
unchanged. All NAND mutations occur on the harness's disposable image copy.
"""
import argparse
from pathlib import Path
import sys

ap=argparse.ArgumentParser(description=__doc__,add_help=False)
ap.add_argument('--glaze-root',type=Path,required=True)
args,remaining=ap.parse_known_args()
test=args.glaze_root.resolve()/'tests/usb_native.py'
source=test.read_text()
changes={
    'with socket.socket() as listener,': 'with socket.socket(socket.AF_UNIX) as listener,',
    'listener.bind(("127.0.0.1", 0))': 'listener.bind(str(work / "usbredir.sock"))',
    'f"tcp:127.0.0.1:{listener.getsockname()[1]}"': 'f"unix:{listener.getsockname()}"',
}
for before,after in changes.items():
    if source.count(before)!=1:
        raise SystemExit('Glaze USB harness changed; review the local transport adapter')
    source=source.replace(before,after)
sys.path.insert(0,str(test.parent))
sys.argv=[str(test),*remaining]
exec(compile(source,str(test),'exec'),{'__name__':'__main__','__file__':str(test)})
