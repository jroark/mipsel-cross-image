#!/bin/bash
# build_be300_2_6_kernel.sh
#
# Build a BE-300 NAND boot image for Linux 2.6.8.1.
#
# Two modes, selected by BE300_2_6_MODE (default: rebuild):
#
#   BE300_2_6_MODE=prebuilt -- wrap the 2004 linux4be kernels/vmlinux-2.6 ELF
#       in the SPL + B000FF container so it boots on bin/be300 --nand.  That
#       kernel carries its own initrd in the second PT_LOAD segment and has
#       no JFFS2 / BE-300 NAND / touch / Stowaway / NE2000 support.
#
#   BE300_2_6_MODE=rebuild -- download kernel.org linux-2.6.8.1 into
#       archives/, extract it to linux-2.6.8.1/, apply
#       patches/linux-2.6.8.1-be300/series (linux4be board support, GCC 10
#       fixes, NAND MTD, VRC4173 cascade + PCMCIA, Stowaway/touch/buttons,
#       ttyS0, be300_2_6_defconfig), build vmlinux with the Debian/Ubuntu
#       mipsel-linux-gnu cross toolchain, then pack it with a JFFS2 rootfs.
#
# BE300_2_6_UI selects the rootfs in rebuild mode:
#   opie (default) -- the BusyBox + Opie 1.2.5 / Qt-Embedded 2.3.10 uClibc-ng
#                     userspace shared with the 2.4.18 and 4.2.9 OPIE images
#                     (scripts/stage_legacy_opie_rootfs.sh), on mtd3.
#   mw             -- the 2003 linux4.be Microwindows/Nano-X donor rootfs from
#                     vmlinux-mw (BE300_2_6_RAMDISK_SRC overrides), shared
#                     with the 2.4.18 mw image
#                     (scripts/stage_legacy_mw_rootfs.sh); merges
#                     configs/be300_2_6_mw.config for BSD ptys.
#   none           -- kernel only (no rootfs; boots to "VFS: Cannot open
#                     root device"), for kernel bring-up.
#
# Other knobs:
#   BE300_2_6_CONSOLE=tty0|ttyS0  kernel console (default tty0 = LCD).
#   BE300_2_6_KEEP_BOOTCON=1      keep mirroring printk to the dock UART
#                                 after boot (debug; conflicts with the
#                                 Stowaway keyboard).
#   BE300_2_6_NAND=<path>         output image.
#
# Intended invocation:
#   docker-compose run --rm mips-dev bash -c "./build_be300_2_6_kernel.sh"
#   docker-compose run --rm mips-dev bash -c "BE300_2_6_MODE=prebuilt ./build_be300_2_6_kernel.sh"

set -euo pipefail

REPO=/work
MODE="${BE300_2_6_MODE:-rebuild}"

if [[ "$MODE" == "prebuilt" ]]; then
    VMLINUX="${BE300_2_6_VMLINUX:-$REPO/kernels/vmlinux-2.6}"
    OUT="${BE300_2_6_NAND:-$REPO/linux-4.2.9/be300-2_6.nand}"
    BUILD_DIR="${BE300_2_6_SPL_BUILD:-$REPO/linux-4.2.9/spl_build_2_6}"

    echo "=== build_be300_2_6_kernel.sh (prebuilt mode) ==="
    echo "  VMLINUX = $VMLINUX"
    echo "  OUT     = $OUT"
    [[ -f "$VMLINUX" ]] || { echo "ERROR: $VMLINUX missing" >&2; exit 1; }

    python3 "$REPO/tools/pack_legacy_kernel_nand.py" \
        --vmlinux "$VMLINUX" \
        --out "$OUT" \
        --build-dir "$BUILD_DIR"
    ls -l "$OUT"
    echo ""
    echo "Boot with:"
    echo "  ./bin/be300 --nand ${OUT#$REPO/} --speed 0 --detect-stall"
    exit 0
fi

[[ "$MODE" == "rebuild" ]] || {
    echo "ERROR: BE300_2_6_MODE must be 'prebuilt' or 'rebuild' (got '$MODE')" >&2
    exit 2
}

KVER=2.6.8.1
SOURCE_DIR="$REPO/linux-$KVER"
TARBALL="$REPO/archives/linux-$KVER.tar.bz2"
TARBALL_URL="https://mirrors.edge.kernel.org/pub/linux/kernel/v2.6/linux-$KVER.tar.bz2"
TARBALL_SHA256=910f4af05f40ed9a6ab3bc8ccf7ca77365fb7bfe9b5dcfa7ff316e03b354d4ff
PATCH_SERIES="$REPO/patches/linux-$KVER-be300/series"
SPL_BUILD="$SOURCE_DIR/spl_build"
KMAKE=(make -C "$SOURCE_DIR" ARCH=mips CROSS_COMPILE=mipsel-linux-gnu-)

UI="${BE300_2_6_UI:-opie}"
CONSOLE="${BE300_2_6_CONSOLE:-tty0}"
case "$UI" in
    opie) OUT="${BE300_2_6_NAND:-$REPO/linux-4.2.9/be300-2_6-opie.nand}" ;;
    mw)   OUT="${BE300_2_6_NAND:-$REPO/linux-4.2.9/be300-2_6-mw.nand}" ;;
    none) OUT="${BE300_2_6_NAND:-$REPO/linux-4.2.9/be300-2_6-rebuilt.nand}" ;;
    *) echo "ERROR: BE300_2_6_UI must be 'opie', 'mw' or 'none' (got '$UI')" >&2; exit 2 ;;
esac
case "$CONSOLE" in
    tty0|ttyS0) ;;
    *) echo "ERROR: BE300_2_6_CONSOLE must be 'tty0' or 'ttyS0' (got '$CONSOLE')" >&2; exit 2 ;;
esac

echo "=== build_be300_2_6_kernel.sh (rebuild mode) ==="
echo "  source   = $SOURCE_DIR"
echo "  patches  = $PATCH_SERIES"
echo "  ui       = $UI"
echo "  console  = $CONSOLE"
echo "  out      = $OUT"

# 1. Reuse a supplied source tree, or fetch and verify the upstream archive.
# An existing tree is useful for offline builds and pinned Git source mirrors.
if [[ ! -f "$SOURCE_DIR/Makefile" ]]; then
    if [[ ! -f "$TARBALL" ]]; then
        echo "--- Downloading linux-$KVER ---"
        mkdir -p "$(dirname "$TARBALL")"
        curl -L --fail "$TARBALL_URL" -o "$TARBALL.part"
        mv "$TARBALL.part" "$TARBALL"
    fi
    echo "$TARBALL_SHA256  $TARBALL" | sha256sum -c - >/dev/null || {
        echo "ERROR: $TARBALL sha256 mismatch" >&2
        exit 1
    }
    tar -xjf "$TARBALL" -C "$REPO"
fi
python3 - "$SOURCE_DIR/Makefile" <<'PYCHECK'
import re, sys
text = open(sys.argv[1]).read()
for key, value in [('VERSION', '2'), ('PATCHLEVEL', '6'), ('SUBLEVEL', '8'), ('EXTRAVERSION', '.1')]:
    match = re.search(r'^' + key + r'\s*=\s*(\S+)\s*$', text, re.M)
    if not match or match[1] != value:
        raise SystemExit('ERROR: expected Linux 2.6.8.1 source in ' + sys.argv[1])
PYCHECK

# 2. Apply the BE-300 patch series (idempotent).
"$REPO/scripts/apply_patch_series.sh" "$PATCH_SERIES" "$SOURCE_DIR"
python3 "$REPO/scripts/install_board_hardware.py" "$SOURCE_DIR" --kernel 2.6

# 3. Configure.  The defconfig's built-in command line carries root= and the
#    NE2000 address because the SPL passes no arguments (a0..a3 = 0).
echo "--- Configuring be300_2_6_defconfig ---"
"${KMAKE[@]}" be300_2_6_defconfig >/dev/null
CMDLINE=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$SOURCE_DIR/.config")
if [[ "$CONSOLE" == "ttyS0" ]]; then
    CMDLINE="${CMDLINE/console=tty0/console=ttyS0}"
fi
if [[ "${BE300_2_6_KEEP_BOOTCON:-0}" == "1" ]]; then
    CMDLINE="$CMDLINE keep_bootcon"
fi
sed -i "s|^CONFIG_CMDLINE=.*|CONFIG_CMDLINE=\"$CMDLINE\"|" "$SOURCE_DIR/.config"
if [[ "$UI" == "mw" ]]; then
    echo "--- merging configs/be300_2_6_mw.config ---"
    FRAG="$REPO/configs/be300_2_6_mw.config"
    for opt in $(grep -oE '^CONFIG_[A-Z0-9_]+' "$FRAG"); do
        sed -i -e "/^$opt=/d" -e "/^# $opt is not set/d" "$SOURCE_DIR/.config"
    done
    grep -E '^CONFIG_' "$FRAG" >> "$SOURCE_DIR/.config"
fi
"${KMAKE[@]}" oldconfig </dev/null >/dev/null
echo "  cmdline  = $CMDLINE"

# 4. Build.
echo "--- Building vmlinux ---"
"${KMAKE[@]}" -j"$(nproc)" vmlinux
mipsel-linux-gnu-size "$SOURCE_DIR/vmlinux"

# The emulator executes 32-bit MIPS only.  The only 64-bit instructions
# allowed in the image are the never-run calibrate_div64_gettimeoffset
# (VR41xx uses the fixed-rate RTC timer) and the R4000SC VCE handler.
BAD64=$(mipsel-linux-gnu-objdump -d "$SOURCE_DIR/vmlinux" | awk '
    /^[0-9a-f]+ <.*>:$/ { fn = $2 }
    $3 ~ /^(sd|ld|daddu|daddiu|dsubu|dsll|dsll32|dsrl|dsrl32|dsra|dsra32|dmult|dmultu|ddiv|ddivu|lwu|ldl|ldr|sdl|sdr|dmfc0|dmtc0)$/ \
        && fn !~ /^<(calibrate_div64_gettimeoffset|handle_vced)>:$/ { print fn, $0 }' | head -5)
if [[ -n "$BAD64" ]]; then
    echo "ERROR: 64-bit instructions in vmlinux outside the known-dead paths:" >&2
    echo "$BAD64" >&2
    exit 1
fi

# 5. Rootfs.
JFFS2_ROOTFS=""
if [[ "$UI" == "opie" ]]; then
    JFFS2_ROOTFS="$REPO/linux-4.2.9/rootfs-2_6-opie.jffs2"
    bash "$REPO/scripts/stage_legacy_opie_rootfs.sh" \
        --label "$KVER" \
        --devtable "$REPO/board/casio-be300/be300_2_6_devtable.txt" \
        --out "$JFFS2_ROOTFS" \
        --console "$CONSOLE" \
        --sysfs
elif [[ "$UI" == "mw" ]]; then
    JFFS2_ROOTFS="$REPO/linux-4.2.9/rootfs-2_6-mw.jffs2"
    bash "$REPO/scripts/stage_legacy_mw_rootfs.sh" \
        --donor "${BE300_2_6_RAMDISK_SRC:-$REPO/vmlinux-mw}" \
        --devtable "$REPO/board/casio-be300/be300_2_6_devtable.txt" \
        --out "$JFFS2_ROOTFS"
fi

# 6. Pack: SPL + flat kernel + JFFS2 mtd3 (tools/pack_legacy_kernel_nand.py
#    enforces the 0x14000..0x500000 kernel window).
echo "--- pack NAND image ---"
PACK_ARGS=( --vmlinux "$SOURCE_DIR/vmlinux" --out "$OUT" --build-dir "$SPL_BUILD" )
if [[ -n "$JFFS2_ROOTFS" ]]; then
    PACK_ARGS+=( --rootfs "$JFFS2_ROOTFS" )
fi
python3 "$REPO/tools/pack_legacy_kernel_nand.py" "${PACK_ARGS[@]}"

echo ""
echo "=== Done ==="
ls -l "$OUT"
echo ""
echo "Boot with:"
echo "  ./bin/be300 --nand ${OUT#$REPO/} --speed 0 --ne2000 --net-mac 02:de:ad:be:ef:01 --stowaway-keyboard"
echo ""
echo "Serial shell (ttyS0, without --stowaway-keyboard -- they share the UART):"
echo "  ./bin/be300 --nand ${OUT#$REPO/} --speed 0 --serial1-bridge pty:auto"
