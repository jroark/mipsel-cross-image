#!/bin/bash
# Native offline NAND inspector/encoder shared by physical Linux packers.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT="${1:-$REPO/out/host/linux-nand-inventory}"
mkdir -p "$(dirname "$OUTPUT")"
"${HOSTCC:-cc}" -std=gnu99 -O2 -Wall -Wextra -Werror \
    "$REPO/tools/nand_inventory.c" \
    "$REPO/board/casio-be300/nand_boot.c" \
    "$REPO/board/casio-be300/nand_ecc.c" -o "$OUTPUT"
printf '%s\n' "$OUTPUT"
