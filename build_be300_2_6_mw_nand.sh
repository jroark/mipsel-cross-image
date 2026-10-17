#!/bin/bash
# Build linux-4.2.9/be300-2_6-mw.nand: the source-built Linux 2.6.8.1
# kernel with the 2003 linux4.be Microwindows/Nano-X donor rootfs (the
# same userspace as the 2.4.18 mw image, via
# scripts/stage_legacy_mw_rootfs.sh) on JFFS2 mtd3.
#
#   docker-compose run --rm mips-dev bash -c "./build_be300_2_6_mw_nand.sh"
#   ./bin/be300 --nand linux-4.2.9/be300-2_6-mw.nand --speed 0 --ne2000 \
#       --net-mac 02:de:ad:be:ef:02 --stowaway-keyboard
set -e

BE300_2_6_MODE=rebuild \
    BE300_2_6_UI=mw \
    BE300_2_6_NAND="${BE300_2_6_NAND:-/work/linux-4.2.9/be300-2_6-mw.nand}" \
    exec ./build_be300_2_6_kernel.sh "$@"
