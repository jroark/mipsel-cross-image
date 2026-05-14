#!/usr/bin/env python3
"""Pack an arbitrary BE-300 vmlinux ELF as a NAND boot image.

This is the "Phase 1" tool from the legacy-kernel plan: it takes any
little-endian MIPS ELF that fits the existing SPL contract (KSEG entry,
flat size <= 0x4EC000) and produces a NAND image bootable on
``bin/be300 --nand``.

It mirrors the constant-extraction + SPL build + NAND pack flow that
``build_be300_kernel.sh`` runs in its Phase 7a/7c for the 4.2.9 kernel,
but operates on an externally-supplied vmlinux instead of the 4.2.9
build output. The SPL itself is built unchanged from
``board/casio-be300/{spl_start.S,spl.c,spl.lds}`` with kernel constants
baked in via ``-D``.

Designed to run inside the ``mips-dev`` Docker container (the modern
``mipsel-linux-gnu-{gcc,ld}`` cross toolchain must be on PATH).

Usage:
    python3 tools/pack_legacy_kernel_nand.py \\
        --vmlinux kernels/vmlinux-2.4 \\
        --out linux-4.2.9/be300-2_4.nand \\
        --build-dir linux-4.2.9/spl_build_2_4

The optional ``--rootfs`` flag is forwarded to ``mk_be300_nand.py`` for
the eventual Phase 2/3 JFFS2 path, but Phase 1 leaves it unset because
the prebuilt 2.4/2.6 kernels carry an embedded initrd in their second
PT_LOAD segment.
"""

from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SPL_SRC_DIR = REPO_ROOT / "board" / "casio-be300"
MK_NAND = REPO_ROOT / "tools" / "mk_be300_nand.py"

ELF_MAGIC = b"\x7fELF"
PT_LOAD = 1


def extract_kernel_consts(vmlinux: Path) -> tuple[int, int, int]:
    """Return (load_va, entry_va, flat_size) extracted from an ELF32 LE MIPS file.

    Mirrors the inline ``python3`` heredoc in ``build_be300_kernel.sh``
    Phase 7a (lines ~2661-2678) so legacy outputs match the 4.2.9 SPL
    contract byte-for-byte.
    """
    data = vmlinux.read_bytes()
    if data[:4] != ELF_MAGIC:
        raise SystemExit(f"{vmlinux}: not an ELF file")
    if data[4] != 1 or data[5] != 1:
        raise SystemExit(f"{vmlinux}: must be ELF32 little-endian")
    e_machine = struct.unpack_from("<H", data, 18)[0]
    if e_machine != 8:
        raise SystemExit(f"{vmlinux}: e_machine={e_machine}, expected MIPS (8)")
    e_entry = struct.unpack_from("<I", data, 24)[0]
    e_phoff = struct.unpack_from("<I", data, 28)[0]
    e_phnum = struct.unpack_from("<H", data, 44)[0]

    loads: list[tuple[int, int]] = []
    for i in range(e_phnum):
        o = e_phoff + i * 32
        p_type, _p_offset, p_vaddr, _p_paddr, p_filesz, *_ = struct.unpack_from(
            "<IIIIIIII", data, o
        )
        if p_type == PT_LOAD and p_filesz:
            loads.append((p_vaddr, p_filesz))
    if not loads:
        raise SystemExit(f"{vmlinux}: no PT_LOAD segments with file data")

    base = min(a for a, _ in loads)
    end = max(a + s for a, s in loads)
    return base, e_entry, end - base


def build_spl(build_dir: Path, load_va: int, entry_va: int, size: int) -> Path:
    """Compile board/casio-be300/{spl_start.S,spl.c} into spl.elf.

    Returns the path to the resulting ``spl.elf``. The compile-time
    constants are injected as ``-D`` flags exactly as Phase 7a does.
    """
    cc = shutil.which("mipsel-linux-gnu-gcc")
    ld = shutil.which("mipsel-linux-gnu-ld")
    if not cc or not ld:
        raise SystemExit(
            "mipsel-linux-gnu-{gcc,ld} not found on PATH; run this script "
            "inside the mips-dev Docker container"
        )
    build_dir.mkdir(parents=True, exist_ok=True)

    cflags = [
        "-march=mips2",
        "-mabi=32",
        "-mno-abicalls",
        "-fno-pic",
        "-nostdlib",
        "-fno-builtin",
        "-ffreestanding",
        "-Os",
        "-g",
        "-fno-stack-protector",
        f"-DKERNEL_LOAD_VA={load_va:#010x}u",
        f"-DKERNEL_ENTRY_VA={entry_va:#010x}u",
        f"-DKERNEL_SIZE={size:#x}u",
    ]
    spl_start_o = build_dir / "spl_start.o"
    spl_o = build_dir / "spl.o"
    spl_elf = build_dir / "spl.elf"

    subprocess.run(
        [cc, *cflags, "-c", "-o", str(spl_start_o),
         str(SPL_SRC_DIR / "spl_start.S")],
        check=True,
    )
    subprocess.run(
        [cc, *cflags, "-c", "-o", str(spl_o), str(SPL_SRC_DIR / "spl.c")],
        check=True,
    )
    subprocess.run(
        [ld, "-m", "elf32ltsmip", "-T", str(SPL_SRC_DIR / "spl.lds"),
         "-o", str(spl_elf), str(spl_start_o), str(spl_o)],
        check=True,
    )
    return spl_elf


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vmlinux", required=True, type=Path,
                    help="Path to the kernel ELF to pack")
    ap.add_argument("--out", required=True, type=Path,
                    help="Output NAND image path")
    ap.add_argument("--build-dir", type=Path, default=None,
                    help="SPL build directory (default: <out>.spl_build)")
    ap.add_argument("--rootfs", type=Path, default=None,
                    help="Optional rootfs blob for NAND partition 3 (e.g. "
                         "rootfs.jffs2). Phase 1 leaves this unset because "
                         "the legacy kernels embed an initrd in vmlinux.")
    args = ap.parse_args()

    if not args.vmlinux.exists():
        raise SystemExit(f"{args.vmlinux}: not found")

    load_va, entry_va, size = extract_kernel_consts(args.vmlinux)
    print(f"[pack_legacy_kernel_nand] {args.vmlinux}")
    print(f"  KERNEL_LOAD_VA  = 0x{load_va:08X}")
    print(f"  KERNEL_ENTRY_VA = 0x{entry_va:08X}")
    print(f"  KERNEL_SIZE     = 0x{size:X} ({size/1024:.0f} KiB)")
    if size > 0x4EC000:
        raise SystemExit(
            f"  ERROR: flat kernel size 0x{size:X} > 0x4EC000 NAND kernel slot")

    build_dir = args.build_dir or args.out.with_suffix(args.out.suffix + ".spl_build")
    spl_elf = build_spl(build_dir, load_va, entry_va, size)
    print(f"  SPL ELF         = {spl_elf}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, str(MK_NAND),
           "--vmlinux", str(args.vmlinux),
           "--spl", str(spl_elf),
           "--out", str(args.out)]
    if args.rootfs is not None:
        cmd.extend(["--rootfs", str(args.rootfs)])
    subprocess.run(cmd, check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
