#!/bin/bash
# Build a BE-300 NAND image with Linux 2.6.8.1 and the Opie 1.2.5 /
# Qt-Embedded 2.3.10 userspace on JFFS2 mtd3.
#
# Source-rebuilds vmlinux from kernel.org linux-2.6.8.1 +
# patches/linux-2.6.8.1-be300/series, builds the same uClibc-ng BusyBox +
# Opie rootfs as the 2.4.18 OPIE image (scripts/stage_legacy_opie_rootfs.sh)
# and packs linux-4.2.9/be300-2_6-opie.nand.
#
# Sibling of build_be300_opie_nand.sh (4.2.9) and
# BE300_2_4_UI=opie ./build_be300_2_4_kernel.sh (2.4.18).

set -e

BE300_2_6_MODE=rebuild \
    BE300_2_6_UI=opie \
    BE300_2_6_NAND="${BE300_2_6_NAND:-/work/linux-4.2.9/be300-2_6-opie.nand}" \
    exec ./build_be300_2_6_kernel.sh "$@"
