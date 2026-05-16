#!/bin/bash
# BE-300 TinyX rootfs builder.
#
# Invoked by build_be300_kernel.sh when BE300_UI=tinyx:
#
#   board/tinyx/build_tinyx_rootfs.sh "$ROOTFS" "$MUSL_SPECS" "$KHDRS"
#
# Phase order (numbered T-* to disambiguate from the parent script's phases):
#
#   T1.  prepare_support_libs       libbe300cxx.a + libbe300gcc.a
#   T2.  load_versions              source board/tinyx/xorg_versions
#   T3.  download_all               cache every tarball into /work/archives/
#   T4.  extract_all                extract sources into /work/xorg-be300/
#   T5.  patch_xorg_sources         autoconf 2.69 modernization on xorg-server
#   T6.  build_host_helpers         util-macros, host xkbcomp -> /tmp/xorg-host
#   T7.  build_protocol_headers     xproto..xtrans -> /tmp/xorg-stage
#   T8.  build_libxau_xcb           libXau, xcb-proto, libxcb, libpthread-stubs
#   T9.  build_core_x11             libX11..libXaw -> $ROOTFS + /tmp/xorg-stage
#  T10.  build_pixman               pixman 0.16.6
#  T11.  build_xorg_server          kdrive Xfbdev (xorg-server-1.6.5.901)
#  T12.  build_matchbox             libmatchbox 1.9 + matchbox-window-manager 1.2
#  T13.  build_terminal             rxvt 2.7.10 (xterm 253 optional)
#  T14.  build_be300_x_helpers      small Xlib helpers for the launcher
#  T15.  compile_xkb_keymap         host xkbcomp -> /usr/share/X11/xkb/compiled/us.xkm
#  T16.  install_fonts              font-misc-misc + font-cursor-misc PCFs
#  T17.  install_matchbox_rc        /etc/matchbox/matchbox-window-manager.rc
#  T18.  prune_install              rm includes/man/locale/.la/.a/pkgconfig
#  T19.  strip_tinyx_artifacts
#  T20.  verify_tinyx_mips2         opcode scan
#
# Helpers (download_archive, make_generated_tree_writable, unsupported_mips2_insn,
# be300_strip_binary, ensure_autotools) are copied by value from
# board/picogui/build_picogui_rootfs.sh so this script remains testable in
# isolation.
#
# Implementation state (May 10, 2026): T1–T19 implemented per
# plans/concurrent-launching-creek.md. Build code is unvalidated against the
# Docker container — expect iteration on configure flags and library link
# order on first end-to-end run. Set BE300_TINYX_SKIP_BUILD=1 to stop after
# download+extract+patch and produce an empty rootfs whose start-tinyx
# falls through to "Xfbdev failed to start" (useful for sanity-checking the
# dispatch path in isolation).

set -e

ROOTFS="${1:?rootfs path required}"
MUSL_SPECS="${2:?musl specs path required}"
KHDRS="${3:?kernel headers path required}"

ARCHIVES="/work/archives"
BOARD_DIR="/work/board/tinyx"
BE300_LIBS="/tmp/be300-tinyx-libs"
LOG_DIR="/work/build-tinyx"
XORG_SRC_ROOT="/work/xorg-be300"
XORG_STAGE="/tmp/xorg-stage"
XORG_HOST="/tmp/xorg-host"
TINYX_BUILD_STAMP="${BE300_TINYX_BUILD_STAMP:-.be300-tinyx-built-v1}"

# BE300_TINYX_SKIP_BUILD=1 stops after download+extract+patch (skeleton mode),
# producing an empty rootfs whose start-tinyx falls through to "Xfbdev failed
# to start".  Default is 0 (run the full build).
BE300_TINYX_SKIP_BUILD="${BE300_TINYX_SKIP_BUILD:-0}"
# Terminal selection: default rxvt, optional xterm.
BE300_TINYX_TERMINAL="${BE300_TINYX_TERMINAL:-rxvt}"

BE300_LIBC="${BE300_LIBC:-uclibc}"

CROSS="mipsel-linux-gnu-"
TARGET_CC="${BE300_TARGET_CC:-${CROSS}gcc}"
TARGET_CXX="${BE300_TARGET_CXX:-${CROSS}g++}"
TARGET_AR="${BE300_TARGET_AR:-${CROSS}ar}"
TARGET_RANLIB="${BE300_TARGET_RANLIB:-${CROSS}ranlib}"
TARGET_STRIP="${BE300_TARGET_STRIP:-${CROSS}strip}"
TARGET_CROSS_COMPILE="${BE300_TARGET_CROSS_COMPILE:-${CROSS}}"

ARCH_CFLAGS="${BE300_ARCH_CFLAGS:--march=mips2 -msoft-float}"
DEFAULT_LIBC_CFLAGS="-isystem ${KHDRS}/include -B/tmp/libgcc_patched -L/tmp/libgcc_patched"
DEFAULT_LIBC_LDFLAGS="-B/tmp/libgcc_patched -L/tmp/libgcc_patched"
LIBC_CFLAGS="${BE300_LIBC_CFLAGS:-$DEFAULT_LIBC_CFLAGS} -B/tmp/libgcc_patched -L/tmp/libgcc_patched"
LIBC_LDFLAGS="${BE300_LIBC_LDFLAGS:-$DEFAULT_LIBC_LDFLAGS} -B/tmp/libgcc_patched -L/tmp/libgcc_patched"

if [ "$BE300_LIBC" = "musl" ]; then
    LINK_STATIC_LDFLAGS="-static"
else
    LINK_STATIC_LDFLAGS=""
fi

COMMON_CFLAGS="${ARCH_CFLAGS} -Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-stack-protector -fcommon -Wno-error -Wno-implicit-function-declaration -Wno-incompatible-pointer-types -D_GNU_SOURCE -D_DEFAULT_SOURCE -D_BSD_SOURCE ${LIBC_CFLAGS} -I${BE300_LIBS}/include -I${XORG_STAGE}/usr/include"
COMMON_LFLAGS="${LIBC_LDFLAGS} ${LINK_STATIC_LDFLAGS} -Wl,--gc-sections -Wl,--copy-dt-needed-entries -Wl,-rpath-link,${XORG_STAGE}/usr/lib -L${BE300_LIBS}/lib -L${XORG_STAGE}/usr/lib -lz -lxcb -lXau -lXdmcp"
# Intentionally empty: X11 libraries are pure C and do not need the C++ shim
# or the patched libgcc helpers.  Passing -lbe300cxx -lbe300gcc here also
# leaks into host-tool builds (libXt's makestrs, etc.) and breaks the host
# link.  Per-package LIBS go through configure flags or LDFLAGS instead.
COMMON_LIBS=""

mkdir -p "$LOG_DIR" "$XORG_SRC_ROOT" "$XORG_STAGE" "$XORG_HOST" "$ARCHIVES"

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

make_generated_tree_writable() {
    local path
    for path in "$@"; do
        [ -d "$path" ] && chmod -R a+rwX "$path" 2>/dev/null || true
    done
}

download_archive() {
    local url="$1"
    local out="$2"
    mkdir -p "$(dirname "$out")"
    if [ ! -s "$out" ]; then
        echo "--- Downloading $(basename "$out") ---"
        if command -v curl >/dev/null 2>&1; then
            curl -L --fail "$url" -o "$out"
        else
            wget "$url" -O "$out"
        fi
    fi
}

unsupported_mips2_insn() {
    mipsel-linux-gnu-objdump -d "$1" 2>/dev/null \
        | awk '$3 ~ /^(mul|clz|clo|ext|ins|movf|movn|movt|movz|pref|seb|seh|wsbh|rdhwr)$/ {print; exit}' \
        || true
}

be300_strip_binary() {
    for file in "$@"; do
        [ -e "$file" ] || continue
        # Skip non-ELF files (e.g. libc.so is a linker script in uClibc-ng).
        # `file` is sufficient, but checking ELF magic is faster + portable.
        if ! head -c 4 "$file" 2>/dev/null | grep -q $'\x7fELF'; then
            continue
        fi
        mipsel-linux-gnu-strip --strip-all \
            --remove-section=.comment \
            --remove-section=.note \
            "$file" 2>/dev/null \
            || mipsel-linux-gnu-strip --strip-all "$file" \
            || true
    done
}

verify_tinyx_mips2() {
    local file
    local bad

    [ -d "$ROOTFS/usr/bin" ] || return 0
    [ -d "$ROOTFS/usr/lib" ] || return 0

    while IFS= read -r file; do
        [ -e "$file" ] || continue
        bad=$(unsupported_mips2_insn "$file")
        if [ -n "$bad" ]; then
            echo "ERROR: $file contains VR4131-unsupported opcode: $bad" >&2
            return 1
        fi
    done < <(find "$ROOTFS/usr/bin" "$ROOTFS/usr/lib" -type f \
                 \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) \
                 2>/dev/null | sort)
    return 0
}

ensure_autotools() {
    # Mirror picogui: install xkb-data, xfonts-utils, xsltproc, python3-libxml2,
    # bdftopcf via apt-get if absent.  These are needed for: host xkbcomp
    # keymap compile, mkfontdir, libxcb codegen, libXfont BDF -> PCF.
    # autotools-dev provides up-to-date config.{sub,guess} that knows
    # aarch64 (the bundled ones in 1.6-era X.Org tarballs predate it).
    local need=""
    command -v xkbcomp        >/dev/null 2>&1 || need+=" x11-xkb-utils"
    command -v mkfontdir      >/dev/null 2>&1 || need+=" xfonts-utils"
    command -v xsltproc       >/dev/null 2>&1 || need+=" xsltproc"
    command -v bdftopcf       >/dev/null 2>&1 || need+=" xfonts-utils"
    command -v autoreconf     >/dev/null 2>&1 || need+=" autoconf automake libtool"
    command -v pkg-config     >/dev/null 2>&1 || need+=" pkg-config"
    python3 -c 'import lxml' 2>/dev/null      || need+=" python3-lxml"
    # xkb-data ships keycodes/symbols/etc that the host xkbcomp uses.
    [ -d /usr/share/X11/xkb/keycodes ]        || need+=" xkb-data"
    [ -f /usr/share/misc/config.sub ]         || need+=" autotools-dev"
    if [ -n "$need" ]; then
        echo "--- apt-get install$need ---"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $need
    fi
}

# Refresh every bundled config.sub / config.guess in the source tree with
# the host's modern copies.  X.Org 1.6-era tarballs ship config.{sub,guess}
# from 2009-2010, which predates the aarch64 (Apple Silicon / Linux on ARM
# server) triple — they reject every --build= value the modern autoconf
# detects.  Idempotent: just overwrites in place.
refresh_config_guess_sub_all() {
    local host_sub="/usr/share/misc/config.sub"
    local host_guess="/usr/share/misc/config.guess"
    [ -f "$host_sub" ] && [ -f "$host_guess" ] || {
        echo "WARNING: /usr/share/misc/config.{sub,guess} missing; aarch64 build may fail" >&2
        return 0
    }
    find "$XORG_SRC_ROOT" -type f -name config.sub -print0 2>/dev/null \
        | xargs -0 -r -I{} install -m 0755 "$host_sub" "{}"
    find "$XORG_SRC_ROOT" -type f -name config.guess -print0 2>/dev/null \
        | xargs -0 -r -I{} install -m 0755 "$host_guess" "{}"
}

# ---------------------------------------------------------------------
# T1. Support libs
# ---------------------------------------------------------------------

prepare_support_libs() {
    echo "=== Building BE-300 TinyX support libraries ==="
    rm -rf "$BE300_LIBS"
    mkdir -p "$BE300_LIBS/include" "$BE300_LIBS/lib"

    ${TARGET_CC} ${COMMON_CFLAGS} -fPIC -c \
        /work/board/opie/be300_cxx_abi.c -o /tmp/be300_cxx_abi.o
    ${TARGET_AR} rcs "$BE300_LIBS/lib/libbe300cxx.a" /tmp/be300_cxx_abi.o

    if [ -e /tmp/libgcc_patched/libbe300gcc.a ]; then
        cp /tmp/libgcc_patched/libbe300gcc.a "$BE300_LIBS/lib/"
    else
        echo "ERROR: /tmp/libgcc_patched/libbe300gcc.a missing — main script's prepare_be300_libgcc did not run" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------
# T2. Load versions
# ---------------------------------------------------------------------

load_versions() {
    # shellcheck disable=SC1091
    . "$BOARD_DIR/xorg_versions"
}

# ---------------------------------------------------------------------
# T3. Download all source tarballs into /work/archives/
# ---------------------------------------------------------------------

XORG_REL="https://www.x.org/releases/individual"
XCB_REL="https://xcb.freedesktop.org/dist"
FREEDESKTOP_REL="https://www.x.org/releases/individual"

download_all() {
    echo "=== Downloading TinyX upstream tarballs ==="
    download_archive "$XORG_REL/util/util-macros-${UTIL_MACROS}.tar.bz2"          "$ARCHIVES/util-macros-${UTIL_MACROS}.tar.bz2"
    download_archive "$XORG_REL/proto/xproto-${XPROTO}.tar.bz2"                   "$ARCHIVES/xproto-${XPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/xextproto-${XEXTPROTO}.tar.bz2"             "$ARCHIVES/xextproto-${XEXTPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/kbproto-${KBPROTO}.tar.bz2"                 "$ARCHIVES/kbproto-${KBPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/inputproto-${INPUTPROTO}.tar.bz2"           "$ARCHIVES/inputproto-${INPUTPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/fontsproto-${FONTSPROTO}.tar.bz2"           "$ARCHIVES/fontsproto-${FONTSPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/randrproto-${RANDRPROTO}.tar.bz2"           "$ARCHIVES/randrproto-${RANDRPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/renderproto-${RENDERPROTO}.tar.bz2"         "$ARCHIVES/renderproto-${RENDERPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/fixesproto-${FIXESPROTO}.tar.bz2"           "$ARCHIVES/fixesproto-${FIXESPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/damageproto-${DAMAGEPROTO}.tar.bz2"         "$ARCHIVES/damageproto-${DAMAGEPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/xcmiscproto-${XCMISCPROTO}.tar.bz2"         "$ARCHIVES/xcmiscproto-${XCMISCPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/bigreqsproto-${BIGREQSPROTO}.tar.bz2"       "$ARCHIVES/bigreqsproto-${BIGREQSPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/resourceproto-${RESOURCEPROTO}.tar.bz2"     "$ARCHIVES/resourceproto-${RESOURCEPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/compositeproto-${COMPOSITEPROTO}.tar.bz2"   "$ARCHIVES/compositeproto-${COMPOSITEPROTO}.tar.bz2"
    download_archive "$XORG_REL/proto/recordproto-${RECORDPROTO}.tar.bz2"         "$ARCHIVES/recordproto-${RECORDPROTO}.tar.bz2"
    download_archive "$XORG_REL/lib/xtrans-${XTRANS}.tar.bz2"                     "$ARCHIVES/xtrans-${XTRANS}.tar.bz2"
    download_archive "$XORG_REL/lib/libXau-${XAU}.tar.bz2"                        "$ARCHIVES/libXau-${XAU}.tar.bz2"
    download_archive "$XORG_REL/lib/libXdmcp-${XDMCP}.tar.bz2"                    "$ARCHIVES/libXdmcp-${XDMCP}.tar.bz2"
    download_archive "$XCB_REL/xcb-proto-${XCBPROTO}.tar.gz"                      "$ARCHIVES/xcb-proto-${XCBPROTO}.tar.gz"
    download_archive "$XCB_REL/libxcb-${LIBXCB}.tar.gz"                           "$ARCHIVES/libxcb-${LIBXCB}.tar.gz"
    download_archive "$XCB_REL/libpthread-stubs-${PTHREAD_STUBS}.tar.bz2"         "$ARCHIVES/libpthread-stubs-${PTHREAD_STUBS}.tar.bz2"
    download_archive "$XORG_REL/lib/libX11-${LIBX11}.tar.bz2"                     "$ARCHIVES/libX11-${LIBX11}.tar.bz2"
    # libXext 1.3.5+ only ships as .tar.xz on x.org (bz2 was dropped circa 2018).
    download_archive "$XORG_REL/lib/libXext-${LIBXEXT}.tar.xz"                    "$ARCHIVES/libXext-${LIBXEXT}.tar.xz"
    download_archive "$XORG_REL/lib/libICE-${LIBICE}.tar.bz2"                     "$ARCHIVES/libICE-${LIBICE}.tar.bz2"
    download_archive "$XORG_REL/lib/libSM-${LIBSM}.tar.bz2"                       "$ARCHIVES/libSM-${LIBSM}.tar.bz2"
    download_archive "$XORG_REL/lib/libXrender-${LIBXRENDER}.tar.bz2"             "$ARCHIVES/libXrender-${LIBXRENDER}.tar.bz2"
    download_archive "$XORG_REL/lib/libXfont-${LIBXFONT}.tar.bz2"                 "$ARCHIVES/libXfont-${LIBXFONT}.tar.bz2"
    download_archive "$XORG_REL/lib/libfontenc-${LIBFONTENC}.tar.bz2"             "$ARCHIVES/libfontenc-${LIBFONTENC}.tar.bz2"
    download_archive "$XORG_REL/lib/libxkbfile-${LIBXKBFILE}.tar.bz2"             "$ARCHIVES/libxkbfile-${LIBXKBFILE}.tar.bz2"
    download_archive "$XORG_REL/lib/libXpm-${LIBXPM}.tar.bz2"                     "$ARCHIVES/libXpm-${LIBXPM}.tar.bz2"
    download_archive "$XORG_REL/lib/libXfixes-${LIBXFIXES}.tar.bz2"               "$ARCHIVES/libXfixes-${LIBXFIXES}.tar.bz2"
    download_archive "$XORG_REL/lib/libXi-${LIBXI}.tar.bz2"                       "$ARCHIVES/libXi-${LIBXI}.tar.bz2"
    download_archive "$XORG_REL/lib/libXtst-${LIBXTST}.tar.bz2"                   "$ARCHIVES/libXtst-${LIBXTST}.tar.bz2"
    download_archive "$XORG_REL/lib/libXt-${LIBXT}.tar.bz2"                       "$ARCHIVES/libXt-${LIBXT}.tar.bz2"
    download_archive "$XORG_REL/lib/libXmu-${LIBXMU}.tar.bz2"                     "$ARCHIVES/libXmu-${LIBXMU}.tar.bz2"
    download_archive "$XORG_REL/lib/libXaw-${LIBXAW}.tar.bz2"                     "$ARCHIVES/libXaw-${LIBXAW}.tar.bz2"
    download_archive "$XORG_REL/lib/pixman-${PIXMAN}.tar.bz2"                     "$ARCHIVES/pixman-${PIXMAN}.tar.bz2"
    download_archive "$XORG_REL/app/xkbcomp-${XKBCOMP}.tar.bz2"                   "$ARCHIVES/xkbcomp-${XKBCOMP}.tar.bz2"
    download_archive "$XORG_REL/xserver/xorg-server-${XORG_SERVER}.tar.bz2"       "$ARCHIVES/xorg-server-${XORG_SERVER}.tar.bz2"
    # matchbox-project.org is offline; Yocto Project mirrors the original
    # tarballs under http://downloads.yoctoproject.org/releases/matchbox/.
    # Subdir name is the full version (e.g. .../libmatchbox/1.9/, not /1/).
    download_archive "http://downloads.yoctoproject.org/releases/matchbox/libmatchbox/${MATCHBOX_COMMON}/libmatchbox-${MATCHBOX_COMMON}.tar.bz2" \
                     "$ARCHIVES/libmatchbox-${MATCHBOX_COMMON}.tar.bz2"
    download_archive "http://downloads.yoctoproject.org/releases/matchbox/matchbox-window-manager/${MATCHBOX_WM}/matchbox-window-manager-${MATCHBOX_WM}.tar.bz2" \
                     "$ARCHIVES/matchbox-window-manager-${MATCHBOX_WM}.tar.bz2"
    if [ "$BE300_TINYX_TERMINAL" = "xterm" ]; then
        download_archive "https://invisible-mirror.net/archives/xterm/xterm-${XTERM}.tgz" \
                         "$ARCHIVES/xterm-${XTERM}.tgz"
    else
        download_archive "http://prdownloads.sourceforge.net/rxvt/rxvt-${RXVT}.tar.gz" \
                         "$ARCHIVES/rxvt-${RXVT}.tar.gz"
    fi
    download_archive "$XORG_REL/font/font-util-${FONT_UTIL}.tar.bz2"              "$ARCHIVES/font-util-${FONT_UTIL}.tar.bz2"
    download_archive "$XORG_REL/font/font-misc-misc-${FONT_MISC_MISC}.tar.bz2"    "$ARCHIVES/font-misc-misc-${FONT_MISC_MISC}.tar.bz2"
    download_archive "$XORG_REL/font/font-cursor-misc-${FONT_CURSOR_MISC}.tar.bz2" "$ARCHIVES/font-cursor-misc-${FONT_CURSOR_MISC}.tar.bz2"
}

# ---------------------------------------------------------------------
# T4. Extract all
# ---------------------------------------------------------------------

extract_one() {
    local archive="$1"
    local name="$2"           # directory name expected after extraction
    local dest="$XORG_SRC_ROOT/$name"
    if [ -d "$dest" ]; then
        return 0
    fi
    echo "--- Extracting $(basename "$archive") ---"
    case "$archive" in
        *.tar.bz2|*.tbz2) tar xjf "$archive" -C "$XORG_SRC_ROOT" ;;
        *.tar.gz|*.tgz)   tar xzf "$archive" -C "$XORG_SRC_ROOT" ;;
        *.tar.xz)         tar xJf "$archive" -C "$XORG_SRC_ROOT" ;;
        *) echo "unknown archive type: $archive" >&2; return 1 ;;
    esac
    [ -d "$dest" ] || { echo "extraction did not produce $dest" >&2; return 1; }
}

extract_all() {
    echo "=== Extracting TinyX sources into $XORG_SRC_ROOT ==="
    extract_one "$ARCHIVES/util-macros-${UTIL_MACROS}.tar.bz2"          "util-macros-${UTIL_MACROS}"
    extract_one "$ARCHIVES/xproto-${XPROTO}.tar.bz2"                    "xproto-${XPROTO}"
    extract_one "$ARCHIVES/xextproto-${XEXTPROTO}.tar.bz2"              "xextproto-${XEXTPROTO}"
    extract_one "$ARCHIVES/kbproto-${KBPROTO}.tar.bz2"                  "kbproto-${KBPROTO}"
    extract_one "$ARCHIVES/inputproto-${INPUTPROTO}.tar.bz2"            "inputproto-${INPUTPROTO}"
    extract_one "$ARCHIVES/fontsproto-${FONTSPROTO}.tar.bz2"            "fontsproto-${FONTSPROTO}"
    extract_one "$ARCHIVES/randrproto-${RANDRPROTO}.tar.bz2"            "randrproto-${RANDRPROTO}"
    extract_one "$ARCHIVES/renderproto-${RENDERPROTO}.tar.bz2"          "renderproto-${RENDERPROTO}"
    extract_one "$ARCHIVES/fixesproto-${FIXESPROTO}.tar.bz2"            "fixesproto-${FIXESPROTO}"
    extract_one "$ARCHIVES/damageproto-${DAMAGEPROTO}.tar.bz2"          "damageproto-${DAMAGEPROTO}"
    extract_one "$ARCHIVES/xcmiscproto-${XCMISCPROTO}.tar.bz2"          "xcmiscproto-${XCMISCPROTO}"
    extract_one "$ARCHIVES/bigreqsproto-${BIGREQSPROTO}.tar.bz2"        "bigreqsproto-${BIGREQSPROTO}"
    extract_one "$ARCHIVES/resourceproto-${RESOURCEPROTO}.tar.bz2"      "resourceproto-${RESOURCEPROTO}"
    extract_one "$ARCHIVES/compositeproto-${COMPOSITEPROTO}.tar.bz2"    "compositeproto-${COMPOSITEPROTO}"
    extract_one "$ARCHIVES/recordproto-${RECORDPROTO}.tar.bz2"          "recordproto-${RECORDPROTO}"
    extract_one "$ARCHIVES/xtrans-${XTRANS}.tar.bz2"                    "xtrans-${XTRANS}"
    extract_one "$ARCHIVES/libXau-${XAU}.tar.bz2"                       "libXau-${XAU}"
    extract_one "$ARCHIVES/libXdmcp-${XDMCP}.tar.bz2"                   "libXdmcp-${XDMCP}"
    extract_one "$ARCHIVES/xcb-proto-${XCBPROTO}.tar.gz"                "xcb-proto-${XCBPROTO}"
    extract_one "$ARCHIVES/libxcb-${LIBXCB}.tar.gz"                     "libxcb-${LIBXCB}"
    extract_one "$ARCHIVES/libpthread-stubs-${PTHREAD_STUBS}.tar.bz2"   "libpthread-stubs-${PTHREAD_STUBS}"
    extract_one "$ARCHIVES/libX11-${LIBX11}.tar.bz2"                    "libX11-${LIBX11}"
    extract_one "$ARCHIVES/libXext-${LIBXEXT}.tar.xz"                   "libXext-${LIBXEXT}"
    extract_one "$ARCHIVES/libICE-${LIBICE}.tar.bz2"                    "libICE-${LIBICE}"
    extract_one "$ARCHIVES/libSM-${LIBSM}.tar.bz2"                      "libSM-${LIBSM}"
    extract_one "$ARCHIVES/libXrender-${LIBXRENDER}.tar.bz2"            "libXrender-${LIBXRENDER}"
    extract_one "$ARCHIVES/libXfont-${LIBXFONT}.tar.bz2"                "libXfont-${LIBXFONT}"
    extract_one "$ARCHIVES/libfontenc-${LIBFONTENC}.tar.bz2"            "libfontenc-${LIBFONTENC}"
    extract_one "$ARCHIVES/libxkbfile-${LIBXKBFILE}.tar.bz2"            "libxkbfile-${LIBXKBFILE}"
    extract_one "$ARCHIVES/libXpm-${LIBXPM}.tar.bz2"                    "libXpm-${LIBXPM}"
    extract_one "$ARCHIVES/libXfixes-${LIBXFIXES}.tar.bz2"              "libXfixes-${LIBXFIXES}"
    extract_one "$ARCHIVES/libXi-${LIBXI}.tar.bz2"                      "libXi-${LIBXI}"
    extract_one "$ARCHIVES/libXtst-${LIBXTST}.tar.bz2"                  "libXtst-${LIBXTST}"
    extract_one "$ARCHIVES/libXt-${LIBXT}.tar.bz2"                      "libXt-${LIBXT}"
    extract_one "$ARCHIVES/libXmu-${LIBXMU}.tar.bz2"                    "libXmu-${LIBXMU}"
    extract_one "$ARCHIVES/libXaw-${LIBXAW}.tar.bz2"                    "libXaw-${LIBXAW}"
    extract_one "$ARCHIVES/pixman-${PIXMAN}.tar.bz2"                    "pixman-${PIXMAN}"
    extract_one "$ARCHIVES/xkbcomp-${XKBCOMP}.tar.bz2"                  "xkbcomp-${XKBCOMP}"
    extract_one "$ARCHIVES/xorg-server-${XORG_SERVER}.tar.bz2"          "xorg-server-${XORG_SERVER}"
    extract_one "$ARCHIVES/libmatchbox-${MATCHBOX_COMMON}.tar.bz2"      "libmatchbox-${MATCHBOX_COMMON}"
    extract_one "$ARCHIVES/matchbox-window-manager-${MATCHBOX_WM}.tar.bz2" "matchbox-window-manager-${MATCHBOX_WM}"
    if [ "$BE300_TINYX_TERMINAL" = "xterm" ]; then
        extract_one "$ARCHIVES/xterm-${XTERM}.tgz"                      "xterm-${XTERM}"
    else
        extract_one "$ARCHIVES/rxvt-${RXVT}.tar.gz"                     "rxvt-${RXVT}"
    fi
    extract_one "$ARCHIVES/font-util-${FONT_UTIL}.tar.bz2"              "font-util-${FONT_UTIL}"
    extract_one "$ARCHIVES/font-misc-misc-${FONT_MISC_MISC}.tar.bz2"    "font-misc-misc-${FONT_MISC_MISC}"
    extract_one "$ARCHIVES/font-cursor-misc-${FONT_CURSOR_MISC}.tar.bz2" "font-cursor-misc-${FONT_CURSOR_MISC}"
    make_generated_tree_writable "$XORG_SRC_ROOT"
}

# ---------------------------------------------------------------------
# T5. Patch X.Org sources for modern autoconf/automake and BE-300 runtime quirks
# ---------------------------------------------------------------------

patch_xorg_sources() {
    echo "=== Patching X.Org sources for modern autoconf/automake ==="
    refresh_config_guess_sub_all
    patch_xcb_proto_python3
    patch_xtrans_mips_accept
    patch_libX11_ioctl
    patch_libXt_drop_lock
    python3 "$BOARD_DIR/patch_libxfont_sources.py" \
        "$XORG_SRC_ROOT/libXfont-${LIBXFONT}"
    python3 "$BOARD_DIR/patch_xorg_sources.py" \
        "$XORG_SRC_ROOT/xorg-server-${XORG_SERVER}"
}

# xcb-proto 1.14 ships xcbgen/align.py with `from fractions import gcd`,
# which fails on Python 3.9+ (gcd moved to math).  In-place rewrite.
# Idempotent: only edits files that still have the old import.
patch_xcb_proto_python3() {
    local f="$XORG_SRC_ROOT/xcb-proto-${XCBPROTO}/xcbgen/align.py"
    [ -f "$f" ] || return 0
    if grep -q '^from fractions import gcd' "$f"; then
        sed -i 's|^from fractions import gcd|from math import gcd|' "$f"
        echo "--- Patched $f: fractions.gcd -> math.gcd ---"
    fi
}

# uClibc-ng exports accept(2) as a weak socket wrapper on MIPS.  Xfbdev can
# run all the way to the first client and then jump through a null PLT/GOT
# entry when xtrans accepts the Unix-domain X socket.  Use the kernel's O32
# accept syscall directly in xtrans so both Unix and TCP X listeners avoid
# that wrapper.
patch_xtrans_mips_accept() {
    local f="$XORG_SRC_ROOT/xtrans-${XTRANS}/Xtranssock.c"
    [ -f "$f" ] || return 0
    python3 - "$f" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
marker = "be300-tinyx: direct MIPS accept syscall"
if marker in text:
    sys.exit(0)

anchor = """#if defined HAVE_SOCKLEN_T || (defined(IPv6) && defined(AF_INET6))
# define SOCKLEN_T socklen_t
#elif defined(SVR4) || defined(__SVR4) || defined(__SCO__)
# define SOCKLEN_T size_t
#else
# define SOCKLEN_T int
#endif
"""
patch = anchor + r"""

#if defined(__linux__) && defined(__mips__) && !defined(WIN32)
#include <asm/unistd.h>

/* be300-tinyx: direct MIPS accept syscall, avoiding uClibc weak accept(). */
static int
be300_xtrans_accept(int fd, struct sockaddr *addr, SOCKLEN_T *addrlen)
{
#ifdef __NR_accept
    register long v0 __asm__("$2") = __NR_accept;
    register long a0 __asm__("$4") = fd;
    register long a1 __asm__("$5") = (long)addr;
    register long a2 __asm__("$6") = (long)addrlen;
    register long a3 __asm__("$7");

    __asm__ volatile (
        "syscall"
        : "+r" (v0), "+r" (a0), "+r" (a1), "+r" (a2), "=r" (a3)
        :
        : "memory");

    if (a3) {
        errno = (int)v0;
        return -1;
    }
    return (int)v0;
#else
    errno = ENOSYS;
    return -1;
#endif
}

#define accept be300_xtrans_accept
#endif
"""
if anchor not in text:
    raise SystemExit(f"{path}: SOCKLEN_T anchor not found")
path.write_text(text.replace(anchor, patch, 1))
PY
    echo "--- Patched xtrans: direct MIPS accept syscall ---"

    python3 - "$XORG_SRC_ROOT/xtrans-${XTRANS}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])

xtrans_h = root / "Xtrans.h"
text = xtrans_h.read_text()
marker = "be300-tinyx: local xserver xtrans symbols"
if marker not in text:
    anchor = "typedef struct _XtransConnInfo *XtransConnInfo;\n"
    patch = anchor + """
#if defined(XSERV_t) && defined(__GNUC__)
/* be300-tinyx: local xserver xtrans symbols. */
# define BE300_XTRANS_LOCAL __attribute__((visibility("hidden")))
#else
# define BE300_XTRANS_LOCAL
#endif

"""
    if anchor not in text:
        raise SystemExit(f"{xtrans_h}: XtransConnInfo anchor not found")
    text = text.replace(anchor, patch, 1)

    for decl in (
        "void TRANS(FreeConnInfo) (",
        "XtransConnInfo TRANS(OpenCOTSServer)(",
        "XtransConnInfo TRANS(ReopenCOTSServer)(",
        "int TRANS(GetReopenInfo)(",
        "int TRANS(SetOption)(",
        "int TRANS(CreateListener)(",
        "int TRANS(Received) (",
        "int TRANS(NoListen) (",
        "int TRANS(Listen) (",
        "int TRANS(IsListening) (",
        "int TRANS(ResetListener)(",
        "XtransConnInfo TRANS(Accept)(",
        "int TRANS(BytesReadable)(",
        "int TRANS(Read)(",
        "int TRANS(Write)(",
        "int TRANS(Readv)(",
        "int TRANS(Writev)(",
        "int TRANS(SendFd) (",
        "int TRANS(RecvFd) (",
        "int TRANS(Disconnect)(",
        "int TRANS(Close)(",
        "int TRANS(CloseForCloning)(",
        "int TRANS(IsLocal)(",
        "int TRANS(GetPeerAddr)(",
        "int TRANS(GetConnectionNumber)(",
        "int TRANS(MakeAllCOTSServerListeners)(",
        "int TRANS(ConvertAddress)(",
    ):
        text = text.replace(decl, "BE300_XTRANS_LOCAL " + decl)
    decl = "int\nTRANS(GetHostname) ("
    replacement = "BE300_XTRANS_LOCAL int\nTRANS(GetHostname) ("
    if replacement not in text:
        text = text.replace(decl, replacement, 1)
    xtrans_h.write_text(text)

xtrans_c = root / "Xtrans.c"
text = xtrans_c.read_text()
decl = "int TRANS(GetHostname) (char *buf, int maxlen)"
replacement = "BE300_XTRANS_LOCAL int TRANS(GetHostname) (char *buf, int maxlen)"
if replacement not in text:
    text = text.replace(decl, replacement, 1)
xtrans_c.write_text(text)

xtranssock_c = root / "Xtranssock.c"
text = xtranssock_c.read_text()
for decl in (
    "Xtransport\tTRANS(SocketTCPFuncs) = {",
    "Xtransport\tTRANS(SocketINETFuncs) = {",
    "Xtransport     TRANS(SocketINET6Funcs) = {",
    "Xtransport\tTRANS(SocketLocalFuncs) = {",
    "Xtransport\tTRANS(SocketUNIXFuncs) = {",
):
    replacement = "BE300_XTRANS_LOCAL " + decl
    if replacement not in text:
        text = text.replace(decl, replacement)
if "be300-tinyx: SocketUNIXAccept logging" not in text:
    text = text.replace(
        '    prmsg (2, "SocketUNIXAccept(%p,%d)\\n", ciptr, ciptr->fd);\n',
        '    prmsg (2, "SocketUNIXAccept(%p,%d)\\n", ciptr, ciptr->fd);\n'
        '    /* be300-tinyx: SocketUNIXAccept logging. */\n'
        '    ErrorF("be300-xtrans: SocketUNIXAccept entry ciptr=%p fd=%d addr=%p addrlen=%d\\n",\n'
        '           ciptr, ciptr ? ciptr->fd : -1, ciptr ? ciptr->addr : NULL,\n'
        '           ciptr ? ciptr->addrlen : -1);\n',
        1,
    )
    text = text.replace(
        '    if ((newciptr->fd = accept (ciptr->fd,\n'
        '\t(struct sockaddr *) &sockname, (void *)&namelen)) < 0)\n',
        '    ErrorF("be300-xtrans: SocketUNIXAccept before accept fd=%d\\n", ciptr->fd);\n'
        '    if ((newciptr->fd = accept (ciptr->fd,\n'
        '\t(struct sockaddr *) &sockname, (void *)&namelen)) < 0)\n',
        1,
    )
    text = text.replace(
        '    {\n'
        '\tprmsg (1, "SocketUNIXAccept: accept() failed\\n");\n'
        '\tfree (newciptr);\n'
        '\t*status = TRANS_ACCEPT_FAILED;\n'
        '\treturn NULL;\n'
        '    }\n'
        '\n'
        '\tciptr->addrlen = namelen;\n',
        '    {\n'
        '\tErrorF("be300-xtrans: SocketUNIXAccept accept failed errno=%d\\n", errno);\n'
        '\tprmsg (1, "SocketUNIXAccept: accept() failed\\n");\n'
        '\tfree (newciptr);\n'
        '\t*status = TRANS_ACCEPT_FAILED;\n'
        '\treturn NULL;\n'
        '    }\n'
        '    ErrorF("be300-xtrans: SocketUNIXAccept accepted fd=%d namelen=%d\\n",\n'
        '           newciptr->fd, (int)namelen);\n'
        '\n'
        '\tciptr->addrlen = namelen;\n',
        1,
    )
xtranssock_c.write_text(text)

xtrans_c = root / "Xtrans.c"
text = xtrans_c.read_text()
if "be300-tinyx: Xtrans Accept logging" not in text:
    old = """XtransConnInfo
TRANS(Accept) (XtransConnInfo ciptr, int *status)

{
    XtransConnInfo\tnewciptr;

    prmsg (2,"Accept(%d)\\n", ciptr->fd);

    newciptr = ciptr->transptr->Accept (ciptr, status);

    if (newciptr)
\tnewciptr->transptr = ciptr->transptr;

    return newciptr;
}
"""
    new = """XtransConnInfo
TRANS(Accept) (XtransConnInfo ciptr, int *status)

{
    XtransConnInfo\tnewciptr;
    Xtransport *transptr = ciptr ? ciptr->transptr : NULL;

    /* be300-tinyx: Xtrans Accept logging. */
    ErrorF("be300-xtrans: Accept entry ciptr=%p transptr=%p cb=%p fd=%d\\n",
           ciptr, transptr, transptr ? transptr->Accept : NULL,
           ciptr ? ciptr->fd : -1);

    if (!transptr || !transptr->Accept) {
\tif (status)
\t    *status = TRANS_ACCEPT_MISC_ERROR;
\tErrorF("be300-xtrans: Accept missing callback\\n");
\treturn NULL;
    }

    prmsg (2,"Accept(%d)\\n", ciptr->fd);

    newciptr = transptr->Accept (ciptr, status);
    ErrorF("be300-xtrans: Accept return new=%p status=%d\\n",
           newciptr, status ? *status : 0);

    if (newciptr)
\tnewciptr->transptr = transptr;

    return newciptr;
}
"""
    if old not in text:
        raise SystemExit(f"{xtrans_c}: Accept function anchor not found")
    text = text.replace(old, new, 1)
xtrans_c.write_text(text)
PY
    echo "--- Patched xtrans: local X server symbol binding ---"
}

# libX11 1.6.12 src/XlibInt.c only includes <sys/ioctl.h> inside
# `#ifdef XTHREADS`, but we configure with --disable-xthreads.  FIONREAD
# is then undeclared at line 1268.  Move the include above the guard.
patch_libX11_ioctl() {
    local f="$XORG_SRC_ROOT/libX11-${LIBX11}/src/XlibInt.c"
    [ -f "$f" ] || return 0
    if grep -q '^#ifdef XTHREADS$' "$f" \
        && ! grep -q 'be300-tinyx: unconditional sys/ioctl' "$f"; then
        # Insert unconditional #include <sys/ioctl.h> right after the
        # `#include <stdio.h>` near the top of the file.
        sed -i '/^#include <stdio.h>$/a\
/* be300-tinyx: unconditional sys/ioctl include so FIONREAD is visible\
   when --disable-xthreads moves the original include behind a guard. */\
#include <sys/ioctl.h>' "$f"
        echo "--- Patched $f: unconditional <sys/ioctl.h> ---"
    fi
}

# libXt 1.2.1 src/NextEvent.c defines _XtWaitForSomething with an
# unconditional `drop_lock` parameter (only needed under XTHREADS), but
# include/X11/InitialI.h declares it with `drop_lock` gated by
# `#ifdef XTHREADS`.  When --disable-xthreads, the prototype has 7 args
# and the definition has 8 — gcc reports "conflicting types" and every
# call site reports "too many arguments".  Make the declaration always
# include drop_lock so it matches the unconditional definition + calls.
patch_libXt_drop_lock() {
    local hdr="$XORG_SRC_ROOT/libXt-${LIBXT}/include/X11/InitialI.h"
    local shell="$XORG_SRC_ROOT/libXt-${LIBXT}/src/Shell.c"
    [ -f "$hdr" ] || return 0
    # Strip every #ifdef XTHREADS / ... drop_lock ... / #endif triplet
    # across the libXt sources so all sites (prototype, definition, calls)
    # see the same 8-arg signature.  Targets:
    #   include/X11/InitialI.h - prototype
    #   src/Shell.c            - call site (timeout-watching)
    python3 - "$hdr" "$shell" <<'PY'
import sys, re
changed = 0
already_patched = 0
considered = 0
for path in sys.argv[1:]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    considered += 1
    if 'be300-tinyx: always declare drop_lock' in src:
        already_patched += 1
        continue
    pattern = re.compile(
        r"^#ifdef\s+XTHREADS\s*\n"
        r"([^\n]*drop_lock[^\n]*\n|\s*FALSE,\s*\n)"
        r"#endif\s*\n",
        re.MULTILINE,
    )
    new_src, n = pattern.subn(
        "    /* be300-tinyx: always declare drop_lock so the prototype matches\n"
        "       the unconditional definition + call sites in NextEvent.c. */\n"
        "\\1",
        src,
    )
    if n > 0:
        open(path, 'w').write(new_src)
        print(f"[be300-tinyx] patched {n} XTHREADS/drop_lock site(s) in {path}", flush=True)
        changed += n
# success = anything got patched OR every considered file was already patched
if changed == 0 and already_patched != considered:
    sys.stderr.write(f"WARNING: no XTHREADS/drop_lock patches applied (considered={considered}, already_patched={already_patched})\n")
    sys.exit(1)
PY
    echo "--- Patched libXt: removed XTHREADS guards around drop_lock ---"
}

# ---------------------------------------------------------------------
# Cross-configure boilerplate (used by every library + app build)
# ---------------------------------------------------------------------
#
# tinyx_configure_install <src-dirname> <stage|rootfs|both> [extra configure flags ...]
#
#   - src-dirname: bare directory under $XORG_SRC_ROOT (e.g. "libX11-1.6.12")
#   - destination:
#       stage  - install only to $XORG_STAGE (for header-only / pkgconfig-only pkgs)
#       rootfs - install only to $ROOTFS    (for apps that don't get linked against)
#       both   - install to $XORG_STAGE then copy .so* files to $ROOTFS/usr/lib
#   - extra configure flags get appended verbatim
#
# Calls run in a per-package build dir under $LOG_DIR so reconfigures don't pollute
# the source tree.  Opcode scan runs against freshly-installed library files at the
# end of every call.

tinyx_configure_install() {
    local src="$1"; shift
    local mode="$1"; shift

    local src_dir="$XORG_SRC_ROOT/$src"
    [ -d "$src_dir" ] || { echo "MISSING source: $src_dir" >&2; return 1; }

    local build="$LOG_DIR/$src"
    mkdir -p "$build"

    if [ ! -f "$build/Makefile" ]; then
        echo "--- Configuring $src ---"
        # NOTE: PKG_CONFIG_SYSROOT_DIR is deliberately NOT set because it
        # only rewrites -I/-L flags returned by --cflags/--libs, not
        # variables fetched via pkg-config --variable=foo.  libxcb fetches
        # xcb-proto's xcbincludedir directly and uses the literal value in
        # its Makefile, which would break with SYSROOT prefix.  Instead we
        # post-process each staged .pc to bake $XORG_STAGE/usr into prefix=,
        # so both --cflags/--libs and --variable= return staged paths.
        #
        # *_FOR_BUILD overrides keep host-tool builds (e.g. libXt's makestrs)
        # from inheriting the cross CFLAGS — without that, host gcc picks up
        # the uClibc-ng sysroot's <unistd.h> via -isystem and fails to parse it.
        (
            cd "$build"
            PKG_CONFIG_LIBDIR="$XORG_STAGE/usr/lib/pkgconfig:$XORG_STAGE/usr/share/pkgconfig" \
            PKG_CONFIG_PATH="$XORG_STAGE/usr/lib/pkgconfig:$XORG_STAGE/usr/share/pkgconfig" \
            ACLOCAL_PATH="$XORG_STAGE/usr/share/aclocal" \
            CC="$TARGET_CC" CXX="$TARGET_CXX" \
            AR="$TARGET_AR" RANLIB="$TARGET_RANLIB" STRIP="$TARGET_STRIP" \
            CFLAGS="$COMMON_CFLAGS" \
            CPPFLAGS="-I$XORG_STAGE/usr/include $LIBC_CFLAGS ${CPPFLAGS_EXTRA:-}" \
            LDFLAGS="$COMMON_LFLAGS" \
            LIBS="$COMMON_LIBS" \
            CC_FOR_BUILD="gcc" \
            CFLAGS_FOR_BUILD="-O2" \
            CPPFLAGS_FOR_BUILD="" \
            LDFLAGS_FOR_BUILD="" \
            "$src_dir/configure" \
                --host=mipsel-linux-gnu \
                --build="$(uname -m)-pc-linux-gnu" \
                --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
                --disable-static --enable-shared \
                --disable-malloc0returnsnull \
                "$@" \
                >"$build/configure.log" 2>&1 \
            || { tail -60 "$build/configure.log" >&2; return 1; }
        ) || return 1
    fi

    echo "--- Building $src ---"
    if ! make -C "$build" -j"$(nproc)" >"$build/make.log" 2>&1; then
        # Print the first "error:" with surrounding context, then last 40 lines.
        echo "--- FAILED: $src ---" >&2
        echo "--- first error context (grep -B5) ---" >&2
        grep -B5 ': error:\|: fatal error:\|configure: error' "$build/make.log" 2>/dev/null | head -60 >&2 || true
        echo "--- last 40 lines of make.log ---" >&2
        tail -40 "$build/make.log" >&2
        return 1
    fi

    case "$mode" in
        stage)
            make -C "$build" DESTDIR="$XORG_STAGE" install >"$build/install.log" 2>&1 \
                || { tail -60 "$build/install.log" >&2; return 1; }
            tinyx_fix_staged_pc_prefixes
            tinyx_scan_dir "$XORG_STAGE/usr/lib" "$src"
            ;;
        rootfs)
            make -C "$build" DESTDIR="$ROOTFS" install >"$build/install.log" 2>&1 \
                || { tail -60 "$build/install.log" >&2; return 1; }
            tinyx_scan_dir "$ROOTFS/usr/bin" "$src"
            tinyx_scan_dir "$ROOTFS/usr/lib" "$src"
            ;;
        both)
            make -C "$build" DESTDIR="$XORG_STAGE" install >"$build/install.log" 2>&1 \
                || { tail -60 "$build/install.log" >&2; return 1; }
            tinyx_fix_staged_pc_prefixes
            tinyx_scan_dir "$XORG_STAGE/usr/lib" "$src"
            tinyx_copy_runtime_libs "$XORG_STAGE/usr/lib"
            ;;
        *)
            echo "tinyx_configure_install: unknown mode '$mode'" >&2
            return 1
            ;;
    esac
}

# X.Org modular .pc files are installed with prefix=/usr (autoconf default).
# When other packages run `pkg-config --variable=...` they get the literal
# /usr/... back, even though the actual files are staged under $XORG_STAGE.
# Rewrite prefix= to point at the absolute staged path so both --cflags/--libs
# and --variable=xcbincludedir/etc return paths that exist on disk.
tinyx_fix_staged_pc_prefixes() {
    local d
    for d in "$XORG_STAGE/usr/lib/pkgconfig" "$XORG_STAGE/usr/share/pkgconfig"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -name '*.pc' -type f -print0 \
            | while IFS= read -r -d '' pc; do
                # Only rewrite if prefix=/usr (i.e. autoconf default).  If a
                # package already baked in $XORG_STAGE, leave it alone.
                if grep -q '^prefix=/usr$' "$pc" 2>/dev/null; then
                    sed -i "s|^prefix=/usr$|prefix=$XORG_STAGE/usr|" "$pc"
                fi
            done
    done

    # libtool .la archives bake in libdir=/usr/lib which doesn't exist when
    # cross-compiling.  When a downstream library/program is linked, libtool
    # resolves -lXau through the .la file and tries to open /usr/lib/libXau.la
    # — which is empty/missing — and errors out.  The standard fix is to
    # delete .la files post-install.  Libtool falls back to direct -lXau
    # against the .so, which works regardless of host paths.
    if [ -d "$XORG_STAGE/usr/lib" ]; then
        find "$XORG_STAGE/usr/lib" -maxdepth 1 -name '*.la' -delete 2>/dev/null || true
    fi
}

tinyx_copy_runtime_libs() {
    local from="$1"
    [ -d "$from" ] || return 0
    mkdir -p "$ROOTFS/usr/lib"
    # Only ship the .so* runtime files; skip .a static libs, .la archives,
    # and pkgconfig (handled by the host stage tree, never needed at runtime).
    find "$from" -maxdepth 1 -name '*.so*' -type f -exec cp -a {} "$ROOTFS/usr/lib/" \;
    find "$from" -maxdepth 1 -name '*.so*' -type l -exec cp -a {} "$ROOTFS/usr/lib/" \;
}

tinyx_scan_dir() {
    local dir="$1"
    local label="$2"
    [ -d "$dir" ] || return 0
    local f bad
    while IFS= read -r f; do
        [ -e "$f" ] || continue
        bad=$(unsupported_mips2_insn "$f")
        if [ -n "$bad" ]; then
            echo "ERROR: [$label] $f contains VR4131-unsupported opcode: $bad" >&2
            return 1
        fi
    done < <(find "$dir" -maxdepth 1 -type f \
                 \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) \
                 2>/dev/null | sort)
}

# Host-only configure used for util-macros (m4) and xkbcomp.  No --host flag,
# no cross CC.  Installs into $XORG_HOST.
tinyx_host_install() {
    local src="$1"; shift
    local src_dir="$XORG_SRC_ROOT/$src"
    [ -d "$src_dir" ] || { echo "MISSING source: $src_dir" >&2; return 1; }
    local build="$LOG_DIR/host-$src"
    mkdir -p "$build"
    if [ ! -f "$build/Makefile" ]; then
        echo "--- Configuring host $src ---"
        # Pass --build explicitly because older X.Org tarballs ship a
        # config.guess that predates aarch64 (Apple Silicon / OrbStack).
        (
            cd "$build"
            PKG_CONFIG_LIBDIR="$XORG_HOST/usr/lib/pkgconfig" \
            PKG_CONFIG_PATH="$XORG_HOST/usr/lib/pkgconfig" \
            ACLOCAL_PATH="$XORG_HOST/usr/share/aclocal" \
            "$src_dir/configure" \
                --build="$(uname -m)-pc-linux-gnu" \
                --prefix="$XORG_HOST/usr" \
                "$@" \
                >"$build/configure.log" 2>&1 \
            || { tail -60 "$build/configure.log" >&2; return 1; }
        ) || return 1
    fi
    echo "--- Building host $src ---"
    make -C "$build" -j"$(nproc)" >"$build/make.log" 2>&1 \
        || { tail -80 "$build/make.log" >&2; return 1; }
    make -C "$build" install >"$build/install.log" 2>&1 \
        || { tail -60 "$build/install.log" >&2; return 1; }
}

# ---------------------------------------------------------------------
# T6. Host helpers — util-macros (target + host) and host xkbcomp
# ---------------------------------------------------------------------

build_host_helpers() {
    echo "=== Building host helpers (util-macros only) ==="
    # util-macros is autoconf m4 fragments; install once into the target stage
    # so subsequent target configures pick up XORG_MACROS via aclocal, then
    # again into the host stage for util-macros-aware host-side tools.
    tinyx_configure_install "util-macros-${UTIL_MACROS}" stage
    tinyx_host_install      "util-macros-${UTIL_MACROS}"
    # We do NOT build host xkbcomp from source — the xkbcomp-1.2.4 tarball
    # ships a config.guess from 2010 that can't identify aarch64 build hosts
    # (Apple Silicon / OrbStack containers), and a from-source host xkbcomp
    # would need libX11 dev headers on the build host anyway.  ensure_autotools
    # already apt-installs x11-xkb-utils which provides /usr/bin/xkbcomp;
    # compile_xkb_keymap() picks it up via $(command -v xkbcomp).
}

tinyx_install_legacy_proto_shims() {
    local d="$XORG_STAGE/usr/include/X11/extensions"
    mkdir -p "$d"
    cat > "$d/xteststr.h" <<'EOF'
/* be300-tinyx: legacy xteststr.h shim — xextproto 7.3 split this into
   xtestproto.h (struct definitions) and xtestconst.h (constants). */
#ifndef _XTESTSTR_H_
#define _XTESTSTR_H_
#include <X11/extensions/xtestproto.h>
#include <X11/extensions/xtestconst.h>
#endif
EOF
    cat > "$d/dpmsstr.h" <<'EOF'
/* be300-tinyx: legacy dpmsstr.h shim. */
#ifndef _DPMSSTR_H_
#define _DPMSSTR_H_
#include <X11/extensions/dpmsproto.h>
#include <X11/extensions/dpmsconst.h>
#endif
EOF
    cat > "$d/xtestext1.h" <<'EOF'
/* be300-tinyx: legacy xtestext1.h shim. */
#ifndef _XTESTEXT1_H_
#define _XTESTEXT1_H_
#include <X11/extensions/xtestext1proto.h>
#include <X11/extensions/xtestext1const.h>
#endif
EOF
}

# ---------------------------------------------------------------------
# T7. Protocol headers (header-only / pkgconfig-only packages)
# ---------------------------------------------------------------------

build_protocol_headers() {
    echo "=== Building X11 protocol header packages ==="
    tinyx_configure_install "xproto-${XPROTO}"           stage
    tinyx_configure_install "xextproto-${XEXTPROTO}"     stage
    # xextproto 7.3 renamed the legacy xteststr.h / dpmsstr.h headers
    # (and others) into xtestproto.h+xtestconst.h / dpmsproto.h+dpmsconst.h.
    # xorg-server-1.6.5 still references the old names; ship compatibility
    # shims so the build finds them at <X11/extensions/xteststr.h> etc.
    tinyx_install_legacy_proto_shims
    tinyx_configure_install "kbproto-${KBPROTO}"         stage
    tinyx_configure_install "inputproto-${INPUTPROTO}"   stage
    tinyx_configure_install "fontsproto-${FONTSPROTO}"   stage
    tinyx_configure_install "randrproto-${RANDRPROTO}"   stage
    tinyx_configure_install "renderproto-${RENDERPROTO}" stage
    tinyx_configure_install "fixesproto-${FIXESPROTO}"   stage
    tinyx_configure_install "damageproto-${DAMAGEPROTO}" stage
    tinyx_configure_install "xcmiscproto-${XCMISCPROTO}" stage
    tinyx_configure_install "bigreqsproto-${BIGREQSPROTO}" stage
    tinyx_configure_install "resourceproto-${RESOURCEPROTO}" stage
    tinyx_configure_install "compositeproto-${COMPOSITEPROTO}" stage
    tinyx_configure_install "recordproto-${RECORDPROTO}" stage
    tinyx_configure_install "xtrans-${XTRANS}"           stage
}

# ---------------------------------------------------------------------
# T8. Auth + XCB transport
# ---------------------------------------------------------------------

build_libxau_xcb() {
    echo "=== Building libXau, libXdmcp, xcb-proto, libxcb, libpthread-stubs ==="
    tinyx_configure_install "libXau-${XAU}"                       both
    tinyx_configure_install "libXdmcp-${XDMCP}"                   both
    tinyx_configure_install "libpthread-stubs-${PTHREAD_STUBS}"   stage

    # xcb-proto installs only python codegen + .xml protocol descriptions
    # plus a pkgconfig file; it's effectively a build-time data package.
    # Configure host-style (no cross CC) so its python wrappers land where
    # libxcb's codegen can find them.  Then ensure it's also in the target
    # stage for libxcb's target configure.
    tinyx_host_install      "xcb-proto-${XCBPROTO}"
    tinyx_configure_install "xcb-proto-${XCBPROTO}"               stage

    # libxcb's codegen uses host python.  PYTHON env points it at the host;
    # PKG_CONFIG sees xcb-proto in $XORG_STAGE.
    PYTHON=python3 \
        tinyx_configure_install "libxcb-${LIBXCB}"                both \
            --enable-xinput=no --enable-xkb=no \
            --enable-render=yes --enable-randr=yes
}

# ---------------------------------------------------------------------
# T8b. zlib (libfontenc dependency — required even with --disable-freetype)
# ---------------------------------------------------------------------

build_zlib() {
    local ver="1.3.1"
    local archive="$ARCHIVES/zlib-${ver}.tar.gz"
    local build="$LOG_DIR/zlib-${ver}"
    if [ -f "$ROOTFS/usr/lib/libz.so" ]; then
        echo "=== zlib already built (reusing) ==="
        return 0
    fi
    download_archive "https://github.com/madler/zlib/releases/download/v${ver}/zlib-${ver}.tar.gz" "$archive"

    rm -rf "$build"
    mkdir -p "$build"
    ( cd "$build"
      tar xzf "$archive" --strip-components=1
      # zlib's hand-rolled configure honors CC/CFLAGS env; --shared builds
      # libz.so + libz.so.1.  Install to both $XORG_STAGE (build-time
      # headers + .so symlink) and $ROOTFS (runtime libz.so.1).
      CC="$TARGET_CC" \
      CFLAGS="$ARCH_CFLAGS -Os -fno-stack-protector $LIBC_CFLAGS" \
      CHOST="mipsel-linux-gnu" \
        ./configure --prefix=/usr --shared
      make -j"$(nproc)"
      make DESTDIR="$XORG_STAGE" install
      make DESTDIR="$ROOTFS"     install
    )
    # Same .pc prefix rewrite we apply elsewhere
    tinyx_fix_staged_pc_prefixes
    if [ ! -f "$XORG_STAGE/usr/include/zlib.h" ]; then
        echo "ERROR: zlib install did not produce zlib.h" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------
# T9. Core X11 client libraries
# ---------------------------------------------------------------------

build_core_x11() {
    echo "=== Building core X11 libraries (libX11..libXaw) ==="

    # libX11: the elephant.  Disabling loadable i18n cuts ~600 KB of
    # /usr/lib/X11/locale; disabling xthreads removes pthread coupling
    # that we don't need (xterm and matchbox are single-threaded).
    # --disable-ipv6 is xtrans.m4's option; BE-300 has no IPv6 stack and
    # uClibc-ng's in6addr_any visibility is gated by config we don't enable.
    tinyx_configure_install "libX11-${LIBX11}"           both \
        --with-xcb \
        --disable-xthreads --disable-xthreads-warning \
        --disable-loadable-i18n --disable-composecache \
        --disable-specs --disable-xf86bigfont \
        --disable-ipv6 \
        --without-launchd

    tinyx_configure_install "libXext-${LIBXEXT}"         both
    tinyx_configure_install "libICE-${LIBICE}"           both --without-launchd --disable-ipv6
    tinyx_configure_install "libSM-${LIBSM}"             both --without-launchd --disable-ipv6
    tinyx_configure_install "libXrender-${LIBXRENDER}"   both
    tinyx_configure_install "libfontenc-${LIBFONTENC}"   both \
        --with-encodingsdir=/usr/share/X11/fonts/encodings

    # libXfont: PCF + builtin BDF only — no freetype, no fontconfig.
    # Keeps freetype 2.3's bytecode loops (potential MIPS32 op emitter)
    # out of the rootfs entirely.
    tinyx_configure_install "libXfont-${LIBXFONT}"       both \
        --disable-freetype --enable-builtins --disable-fc

    tinyx_configure_install "libxkbfile-${LIBXKBFILE}"   both
    tinyx_configure_install "libXpm-${LIBXPM}"           both \
        --disable-open-zfile
    # libXfixes is a libXi dependency (xfixes pkgconfig).
    tinyx_configure_install "libXfixes-${LIBXFIXES}"     both
    # libXi is a libXtst dependency (and provides input-extension client API).
    tinyx_configure_install "libXi-${LIBXI}"             both
    # libXtst is needed only for its <X11/extensions/XTest.h> header —
    # xorg-server's modinit.h pulls it in for the XTEST extension.
    tinyx_configure_install "libXtst-${LIBXTST}"         both
    tinyx_configure_install "libXt-${LIBXT}"             both \
        --with-appdefaultdir=/etc/X11/app-defaults
    tinyx_configure_install "libXmu-${LIBXMU}"           both
    tinyx_configure_install "libXaw-${LIBXAW}"           both --disable-xprint
}

# ---------------------------------------------------------------------
# T10. Pixman (used by libX11 RENDER and xorg-server)
# ---------------------------------------------------------------------

build_pixman() {
    echo "=== Building pixman ==="
    # MIPS DSPr2 ASM uses MIPS32R2 ops; ARM SIMD/NEON/IWMMXT obviously
    # don't apply on MIPS.  --disable-gtk avoids pulling in the GTK demo
    # programs we don't ship.
    tinyx_configure_install "pixman-${PIXMAN}" both \
        --disable-mips-dspr2 \
        --disable-arm-simd --disable-arm-neon --disable-arm-iwmmxt \
        --disable-gtk
}

# ---------------------------------------------------------------------
# T11. xorg-server 1.6.5.901 — kdrive Xfbdev only
# ---------------------------------------------------------------------
#
# patch_xorg_sources() already ran in main() before this point and
# modernized the autoconf macros + dropped HAL/UDEV PKG_CHECK_MODULES.
# We still run autoreconf -fi to regenerate the configure script from
# the patched configure.ac.

build_xorg_server() {
    local src="xorg-server-${XORG_SERVER}"
    local src_dir="$XORG_SRC_ROOT/$src"
    [ -d "$src_dir" ] || { echo "MISSING source: $src_dir" >&2; return 1; }

    echo "=== Regenerating xorg-server autoconf tree ==="
    (
        cd "$src_dir"
        if [ ! -f .be300-autoreconfd ]; then
            ACLOCAL_PATH="$XORG_STAGE/usr/share/aclocal:$XORG_HOST/usr/share/aclocal:/usr/share/aclocal" \
                autoreconf -fi >"$LOG_DIR/$src.autoreconf.log" 2>&1 \
                || { tail -60 "$LOG_DIR/$src.autoreconf.log" >&2; return 1; }
            touch .be300-autoreconfd
        fi
    ) || return 1

    echo "=== Configuring kdrive Xfbdev ==="
    # Composite is not needed for the BE-300 matchbox/rxvt profile, and its
    # screen BlockHandler path is fragile on this MIPS/uClibc build.  If this
    # tree was configured before the flag was added, force just the server
    # configure step to rerun with the leaner extension set.
    if [ -f "$LOG_DIR/$src/configure.log" ] \
            && ! grep -q -- '--disable-composite' "$LOG_DIR/$src/configure.log"; then
        rm -rf "$LOG_DIR/$src"
    fi
    # be300-tinyx: -Bsymbolic-functions tells ld to resolve all function
    # references inside the executable to their local definition at static
    # link time, instead of going through dynamic-loader GOT slots that
    # uClibc-ng's resolver leaves zero on this target.
    local _saved_common_cflags="$COMMON_CFLAGS"
    local _saved_common_lflags="$COMMON_LFLAGS"
    COMMON_LFLAGS="$_saved_common_lflags -Wl,-Bsymbolic-functions"
    tinyx_configure_install "$src" rootfs \
        --enable-kdrive --enable-xfbdev --enable-input-linux \
        --disable-xorg --disable-xnest --disable-xvfb --disable-xephyr --disable-xfake \
        --disable-xwin --disable-xdmx \
        --disable-dri --disable-dri2 --disable-glx --disable-aiglx --disable-dga \
        --disable-xinerama --disable-xv --disable-xvmc --disable-record \
        --disable-composite \
        --disable-screensaver --disable-xres --disable-xselinux \
        --disable-xfree86-utils --disable-install-libxf86config \
        --disable-builtin-fonts --disable-config-hal --disable-config-udev \
        --disable-libdrm --disable-tslib --disable-unit-tests \
        --disable-ipv6 \
        --disable-dbe --disable-mitshm --disable-xtrap --disable-multibuffer \
        --with-xkb-bin-directory=/usr/bin \
        --with-xkb-path=/usr/share/X11/xkb \
        --with-default-font-path=/usr/share/X11/fonts/misc \
        --with-fontdir=/usr/share/X11/fonts \
        --without-dtrace --without-doxygen --without-xmlto --without-fop

    # kdrive installs the server as $ROOTFS/usr/bin/Xfbdev; verify and
    # opcode-scan it explicitly so a regression fails the build instead
    # of silently shipping a server that SIGILLs on first launch.
    if [ ! -x "$ROOTFS/usr/bin/Xfbdev" ]; then
        echo "ERROR: Xfbdev did not install to \$ROOTFS/usr/bin/Xfbdev" >&2
        COMMON_CFLAGS="$_saved_common_cflags"
        COMMON_LFLAGS="$_saved_common_lflags"
        return 1
    fi
    local bad
    bad="$(unsupported_mips2_insn "$ROOTFS/usr/bin/Xfbdev")"
    if [ -n "$bad" ]; then
        echo "ERROR: Xfbdev contains VR4131-unsupported opcode: $bad" >&2
        COMMON_CFLAGS="$_saved_common_cflags"
        COMMON_LFLAGS="$_saved_common_lflags"
        return 1
    fi
    echo "--- Xfbdev built and opcode-scan clean ---"
    COMMON_CFLAGS="$_saved_common_cflags"
    COMMON_LFLAGS="$_saved_common_lflags"
}

# ---------------------------------------------------------------------
# T12. libmatchbox + matchbox-window-manager
# ---------------------------------------------------------------------

build_matchbox() {
    echo "=== Building libmatchbox + matchbox-window-manager ==="
    # libmatchbox provides the shared infrastructure (settings cache, theme
    # XML reader, image loader stubs).  Disable the heavyweight image
    # codecs and font subsystems we don't need; matchbox-wm uses
    # libmatchbox's stubs in that case.
    # libmatchbox's mbconfig.h unconditionally `#define`s USE_PNG / USE_XFT
    # / USE_JPG / USE_PANGO / USE_EXPAT even when we --disable-* them.
    # Comment them all out so libmb/{mbpixbuf,mbexp,mbdotdesktop}.h skip the
    # corresponding headers we don't ship.
    local mbcfg="${XORG_SRC_ROOT}/libmatchbox-${MATCHBOX_COMMON}/libmb/mbconfig.h"
    if [ -f "$mbcfg" ] && ! grep -q "be300-tinyx: skip optional defines" "$mbcfg"; then
        sed -i \
            -e 's|^#define USE_PNG.*$|/* be300-tinyx: skip optional defines */|' \
            -e 's|^#define USE_XFT.*$|/* be300-tinyx: skip optional defines (xft) */|' \
            -e 's|^#define USE_JPG.*$|/* be300-tinyx: skip optional defines (jpg) */|' \
            -e 's|^#define USE_PANGO.*$|/* be300-tinyx: skip optional defines (pango) */|' \
            -e 's|^#define USE_EXPAT.*$|/* be300-tinyx: skip optional defines (expat) */|' \
            "$mbcfg"
    fi

    # libmatchbox's tests/ subdir builds binaries that need an explicit
    # `-lX11 -lXext` on their link line, which the upstream Makefile.am
    # misses.  We only need libmb.so itself; skip the tests entirely.
    local mbam="${XORG_SRC_ROOT}/libmatchbox-${MATCHBOX_COMMON}/Makefile.am"
    if [ -f "$mbam" ] && grep -q "^SUBDIRS=libmb doc tests$" "$mbam"; then
        sed -i 's|^SUBDIRS=libmb doc tests$|SUBDIRS=libmb doc|' "$mbam"
    fi
    local mbmkin="${XORG_SRC_ROOT}/libmatchbox-${MATCHBOX_COMMON}/Makefile.in"
    if [ -f "$mbmkin" ]; then
        sed -i 's|^SUBDIRS = libmb doc tests$|SUBDIRS = libmb doc|' "$mbmkin"
    fi

    # CPPFLAGS_EXTRA: libmatchbox's Makefile.am misses -I$(top_srcdir),
    # so libmb/foo.c can't find "libmb/bar.h".  Inject it.
    CPPFLAGS_EXTRA="-I${XORG_SRC_ROOT}/libmatchbox-${MATCHBOX_COMMON}" \
    tinyx_configure_install "libmatchbox-${MATCHBOX_COMMON}" both \
        --disable-png --disable-jpeg \
        --disable-xft --disable-pango \
        --disable-startup-notification \
        --disable-xsettings \
        --disable-expat

    # matchbox-window-manager 1.2 src/structs.h only defines DEFAULTTHEME /
    # DEFAULTTHEMENAME (no underscore variants used by mbtheme.c) inside
    # an `#ifdef MB_HAVE_PNG` block.  Without PNG support we hit undeclared
    # identifier errors.  Add the alias defines to the #else branch.
    local sh="${XORG_SRC_ROOT}/matchbox-window-manager-${MATCHBOX_WM}/src/structs.h"
    if [ -f "$sh" ] && ! grep -q "be300-tinyx: alias DEFAULTTHEME" "$sh"; then
        python3 - "$sh" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
needle = '#define DEFAULT_THEME_NAME  "Default"\n\n#endif'
repl = (
    '#define DEFAULT_THEME_NAME  "Default"\n'
    '/* be300-tinyx: alias DEFAULTTHEME / DEFAULTTHEMENAME so mbtheme.c\n'
    '   compiles without MB_HAVE_PNG. */\n'
    '#define DEFAULTTHEME        DEFAULT_THEME\n'
    '#define DEFAULTTHEMENAME    DEFAULT_THEME_NAME\n\n#endif'
)
if needle in src:
    open(path, 'w').write(src.replace(needle, repl, 1))
PY
    fi

    tinyx_configure_install "matchbox-window-manager-${MATCHBOX_WM}" rootfs \
        --disable-xft --disable-libpng --disable-jpeg \
        --disable-startup-notification \
        --disable-xsettings --disable-expat

    if [ ! -x "$ROOTFS/usr/bin/matchbox-window-manager" ]; then
        echo "ERROR: matchbox-window-manager did not install to \$ROOTFS/usr/bin/" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------
# T13. Terminal (rxvt 2.7.10 default; xterm 253 optional)
# ---------------------------------------------------------------------

build_terminal() {
    echo "=== Building terminal: ${BE300_TINYX_TERMINAL} ==="
    if [ "$BE300_TINYX_TERMINAL" = "rxvt" ]; then
        # rxvt's ptytty.c includes <sys/stropts.h> when PTYS_ARE_PTMX is set,
        # but Linux/uClibc-ng has no STREAMS headers (only Solaris does).
        # Comment out the include — the I_PUSH ioctl isn't needed on Linux.
        local ptt="${XORG_SRC_ROOT}/rxvt-${RXVT}/src/ptytty.c"
        if [ -f "$ptt" ] && ! grep -q "be300-tinyx: skip stropts" "$ptt"; then
            sed -i 's|^# include <sys/stropts\.h>.*$|/* be300-tinyx: skip stropts.h — Linux has no STREAMS */|' "$ptt"
        fi
        # --disable-shared --enable-static: rxvt 2.7.10's Makefile.in links
        # rxvt against librxvt.la.  With libtool's shared mode disabled,
        # librxvt's objects fold into the rxvt binary instead of producing a
        # dynamic librxvt.so.1.  matchbox-window-manager, matchbox-remote, and
        # be300-xfillroot all connect to ":0" via libX11 directly with no
        # trouble, so eliminating the librxvt.so.1 transport sidesteps the
        # "can't open display unix:0" failure that surfaced under uClibc-ng's
        # dynamic loader.  The rxvt binary still dynamically links libX11.
        # (Args after "$@" override tinyx_configure_install's earlier
        # --disable-static --enable-shared defaults.)
        tinyx_configure_install "rxvt-${RXVT}" rootfs \
            --disable-xim --disable-xft --disable-frills \
            --disable-mousewheel --disable-perl \
            --disable-resources --disable-utmp --disable-wtmp --disable-lastlog \
            --disable-transparency \
            --disable-shared --enable-static
        if [ ! -x "$ROOTFS/usr/bin/rxvt" ]; then
            echo "ERROR: rxvt did not install to \$ROOTFS/usr/bin/rxvt" >&2
            return 1
        fi
        # If libtool installed a stray librxvt.so.* anyway (older libtool
        # macros sometimes ignore --disable-shared if -version-info is set),
        # drop it so the rxvt binary cannot accidentally pick it up at
        # runtime via RPATH.
        rm -f "$ROOTFS/usr/lib"/librxvt.so* "$ROOTFS/usr/lib"/librxvt.la \
              "$ROOTFS/usr/lib"/librxvt.a 2>/dev/null || true
    else
        tinyx_configure_install "xterm-${XTERM}" rootfs \
            --disable-luit --disable-tek4014 --disable-toolbar \
            --disable-imake \
            --disable-xft --disable-fontconfig \
            --without-Xaw3d --without-Xaw3dxft \
            --disable-i18n --disable-mini-luit \
            --disable-input-method
        if [ ! -x "$ROOTFS/usr/bin/xterm" ]; then
            echo "ERROR: xterm did not install to \$ROOTFS/usr/bin/xterm" >&2
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------
# T14. BE-300 X helpers
# ---------------------------------------------------------------------

build_be300_x_helpers() {
    echo "=== Building BE-300 TinyX Xlib helpers ==="
    ${TARGET_CC} ${COMMON_CFLAGS} \
        "$BOARD_DIR/be300_xfillroot.c" \
        ${LIBC_LDFLAGS} \
        -Wl,--gc-sections -Wl,--copy-dt-needed-entries \
        -Wl,-rpath-link,"${XORG_STAGE}/usr/lib" \
        -L"${XORG_STAGE}/usr/lib" \
        -lX11 -lxcb -lXau -lXdmcp \
        -o "$ROOTFS/usr/bin/be300-xfillroot"
    be300_strip_binary "$ROOTFS/usr/bin/be300-xfillroot"

    # be300-xstatus is the steady-state visible client.  matchbox in
    # single-fullscreen mode does not paint anything itself once it owns the
    # root, so without a mapped top-level the LCD ends up flat.  xstatus draws
    # banner + clock + uptime + eth0 IP and repaints every second; the start
    # script launches it right after matchbox and respawns it on exit.
    ${TARGET_CC} ${COMMON_CFLAGS} \
        "$BOARD_DIR/be300_xstatus.c" \
        ${LIBC_LDFLAGS} \
        -Wl,--gc-sections -Wl,--copy-dt-needed-entries \
        -Wl,-rpath-link,"${XORG_STAGE}/usr/lib" \
        -L"${XORG_STAGE}/usr/lib" \
        -lX11 -lxcb -lXau -lXdmcp \
        -o "$ROOTFS/usr/bin/be300-xstatus"
    be300_strip_binary "$ROOTFS/usr/bin/be300-xstatus"

    # be300-tinyx-launcher: 240x18 top dock with [Term][Stat][Kbd] buttons.
    # Maps as _NET_WM_WINDOW_TYPE_DOCK + _NET_WM_STRUT_PARTIAL so matchbox
    # reserves the strip; buttons fork/exec rxvt + xstatus + SIGUSR1 to OSK.
    ${TARGET_CC} ${COMMON_CFLAGS} \
        "$BOARD_DIR/be300_tinyx_launcher.c" \
        ${LIBC_LDFLAGS} \
        -Wl,--gc-sections -Wl,--copy-dt-needed-entries \
        -Wl,-rpath-link,"${XORG_STAGE}/usr/lib" \
        -L"${XORG_STAGE}/usr/lib" \
        -lX11 -lxcb -lXau -lXdmcp \
        -o "$ROOTFS/usr/bin/be300-tinyx-launcher"
    be300_strip_binary "$ROOTFS/usr/bin/be300-tinyx-launcher"

    # be300-tinyx-osk: 240x90 on-screen keyboard pinned to the bottom of the
    # screen.  Originally synthesized keys via XTestFakeKeyEvent, but the
    # xorg-server-1.6.5 XTEST dispatch faults on first request (likely
    # XACE/dispatch patch interaction); XTest calls disabled in the OSK
    # source until the server-side handler is fixed.  Still draws the grid,
    # tracks layer state, and logs taps for forensics.  Drop -lXtst -lXi
    # because we no longer call those libs.  SIGUSR1 toggles map/unmap; the
    # launcher's [Kbd] button sends it.
    ${TARGET_CC} ${COMMON_CFLAGS} \
        "$BOARD_DIR/be300_tinyx_osk.c" \
        ${LIBC_LDFLAGS} \
        -Wl,--gc-sections -Wl,--copy-dt-needed-entries \
        -Wl,-rpath-link,"${XORG_STAGE}/usr/lib" \
        -L"${XORG_STAGE}/usr/lib" \
        -lX11 -lxcb -lXau -lXdmcp \
        -o "$ROOTFS/usr/bin/be300-tinyx-osk"
    be300_strip_binary "$ROOTFS/usr/bin/be300-tinyx-osk"
}

# ---------------------------------------------------------------------
# T15. XKB keymap precompile
# ---------------------------------------------------------------------

compile_xkb_keymap() {
    echo "=== Pre-compiling XKB keymap us.xkm ==="
    local host_xkbcomp="$XORG_HOST/usr/bin/xkbcomp"
    if [ ! -x "$host_xkbcomp" ]; then
        # Fallback to the system xkbcomp installed by ensure_autotools.
        host_xkbcomp="$(command -v xkbcomp || true)"
    fi
    if [ -z "$host_xkbcomp" ] || [ ! -x "$host_xkbcomp" ]; then
        echo "ERROR: no host xkbcomp available; ensure_autotools needs to install x11-xkb-utils" >&2
        return 1
    fi

    local out="$ROOTFS/usr/share/X11/xkb/compiled/us.xkm"
    mkdir -p "$(dirname "$out")"

    # -xkm tells xkbcomp to emit a binary keymap.  Resolve includes
    # against the host xkb-data tree (/usr/share/X11/xkb/...).
    "$host_xkbcomp" \
        -I/usr/share/X11/xkb \
        -I"$BOARD_DIR" \
        -xkm \
        "$BOARD_DIR/keymap.us.xkb" \
        "$out" \
        >"$LOG_DIR/xkbcomp.log" 2>&1 \
    || { tail -40 "$LOG_DIR/xkbcomp.log" >&2; return 1; }

    if [ ! -s "$out" ]; then
        echo "ERROR: xkbcomp produced empty $out" >&2
        return 1
    fi
    echo "--- compiled $(ls -l "$out" | awk '{print $5}') bytes -> $out ---"
}

# ---------------------------------------------------------------------
# T16. Bitmap fonts (PCF only)
# ---------------------------------------------------------------------

install_fonts() {
    echo "=== Building and installing PCF bitmap fonts ==="
    # font-util provides bdftopcf + the fontutil.pc that font-misc-misc and
    # font-cursor-misc require via PKG_CHECK_MODULES.
    tinyx_configure_install "font-util-${FONT_UTIL}" stage
    # font-misc-misc and font-cursor-misc are mostly bdftopcf + gzip rules
    # with autoconf-style install.  The cross-configure machinery is fine
    # because the build runs no compiled code (the font compilation uses
    # host bdftopcf, which ensure_autotools installs).
    tinyx_configure_install "font-misc-misc-${FONT_MISC_MISC}"     rootfs \
        --with-fontrootdir=/usr/share/X11/fonts \
        --without-fop --without-xmlto
    tinyx_configure_install "font-cursor-misc-${FONT_CURSOR_MISC}" rootfs \
        --with-fontrootdir=/usr/share/X11/fonts \
        --without-fop --without-xmlto

    local font_dir="$ROOTFS/usr/share/X11/fonts/misc"
    if [ ! -d "$font_dir" ]; then
        echo "ERROR: font install did not populate $font_dir" >&2
        return 1
    fi

    # Keep only the three fonts the launcher + matchbox + xterm use.
    # Everything else is deleted to claw back JFFS2 space.
    local keep_pat='^(6x13|fixed|cursor)\.pcf'
    find "$font_dir" -maxdepth 1 -type f \
        \( -name '*.pcf' -o -name '*.pcf.gz' -o -name '*.bdf' \) \
        -print0 \
        | while IFS= read -r -d '' f; do
            base="$(basename "$f")"
            if ! echo "$base" | grep -Eq "$keep_pat"; then
                rm -f "$f"
            fi
        done

    # mkfontdir runs on the host but operates on a directory tree, so
    # cross-compilation is a no-op here.
    if command -v mkfontdir >/dev/null 2>&1; then
        (cd "$font_dir" && mkfontdir)
    elif command -v mkfontscale >/dev/null 2>&1; then
        # Some Debian variants split mkfontdir into mkfontscale.
        (cd "$font_dir" && mkfontscale)
    else
        echo "WARNING: mkfontdir not found; fonts.dir will be missing" >&2
    fi

    if [ ! -s "$font_dir/fonts.dir" ]; then
        echo "WARNING: $font_dir/fonts.dir is empty or missing" >&2
    fi

    if [ -s "$font_dir/6x13.pcf.gz" ] || [ -s "$font_dir/6x13.pcf" ]; then
        cat > "$font_dir/fonts.alias" <<'EOF'
fixed -misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso10646-1
6x13 -misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso10646-1
EOF
    fi

    echo "--- installed fonts ---"
    ls -l "$font_dir"
}

install_matchbox_rc() {
    install -D -m 0644 "$BOARD_DIR/matchbox-window-manager.rc" \
        "$ROOTFS/etc/matchbox/matchbox-window-manager.rc"
}

prune_install() {
    [ -d "$ROOTFS/usr" ] || return 0
    rm -rf "$ROOTFS/usr/include" "$ROOTFS/usr/share/man" \
           "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/info" \
           "$ROOTFS/usr/share/locale" "$ROOTFS/usr/share/aclocal" \
           "$ROOTFS/usr/share/pkgconfig" "$ROOTFS/usr/lib/pkgconfig" \
           "$ROOTFS/usr/lib/cmake" 2>/dev/null || true
    find "$ROOTFS/usr/lib" \( -name '*.la' -o -name '*.a' \) -delete 2>/dev/null || true
    find "$ROOTFS/usr/share/X11/locale" -mindepth 1 -delete 2>/dev/null || true
}

strip_tinyx_artifacts() {
    for f in Xfbdev matchbox-window-manager xterm rxvt \
             be300-xstatus be300-xfillroot \
             be300-tinyx-launcher be300-tinyx-osk; do
        [ -x "$ROOTFS/usr/bin/$f" ] && be300_strip_binary "$ROOTFS/usr/bin/$f"
    done
    if [ -d "$ROOTFS/usr/lib" ]; then
        while IFS= read -r f; do
            be300_strip_binary "$f"
        done < <(find "$ROOTFS/usr/lib" -name '*.so*' -type f 2>/dev/null)
    fi
}

# ---------------------------------------------------------------------
# Rootfs scaffolding (always runs; cheap)
# ---------------------------------------------------------------------

prepare_layout() {
    mkdir -p \
        "$ROOTFS/usr/bin" \
        "$ROOTFS/usr/lib" \
        "$ROOTFS/usr/share/X11/xkb/compiled" \
        "$ROOTFS/usr/share/X11/fonts/misc" \
        "$ROOTFS/etc/matchbox" \
        "$ROOTFS/var/log"
}

# ---------------------------------------------------------------------
# Top-level driver
# ---------------------------------------------------------------------

main() {
    ensure_autotools
    prepare_support_libs
    load_versions
    prepare_layout

    if [ -f "$XORG_SRC_ROOT/$TINYX_BUILD_STAMP" ] && [ "$BE300_TINYX_SKIP_BUILD" != "0" ]; then
        echo "=== TinyX skeleton stamp present and SKIP_BUILD=1 — nothing to do ==="
        return 0
    fi

    download_all
    extract_all
    patch_xorg_sources

    if [ "$BE300_TINYX_SKIP_BUILD" = "1" ]; then
        echo "=== TinyX skeleton complete (BE300_TINYX_SKIP_BUILD=1) ==="
        echo "=== Sources extracted to $XORG_SRC_ROOT; no compilation yet ==="
        echo "=== /bin/start-tinyx will hit the 'Xfbdev failed to start' branch ==="
        touch "$XORG_SRC_ROOT/$TINYX_BUILD_STAMP"
        install_matchbox_rc
        return 0
    fi

    build_host_helpers
    build_protocol_headers
    build_libxau_xcb
    build_zlib
    build_core_x11
    build_pixman
    build_xorg_server
    build_matchbox
    build_terminal
    build_be300_x_helpers
    compile_xkb_keymap
    install_fonts
    install_matchbox_rc
    prune_install
    strip_tinyx_artifacts
    verify_tinyx_mips2

    touch "$XORG_SRC_ROOT/$TINYX_BUILD_STAMP"
    echo "=== TinyX build complete ==="
}

main "$@"
