#!/bin/bash
# build_be300_2_6_kernel.sh
#
# Pack a BE-300 NAND boot image around the Linux 2.6.8.1 kernel.
#
# Phase 1 (this script today): wrap the prebuilt kernels/vmlinux-2.6 ELF
# in the existing SPL + B000FF container so it can boot on the modern
# bin/be300 emulator (the legacy --kernel ELF loader was removed; --nand
# is the only path now). The 2.6.8.1 kernel carries its initrd inside
# the second PT_LOAD segment, so no separate rootfs blob is needed.
#
# Phase 3 (TODO, per /Users/jroark/.claude/plans/optimized-leaping-wadler.md):
# fetch stock linux-2.6.8.1.tar.bz2, overlay
# src/linux-latest/kernel-unstable-2.6.x/, apply the VR4131 cache patches
# and root-of-repo 2.6.x diffs, embed an initramfs from
# scripts/build_legacy_initramfs.sh, build vmlinux, then re-enter the
# packer below.
#
# Intended invocation:
#   docker-compose run --rm mips-dev bash -c "./build_be300_2_6_kernel.sh"

set -euo pipefail

VMLINUX="${BE300_2_6_VMLINUX:-/work/kernels/vmlinux-2.6}"
OUT="${BE300_2_6_NAND:-/work/linux-4.2.9/be300-2_6.nand}"
BUILD_DIR="${BE300_2_6_SPL_BUILD:-/work/linux-4.2.9/spl_build_2_6}"

echo "=== build_be300_2_6_kernel.sh ==="
echo "  VMLINUX = $VMLINUX"
echo "  OUT     = $OUT"

if [[ ! -f "$VMLINUX" ]]; then
    echo "ERROR: $VMLINUX missing. Phase 3 (source rebuild) is not yet"
    echo "implemented; for Phase 1 expects the prebuilt kernels/vmlinux-2.6." >&2
    exit 1
fi

python3 /work/tools/pack_legacy_kernel_nand.py \
    --vmlinux "$VMLINUX" \
    --out "$OUT" \
    --build-dir "$BUILD_DIR"

echo ""
echo "=== Done ==="
ls -l "$OUT"
echo ""
echo "Boot with:"
echo "  ./bin/be300 --nand ${OUT#/work/} --speed 0 --detect-stall"
