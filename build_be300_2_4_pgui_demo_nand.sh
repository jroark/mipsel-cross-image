#!/bin/bash
# Build a BE-300 NAND image with the picogui-DEMO userspace on JFFS2 mtd3.
#
# Source-rebuilds vmlinux from archives/linux4be-2.4.18-20021129.tar.gz +
# patches/linux-2.4.18-be300/series (which now includes patch 0012 fixing
# the modern-gcc ip_fast_csum miscompile so TCP loopback works), then
# extracts vmlinux-pgui-demo's __rd_start..__rd_end ramdisk (BusyBox +
# uClibc 0.9.15 + picogui demo apps: pgserver, pgboard, omnibar,
# canvastst, ...) and writes it as the JFFS2 mtd3 partition.  Kernel
# cmdline: noinitrd root=/dev/mtdblock3 rootfstype=jffs2 init=/sbin/init.
#
# Sibling of build_be300_2_4_pgui_nand.sh (which defaults to the test1
# donor / videotest-only userspace).
#
# Override BE300_2_4_RAMDISK_SRC for a different donor vmlinux.

set -e

BE300_2_4_UI=pgui \
    BE300_2_4_RAMDISK_SRC="${BE300_2_4_RAMDISK_SRC:-/work/vmlinux-pgui-demo}" \
    BE300_2_4_NAND="${BE300_2_4_NAND:-/work/linux-4.2.9/be300-2_4-pgui-demo.nand}" \
    exec ./build_be300_2_4_kernel.sh "$@"
