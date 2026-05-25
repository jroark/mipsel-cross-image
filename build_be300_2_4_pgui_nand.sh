#!/bin/bash
# Build a BE-300 NAND image with a Linux 2.4.18-mips kernel that
# mounts the picogui rootfs from /dev/mtdblock3 (JFFS2).
#
# Source-rebuilds vmlinux from archives/linux4be-2.4.18-20021129.tar.gz
# + patches/linux-2.4.18-be300/series, then unpacks
# vmlinux-pgui-test1's __rd_start..__rd_end (BusyBox + uClibc 0.9.15 +
# picogui) and writes that as the JFFS2 mtd3 partition.  Kernel cmdline
# becomes `noinitrd root=/dev/mtdblock3 rootfstype=jffs2 init=/sbin/init`.
#
# Override the ramdisk donor with BE300_2_4_RAMDISK_SRC=<other vmlinux>.

set -e

BE300_2_4_UI=pgui exec ./build_be300_2_4_kernel.sh "$@"
