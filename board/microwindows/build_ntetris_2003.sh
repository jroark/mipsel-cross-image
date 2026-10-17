#!/bin/bash
# Build a BE-300 button-controlled ntetris for the 2003 linux4.be Nano-X
# server used by the Linux 2.4.18 and 2.6.8.1 mw profiles.
#
# The donor ntetris links the donor libnano-X.so (uClibc 0.9.19).  To change
# it we rebuild it from Microwindows commit 62030e8 (May 18 2003, the closest
# commit to the donor's May 18 2003 build; nxproto.h/client.c are unchanged
# through the 0.90 tag), with that tree's client library compiled in.
# patch_nxtetris_be300.py removes the on-screen buttons and reads the
# "BE-300 Buttons" evdev node directly (BE300_EVDEV_BUTTONS), since the
# donor server only reads the /dev/tty0 console keyboard.
#
# It links statically against the BE-300 uClibc-ng 1.0.51 sysroot, the libc
# the 2.4.18 and 2.6.8.1 OPIE images already run on: 32-bit time_t, the
# legacy-syscall preferences from build_be300_kernel.sh prepare_uclibc_ng()
# (_newselect, gettimeofday, ...), LinuxThreads without TLS, soft-float.
# musl 1.2 needs set_thread_area, set_tid_address and clock_gettime, which
# those kernels lack.  libgcc_helpers.c supplies MIPS II 64-bit division
# helpers in place of Debian's mips32r2 libgcc ones (mul/clz).
#
# BE300_NTETRIS_CFLAGS adds compiler flags (e.g. -DBE300_TETRIS_DEBUG=1).
#
# usage: build_ntetris_2003.sh <output-binary>
set -euo pipefail

OUT=${1:?usage: build_ntetris_2003.sh <output-binary>}
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
    "microwindows-${MW_SHA}/src/demos/nanox/ntetris.c" \
    "microwindows-${MW_SHA}/src/demos/nanox/ntetris.h"
SRC=$WORK/src
python3 /work/board/microwindows/patch_nxtetris_be300.py "$SRC/demos/nanox/ntetris.c"

ARCH="-march=mips2 -msoft-float -mabi=32 -fno-stack-protector -fno-pie"
# Client-side only: no shared memory transport, images/timers as in the
# donor build.  -fcommon: the 2003 headers define globals in .h files.
CFLAGS="$ARCH -Os -fcommon -w -nostdinc \
    -isystem $UC/usr/include -isystem /work/uclibc-kernel-headers/include \
    -isystem $GCCLIB/include \
    -I$SRC/include -I$SRC/nanox \
    -DUNIX=1 -DLINUX=1 -DMW_FEATURE_IMAGES=1 -DMW_FEATURE_TIMERS=1 \
    -DHAVE_SHAREDMEM_SUPPORT=0 \
    -DBE300_HW_BUTTONS=1 -DBE300_EVDEV_BUTTONS=1 ${BE300_NTETRIS_CFLAGS:-}"

$CC $ARCH -O2 -ffreestanding -fno-builtin \
    -c -o "$WORK/libgcc_helpers.o" /work/board/casio-be300/libgcc_helpers.c
for f in demos/nanox/ntetris nanox/client nanox/nxproto nanox/error; do
    # shellcheck disable=SC2086
    $CC $CFLAGS -c -o "$WORK/$(basename $f).o" "$SRC/$f.c"
done

# Debian's libgcc.a is hard-float; the FP-ABI mismatch warnings are
# expected (see CLAUDE.md, uClibc-ng dynamic profile) and ntetris does no
# floating point.
$CC $ARCH -static -no-pie -nostdlib -Wl,-s -o "$OUT" \
    "$UC/usr/lib/crt1.o" "$UC/usr/lib/crti.o" "$GCCLIB/crtbegin.o" \
    "$WORK/ntetris.o" "$WORK/client.o" "$WORK/nxproto.o" "$WORK/error.o" \
    "$WORK/libgcc_helpers.o" \
    -L"$UC/usr/lib" -lc "$GCCLIB/libgcc.a" \
    "$GCCLIB/crtend.o" "$UC/usr/lib/crtn.o" 2>&1 | grep -v 'uses -m.*-float' || true
[ -f "$OUT" ] || { echo "ERROR: link of $OUT failed" >&2; exit 1; }

# VR4131 is MIPS III without SPECIAL2, conditional moves or MIPS32r2 ops; the
# emulator is 32-bit only.  Fail rather than ship an opcode that SIGILLs.
# (Capture first: with pipefail, `objdump | grep -q` reports the SIGPIPE.)
DISASM=$(mipsel-linux-gnu-objdump -d "$OUT")
if grep -qE $'\t(mul|madd|maddu|msub|msubu|clz|clo|movn|movz|movt|movf|ext|ins|seb|seh|wsbh|rotr|rotrv|rdhwr|sd|ld|daddu|daddiu|dsll|dsrl|dsra|dmult|ddiv)\t' <<<"$DISASM"; then
    echo "ERROR: $OUT contains instructions the VR4131 cannot execute" >&2
    exit 1
fi
ls -la "$OUT"
