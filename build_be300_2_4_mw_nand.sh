#!/bin/bash
# Build a BE-300 NAND image with the Microwindows / Nano-X userspace on
# JFFS2 mtd3.
#
# Source-rebuilds vmlinux from archives/linux4be-2.4.18-20021129.tar.gz +
# patches/linux-2.4.18-be300/series, then extracts vmlinux-mw's
# __rd_start..__rd_end ramdisk (BusyBox + uClibc 0.9.19 + nano-X server
# + nanowm + launcher + ~30 Nano-X demo apps: ntetris, nxclock, nxterm,
# nxkbd, nxmag, nxroach, nxeyes, ...) and writes it as the JFFS2 mtd3
# partition.  Kernel cmdline:
#   noinitrd root=/dev/mtdblock3 rootfstype=jffs2 init=/sbin/init ne=0x300,72
#
# Sibling of build_be300_2_4_pgui_nand.sh / build_be300_2_4_pgui_demo_nand.sh.
#
# Override BE300_2_4_RAMDISK_SRC for a different donor vmlinux.

set -e

BE300_2_4_UI=mw \
    BE300_2_4_RAMDISK_SRC="${BE300_2_4_RAMDISK_SRC:-/work/vmlinux-mw}" \
    BE300_2_4_NAND="${BE300_2_4_NAND:-/work/linux-4.2.9/be300-2_4-mw.nand}" \
    exec ./build_be300_2_4_kernel.sh "$@"
