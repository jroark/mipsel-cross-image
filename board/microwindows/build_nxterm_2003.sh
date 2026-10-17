#!/bin/bash
# Build a launcher-safe nxterm for the Linux 2.4.18 and 2.6.8.1
# Microwindows images from the 2003 source matching their Nano-X server.
set -euo pipefail

OUT=${1:?usage: build_nxterm_2003.sh <output-binary>}
MW_SHA=62030e82492b549dab8aaead29b40963aea79de1
ARCHIVE=/work/archives/microwindows-${MW_SHA:0:12}.tar.gz
UC=/work/uclibc-sysroot
CC=mipsel-linux-gnu-gcc
GCCLIB=$(dirname "$($CC -print-libgcc-file-name)")

if [ ! -f "$ARCHIVE" ]; then
    echo "--- Downloading Microwindows ${MW_SHA:0:12} (2003) ---"
    wget -q "https://github.com/ghaerr/microwindows/archive/${MW_SHA}.tar.gz" \
        -O "$ARCHIVE.tmp"
    mv "$ARCHIVE.tmp" "$ARCHIVE"
fi
if [ ! -f "$UC/usr/lib/libc.a" ]; then
    echo "ERROR: $UC/usr/lib/libc.a missing; build the uClibc-ng sysroot first:" >&2
    echo "  BE300_LIBC=uclibc ./build_be300_kernel.sh" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tar xzf "$ARCHIVE" -C "$WORK" --strip-components=1 \
    "microwindows-${MW_SHA}/src/include" \
    "microwindows-${MW_SHA}/src/nanox" \
    "microwindows-${MW_SHA}/src/demos/nanox/nxterm.c" \
    "microwindows-${MW_SHA}/src/demos/nanox/nxterm.h"
SRC=$WORK/src

# The stock 80x25 window is wider than the 240x320 LCD. The advertised -g
# option is not parsed by this source revision, so set useful defaults here.
sed -i -e 's/col = 80;/col = 38;/' -e 's/row = 25;/row = 20;/' \
    "$SRC/demos/nanox/nxterm.c"
# uClibc-ng is configured without utmp; nxterm only references struct utmp
# inside an already-disabled #if 0 block.
sed -i '/#include <utmp.h>/d' "$SRC/demos/nanox/nxterm.c"

ARCH="-march=mips2 -msoft-float -mabi=32 -fno-stack-protector -fno-pie"
CFLAGS="$ARCH -Os -fcommon -w -nostdinc \
    -isystem $UC/usr/include -isystem /work/uclibc-kernel-headers/include \
    -isystem $GCCLIB/include \
    -I$SRC/include -I$SRC/nanox -I$SRC/demos/nanox \
    -DUNIX=1 -DLINUX=1 -DMW_FEATURE_IMAGES=1 -DMW_FEATURE_TIMERS=1 \
    -DHAVE_SHAREDMEM_SUPPORT=0"

$CC $ARCH -O2 -ffreestanding -fno-builtin \
    -c -o "$WORK/libgcc_helpers.o" /work/board/casio-be300/libgcc_helpers.c
for f in demos/nanox/nxterm nanox/client nanox/nxproto nanox/error nanox/nxutil; do
    # shellcheck disable=SC2086
    $CC $CFLAGS -c -o "$WORK/$(basename "$f").o" "$SRC/$f.c"
done

# Static uClibc-ng avoids the donor nxterm's broken launcher-child startup
# while retaining the 2003 Nano-X wire protocol and BSD pty implementation.
set +e
$CC $ARCH -static -no-pie -nostdlib -Wl,-s -o "$OUT" \
    "$UC/usr/lib/crt1.o" "$UC/usr/lib/crti.o" "$GCCLIB/crtbegin.o" \
    "$WORK/nxterm.o" "$WORK/client.o" "$WORK/nxproto.o" "$WORK/error.o" \
    "$WORK/nxutil.o" "$WORK/libgcc_helpers.o" \
    -L"$UC/usr/lib" -lc "$GCCLIB/libgcc.a" \
    "$GCCLIB/crtend.o" "$UC/usr/lib/crtn.o" \
    2>&1 | grep -v 'uses -m.*-float'
LINK_STATUS=${PIPESTATUS[0]}
set -e
if [ "$LINK_STATUS" -ne 0 ] || [ ! -f "$OUT" ]; then
    echo "ERROR: link of $OUT failed" >&2
    exit 1
fi

DISASM=$(mipsel-linux-gnu-objdump -d "$OUT")
if grep -qE $'\t(mul|madd|maddu|msub|msubu|clz|clo|movn|movz|movt|movf|ext|ins|seb|seh|wsbh|rotr|rotrv|rdhwr|sd|ld|daddu|daddiu|dsll|dsrl|dsra|dmult|ddiv)\t' <<<"$DISASM"; then
    echo "ERROR: $OUT contains instructions the VR4131 cannot execute" >&2
    exit 1
fi
ls -la "$OUT"
