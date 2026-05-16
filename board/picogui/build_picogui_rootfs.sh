#!/bin/bash
# BE-300 PicoGUI rootfs builder.
#
# Invoked by build_be300_kernel.sh when BE300_UI=picogui:
#
#   board/picogui/build_picogui_rootfs.sh "$ROOTFS" "$MUSL_SPECS" "$KHDRS"
#
# Phase order:
#
#   1. prepare_support_libs       libbe300cxx.a + libbe300gcc.a
#   2. resolve_picogui_sha        read board/picogui/git_sha; refuse placeholder
#   3. prepare_picogui_source     download/extract jserv tarball idempotently
#   4. patch_picogui_source       autoconf modernization + evdev wiring
#   5. overlay_evdev_driver       cp board/picogui/evdev.c into pg1/server/input/
#   6. autogen_picogui_server     pg1/server/autogen.sh
#   7. configure_picogui_server   out-of-tree, --with-profile=picogui.config
#   8. build_picogui_server       make pgserver in pg1/server/build
#   9. install_picogui_server     make install DESTDIR=$ROOTFS
#  10. autogen_picogui_apps       pg1/apps/autogen.sh
#  11. configure_picogui_apps     pg1/apps configure with WORKING_ONLY
#  12. build_picogui_apps         make pgboard pterm picosm tpcal
#  13. install_picogui_apps       make install DESTDIR=$ROOTFS (working/ only)
#  14. install_themes_and_runtime copy a starter theme + pgserverrc
#  15. strip + verify_picogui_mips2  fail fast on opcode regressions
#
# Helper functions (download_archive, make_generated_tree_writable, etc.) are
# copied by value from board/opie/build_opie_rootfs.sh so this script remains
# testable in isolation.

set -e

ROOTFS="${1:?rootfs path required}"
MUSL_SPECS="${2:?musl specs path required}"
KHDRS="${3:?kernel headers path required}"

PICOGUI_VERSION_TAG="jserv"
ARCHIVES="/work/archives"
BOARD_DIR="/work/board/picogui"
BE300_LIBS="/tmp/be300-picogui-libs"
LOG_DIR="/work/build-picogui"
SERVER_BUILD_LOG="$LOG_DIR/be300_picogui_server_build.log"
APPS_BUILD_LOG="$LOG_DIR/be300_picogui_apps_build.log"

BE300_LIBC="${BE300_LIBC:-uclibc}"
BE300_PICOGUI_BUILD_STAMP="${BE300_PICOGUI_BUILD_STAMP:-.be300-picogui-built-v2}"
BE300_PICOGUI_DEFAULT_CALIBRATION="${BE300_PICOGUI_DEFAULT_CALIBRATION:-1}"

CROSS="mipsel-linux-gnu-"
TARGET_CC="${BE300_TARGET_CC:-${CROSS}gcc}"
TARGET_CXX="${BE300_TARGET_CXX:-${CROSS}g++}"
TARGET_AR="${BE300_TARGET_AR:-${CROSS}ar}"
TARGET_RANLIB="${BE300_TARGET_RANLIB:-${CROSS}ranlib}"
TARGET_STRIP="${BE300_TARGET_STRIP:-${CROSS}strip}"
TARGET_CROSS_COMPILE="${BE300_TARGET_CROSS_COMPILE:-${CROSS}}"

# uClibc-ng default; musl override flips on -static.  Either way we add
# /tmp/libgcc_patched explicitly because the main script's TARGET_LIBC_LDFLAGS
# under uclibc lacks the -B/-L for the patched libgcc.
ARCH_CFLAGS="${BE300_ARCH_CFLAGS:--march=mips2 -msoft-float}"
DEFAULT_LIBC_CFLAGS="-isystem ${KHDRS}/include -B/tmp/libgcc_patched -L/tmp/libgcc_patched"
DEFAULT_LIBC_LDFLAGS="-B/tmp/libgcc_patched -L/tmp/libgcc_patched"
LIBC_CFLAGS="${BE300_LIBC_CFLAGS:-$DEFAULT_LIBC_CFLAGS} -B/tmp/libgcc_patched -L/tmp/libgcc_patched"
LIBC_LDFLAGS="${BE300_LIBC_LDFLAGS:-$DEFAULT_LIBC_LDFLAGS} -B/tmp/libgcc_patched -L/tmp/libgcc_patched"

if [ "$BE300_LIBC" = "musl" ]; then
    PICOGUI_SRC="/work/picogui-${PICOGUI_VERSION_TAG}-be300"
    LINK_STATIC_LDFLAGS="-static"
else
    PICOGUI_SRC="/work/picogui-${PICOGUI_VERSION_TAG}-be300-${BE300_LIBC}"
    LINK_STATIC_LDFLAGS=""
fi

# -fgnu89-inline: pgfx.h declares pgRect/pgText/pgSetColor/etc as `inline`
# (no `static`, no body) and pgfx.c provides matching `inline` definitions.
# Under C99 inline semantics (modern GCC default), inline-without-extern
# produces no out-of-line symbol — apps then fail to link with "undefined
# reference to pgRect".  -fgnu89-inline restores GNU89 semantics where
# inline implies extern (out-of-line copy emitted), matching what picogui
# was originally written against.
COMMON_CFLAGS="${ARCH_CFLAGS} -Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fgnu89-inline ${LIBC_CFLAGS} -I${BE300_LIBS}/include"
COMMON_CXXFLAGS="${COMMON_CFLAGS} -nostdinc++ -fno-exceptions -fno-rtti"
COMMON_LFLAGS="${LIBC_LDFLAGS} ${LINK_STATIC_LDFLAGS} -Wl,--gc-sections -L${BE300_LIBS}/lib"
COMMON_LIBS="-lbe300cxx -lbe300gcc"

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

make_generated_tree_writable() {
    local path
    for path in "$@"; do
        if [ -d "$path" ]; then
            chmod -R a+rwX "$path" 2>/dev/null || true
        fi
    done
}

download_archive() {
    local url="$1"
    local out="$2"

    mkdir -p "$ARCHIVES"
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
        mipsel-linux-gnu-strip --strip-all \
            --remove-section=.comment \
            --remove-section=.note \
            "$file" 2>/dev/null \
            || mipsel-linux-gnu-strip --strip-all "$file"
    done
}

verify_picogui_mips2() {
    local file
    local bad

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

# ---------------------------------------------------------------------
# Phase 1: BE-300 support libs
# ---------------------------------------------------------------------

prepare_support_libs() {
    echo "=== Building BE-300 PicoGUI support libraries ==="
    rm -rf "$BE300_LIBS"
    mkdir -p "$BE300_LIBS/include" "$BE300_LIBS/lib"

    ${TARGET_CC} ${COMMON_CFLAGS} -fPIC -c \
        /work/board/opie/be300_cxx_abi.c -o /tmp/be300_cxx_abi.o
    ${TARGET_AR} rcs "$BE300_LIBS/lib/libbe300cxx.a" /tmp/be300_cxx_abi.o

    if [ ! -e "$BE300_LIBS/lib/libbe300gcc.a" ]; then
        if [ -e /tmp/libgcc_patched/libbe300gcc.a ]; then
            cp /tmp/libgcc_patched/libbe300gcc.a "$BE300_LIBS/lib/"
        else
            echo "ERROR: /tmp/libgcc_patched/libbe300gcc.a missing — main script's prepare_be300_libgcc did not run" >&2
            return 1
        fi
    fi
}

# Cross-build zlib + libpng into $BE300_LIBS so pgserver picks up libpng
# from configure.ac's AC_CHECK_LIB(png) check, enabling CONFIG_FORMAT_PNG
# at runtime.  Required for the aqua theme — its compiled .th file in
# media/themes/aqua.th embeds PNG bitmaps that classique/bg_picogui
# don't.  Both libs are tiny (~120 KB statically linked combined), and
# we link them statically into pgserver since the picogui rootfs has no
# generic libpng.so consumers anyway.
prepare_png_libs() {
    local zlib_ver="1.3.1"
    local png_ver="1.6.43"
    local zlib_archive="$ARCHIVES/zlib-${zlib_ver}.tar.gz"
    local png_archive="$ARCHIVES/libpng-${png_ver}.tar.gz"

    if [ -f "$BE300_LIBS/lib/libpng16.a" ] \
        && [ -f "$BE300_LIBS/lib/libz.a" ]; then
        echo "=== zlib + libpng already built (reusing) ==="
        return 0
    fi

    echo "=== Cross-building zlib ${zlib_ver} + libpng ${png_ver} ==="
    # zlib.net mirror tends to 404 old versions; pull the GitHub release
    # directly. SourceForge libpng stays through redirects (curl -L below).
    download_archive "https://github.com/madler/zlib/releases/download/v${zlib_ver}/zlib-${zlib_ver}.tar.gz" "$zlib_archive"
    download_archive "https://downloads.sourceforge.net/project/libpng/libpng16/${png_ver}/libpng-${png_ver}.tar.gz" "$png_archive"

    rm -rf "/tmp/zlib-build" "/tmp/libpng-build"
    mkdir -p "/tmp/zlib-build" "/tmp/libpng-build"

    ( cd "/tmp/zlib-build"
      tar xzf "$zlib_archive" --strip-components=1
      # zlib's hand-rolled configure honors CC/CFLAGS env.  --static
      # tells it not to bother with a shared lib; we link static into
      # pgserver only.  -fno-stack-protector is critical: uClibc-ng
      # has no __stack_chk_guard / __stack_chk_fail and modern GCC
      # otherwise emits stack-cookie code by default.
      CC="${TARGET_CC}" \
      CFLAGS="${ARCH_CFLAGS} -Os -fno-stack-protector ${LIBC_CFLAGS}" \
      CHOST="mipsel-linux-gnu" \
        ./configure --prefix="$BE300_LIBS" --static
      make -j"$(nproc)"
      make install
    )

    ( cd "/tmp/libpng-build"
      tar xzf "$png_archive" --strip-components=1
      # libpng autoconf needs zlib's location.  Both pnglibconf
      # generation and the main compile use $CPPFLAGS for the
      # preprocessor; CFLAGS alone isn't enough because the
      # pnglibconf rule invokes CC -E without expanding CFLAGS.
      # We also bypass the mipsel-uclibc-gcc wrapper here and use the
      # raw cross-compiler so libpng's autoconf probes don't get
      # confused by the wrapper's -nostdlib link line.
      CC="mipsel-linux-gnu-gcc" \
      CPP="mipsel-linux-gnu-gcc -E" \
      CPPFLAGS="-I${BE300_LIBS}/include -isystem /work/uclibc-sysroot/usr/include" \
      CFLAGS="${ARCH_CFLAGS} -Os -fno-stack-protector --sysroot=/work/uclibc-sysroot" \
      LDFLAGS="-L${BE300_LIBS}/lib --sysroot=/work/uclibc-sysroot" \
        ./configure --host=mipsel-linux-gnu \
                    --prefix="$BE300_LIBS" \
                    --disable-shared --enable-static \
                    --without-binconfigs
      # The contrib/tools/png-fix-itxt utility uses glibc-only symbols
      # (__fgetc_unlocked, __stdout) that uClibc-ng lacks.  We only need
      # libpng16.la for pgserver, so build the library alone and copy
      # the artefacts manually — `make install` would also try to
      # install the broken contrib tool.
      make -j"$(nproc)" libpng16.la
      install -m 0644 .libs/libpng16.a "${BE300_LIBS}/lib/libpng16.a"
      ln -sf libpng16.a "${BE300_LIBS}/lib/libpng.a"
      install -m 0644 png.h pngconf.h pnglibconf.h "${BE300_LIBS}/include/"
    )

    # libpng installs as libpng16.a + a libpng.a symlink. pgserver's
    # configure greps for -lpng so make sure both names resolve.
    if [ ! -e "$BE300_LIBS/lib/libpng.a" ] \
        && [ -e "$BE300_LIBS/lib/libpng16.a" ]; then
        ln -sf libpng16.a "$BE300_LIBS/lib/libpng.a"
    fi
}

# ---------------------------------------------------------------------
# Phase 2: SHA pin
# ---------------------------------------------------------------------

resolve_picogui_sha() {
    local sha_file="$BOARD_DIR/git_sha"
    if [ ! -f "$sha_file" ]; then
        echo "ERROR: $sha_file not found — cannot pin picogui source" >&2
        return 1
    fi
    PICOGUI_GIT_SHA=$(tr -d '[:space:]' <"$sha_file")
    if [ -z "$PICOGUI_GIT_SHA" ] || \
       [ "$PICOGUI_GIT_SHA" = "0000000000000000000000000000000000000000" ]; then
        cat >&2 <<EOF
ERROR: board/picogui/git_sha holds the placeholder SHA.

Pin a real jserv/picogui commit before building. See
board/picogui/README.md "Source pin" section for the one-liner.
EOF
        return 1
    fi
    PICOGUI_SHA12="${PICOGUI_GIT_SHA:0:12}"
    PICOGUI_ARCHIVE="$ARCHIVES/picogui-jserv-${PICOGUI_SHA12}.tar.gz"
    PICOGUI_URL="https://github.com/jserv/picogui/archive/${PICOGUI_GIT_SHA}.tar.gz"
}

# ---------------------------------------------------------------------
# Phase 3: download + extract
# ---------------------------------------------------------------------

prepare_picogui_source() {
    download_archive "$PICOGUI_URL" "$PICOGUI_ARCHIVE"
    make_generated_tree_writable "$PICOGUI_SRC"

    if [ ! -d "$PICOGUI_SRC" ] \
       || [ ! -f "$PICOGUI_SRC/$BE300_PICOGUI_BUILD_STAMP" ]; then
        echo "=== Extracting picogui jserv ${PICOGUI_SHA12} for BE-300 ==="
        rm -rf "$PICOGUI_SRC"
        tar xzf "$PICOGUI_ARCHIVE" -C /work
        # GitHub archive unpacks as picogui-<full-sha>; rename for stability.
        mv "/work/picogui-${PICOGUI_GIT_SHA}" "$PICOGUI_SRC"
    fi
}

# ---------------------------------------------------------------------
# Phases 4 + 5: patch + overlay evdev driver
# ---------------------------------------------------------------------

patch_picogui_source() {
    python3 "$BOARD_DIR/patch_picogui_sources.py" "$PICOGUI_SRC"
}

overlay_evdev_driver() {
    local dst="$PICOGUI_SRC/pg1/server/input/evdev.c"
    if [ ! -d "$(dirname "$dst")" ]; then
        echo "ERROR: pg1/server/input/ missing in $PICOGUI_SRC" >&2
        return 1
    fi
    cp "$BOARD_DIR/evdev.c" "$dst"
}

# ---------------------------------------------------------------------
# Phase 6: autogen — server uses its own autogen.sh
# ---------------------------------------------------------------------

autogen_picogui_server() {
    # libtoolize installs ltmain.sh / m4 stubs needed by AM_PROG_LIBTOOL.
    # autogen.sh itself only runs aclocal / autoheader / autoconf / automake;
    # without ltmain.sh, automake -a fails with "required file './ltmain.sh'
    # not found".
    (
        cd "$PICOGUI_SRC/pg1/server"
        libtoolize --copy --force --install 2>&1 | head -20 || true
        ./autogen.sh
    )
}

# ---------------------------------------------------------------------
# Phase 7: configure server (out-of-tree, with our profile)
# ---------------------------------------------------------------------

configure_picogui_server() {
    local build_dir="$PICOGUI_SRC/pg1/server/build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    (
        cd "$build_dir"
        CC="${TARGET_CC}" CXX="${TARGET_CXX}" \
        AR="${TARGET_AR}" RANLIB="${TARGET_RANLIB}" STRIP="${TARGET_STRIP}" \
        CFLAGS="${COMMON_CFLAGS}" \
        CXXFLAGS="${COMMON_CXXFLAGS}" \
        LDFLAGS="${COMMON_LFLAGS}" \
        LIBS="${COMMON_LIBS}" \
            ../configure \
                --host=mipsel-linux-gnu \
                --prefix=/usr \
                --with-profile="$BOARD_DIR/picogui.config"
    )
}

# ---------------------------------------------------------------------
# Phase 8: build server
# ---------------------------------------------------------------------

build_picogui_server() {
    (
        cd "$PICOGUI_SRC/pg1/server/build"
        make -j"$(nproc)" 2>&1 | tee "$SERVER_BUILD_LOG"
    )
}

# ---------------------------------------------------------------------
# Phase 9: install server
# ---------------------------------------------------------------------

install_picogui_server() {
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib" \
             "$ROOTFS/usr/include" \
             "$ROOTFS/usr/share/picogui/themes" \
             "$ROOTFS/usr/share/picogui/fonts"

    (
        cd "$PICOGUI_SRC/pg1/server/build"
        make install DESTDIR="$ROOTFS"
    )
}

# ---------------------------------------------------------------------
# Phase 9.5: build pg1/client/c (libpgui)
#
# pterm / pgboard / picosm / tpcal all link against -lpgui from the C
# client library.  pg1/INSTALL says the build order is server -> client/c
# -> apps; without libpgui installed under DESTDIR, the apps configure
# fails its `AC_CHECK_LIB(pgui, pgInit)` test.
# ---------------------------------------------------------------------

autogen_picogui_client() {
    (
        cd "$PICOGUI_SRC/pg1/client/c"
        libtoolize --copy --force --install 2>&1 | head -20 || true
        ./autogen.sh
    )
}

configure_picogui_client() {
    local build_dir="$PICOGUI_SRC/pg1/client/c/build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    (
        cd "$build_dir"
        # --with-pgserver makes pg1/client/c/configure use
        # `${val}/include` when its AC_TRY_LINK test compiles a
        # `#include <picogui/network.h>` snippet.  Without this, the
        # test's PGSERVER_CFLAGS is empty and the test fails with
        # "cannot link a test picogui program."
        CC="${TARGET_CC}" CXX="${TARGET_CXX}" \
        AR="${TARGET_AR}" RANLIB="${TARGET_RANLIB}" STRIP="${TARGET_STRIP}" \
        CFLAGS="${COMMON_CFLAGS} -I${ROOTFS}/usr/include" \
        CXXFLAGS="${COMMON_CXXFLAGS} -I${ROOTFS}/usr/include" \
        LDFLAGS="${COMMON_LFLAGS} -L${ROOTFS}/usr/lib" \
        LIBS="${COMMON_LIBS}" \
            ../configure \
                --host=mipsel-linux-gnu \
                --prefix=/usr \
                --with-pgserver="${ROOTFS}/usr" \
                --enable-unix-sockets
    )
}

build_picogui_client() {
    (
        cd "$PICOGUI_SRC/pg1/client/c/build"
        make -j"$(nproc)"
    )
}

install_picogui_client() {
    (
        cd "$PICOGUI_SRC/pg1/client/c/build"
        make install DESTDIR="$ROOTFS"
    )
}

# ---------------------------------------------------------------------
# Phase 10–13: apps (working/ subset)
#
# pg1/apps has its own configure that walks all of working/dev/test.  Need
# to scope it to working/ only so we don't drag in test/ demos and dev/
# half-baked apps.  Some forks expose this via --enable-working-only;
# upstream uses the WORKING_ONLY automake conditional which doesn't have a
# configure flag — pass it as a make variable instead.
# ---------------------------------------------------------------------

# The apps subdir's autotools setup is a maintenance nightmare on modern
# automake (strict-mode errors throughout dev/, test/, working/<unused>/,
# even working/Makefile.am has trailing-backslash issues).  Sidestep
# autoconf entirely for apps and just cross-compile each one directly.
# These are all small C programs (1-4 .c files each).
build_picogui_apps() {
    local app_cflags="${COMMON_CFLAGS} -I${ROOTFS}/usr/include"
    local app_ldflags="${COMMON_LFLAGS} -L${ROOTFS}/usr/lib"
    local app_libs="-lpgui ${COMMON_LIBS}"
    local working="$PICOGUI_SRC/pg1/apps/working"

    mkdir -p "$LOG_DIR"
    {
        echo "=== Building picogui apps (direct cross-compile) ==="
        # pgboard — onscreen keyboard.  Per upstream Makefile.am,
        # the `pgboard` binary uses only pgboard.c + kbfile.c.
        # pgboard_cmds.c (separate `pgboard_cmds` tool) and
        # pgboard_api.c (libpgboard.la) are deliberately excluded.
        ${TARGET_CC} ${app_cflags} \
            "${working}/pgboard/pgboard.c" \
            "${working}/pgboard/kbfile.c" \
            ${app_ldflags} ${app_libs} \
            -o "${working}/pgboard/pgboard"
        # pterm — terminal (uses forkpty from -lutil)
        ${TARGET_CC} ${app_cflags} \
            "${working}/pterm/main.c" \
            "${working}/pterm/ptyfork.c" \
            ${app_ldflags} ${app_libs} -lutil \
            -o "${working}/pterm/pterm"
        # picosm — session manager / launcher
        ${TARGET_CC} ${app_cflags} \
            "${working}/picosm/picosm.c" \
            ${app_ldflags} ${app_libs} \
            -o "${working}/picosm/picosm"
        # tpcal — touch calibration utility
        ${TARGET_CC} ${app_cflags} \
            "${working}/tpcal/tpcal.c" \
            "${working}/tpcal/transform.c" \
            ${app_ldflags} ${app_libs} \
            -o "${working}/tpcal/tpcal"
        # pg-demo — BE-300 board demo (board/picogui/pg-demo.c).
        # Title bar + label + tappable button to exercise click routing.
        # Built outside the picogui apps tree because it lives in our board
        # overlay, not the upstream source.
        if [ -f "$BOARD_DIR/pg-demo.c" ]; then
            ${TARGET_CC} ${app_cflags} \
                "$BOARD_DIR/pg-demo.c" \
                ${app_ldflags} ${app_libs} \
                -o "${working}/pg-demo"
        fi
        # pg-keytest — BE-300 keyboard event probe.  Prints all KEYDOWN /
        # KEYUP / CHAR events to /dev/kmsg via PGBIND_ANY.  Used to verify
        # whether pgserver dispatches keys to clients on this build.
        if [ -f "$BOARD_DIR/pg-keytest.c" ]; then
            ${TARGET_CC} ${app_cflags} \
                "$BOARD_DIR/pg-keytest.c" \
                ${app_ldflags} ${app_libs} \
                -o "${working}/pg-keytest"
        fi
        # pg-desktop — BE-300 always-running launcher.  Owns the root
        # window so closing transient apps (atomicnav etc.) doesn't leave
        # the framebuffer un-owned and stale.  Buttons fork+exec the
        # /usr/share/picogui/appmenu/*.app launchers.
        if [ -f "$BOARD_DIR/pg-desktop.c" ]; then
            ${TARGET_CC} ${app_cflags} \
                "$BOARD_DIR/pg-desktop.c" \
                ${app_ldflags} ${app_libs} \
                -o "${working}/pg-desktop"
        fi
        # omnibar — pg1/apps/test/omnibar/omnibar.c.  Single-source app
        # launcher / status bar.  Linked against -lpgui only.
        local test_apps_dir="$PICOGUI_SRC/pg1/apps/test"
        if [ -f "${test_apps_dir}/omnibar/omnibar.c" ]; then
            ${TARGET_CC} ${app_cflags} \
                "${test_apps_dir}/omnibar/omnibar.c" \
                ${app_ldflags} ${app_libs} \
                -o "${test_apps_dir}/omnibar/omnibar"
        fi
        # canvastst — pg1/apps/test/canvastst/canvastst.c.  Animated demo
        # exercising PGCANVAS / PGCANVAS_GROP.  Wants -lm for trig.
        if [ -f "${test_apps_dir}/canvastst/canvastst.c" ]; then
            ${TARGET_CC} ${app_cflags} \
                "${test_apps_dir}/canvastst/canvastst.c" \
                ${app_ldflags} ${app_libs} -lm \
                -o "${test_apps_dir}/canvastst/canvastst"
        fi
        # atomicnav — pg1/apps/dev/atomicnav.  The in-tree picogui web
        # browser: HTTP/1.0 client + HTML 3.2 subset rendered into a
        # textbox via pgserver's CONFIG_FORMAT_HTML loader.  Multiple
        # source files; gethostbyname() pulls in -lresolv on uClibc-ng.
        local atomicnav_dir="$PICOGUI_SRC/pg1/apps/dev/atomicnav"
        if [ -d "$atomicnav_dir" ]; then
            ${TARGET_CC} ${app_cflags} \
                "${atomicnav_dir}/main.c" \
                "${atomicnav_dir}/browserwin.c" \
                "${atomicnav_dir}/url.c" \
                "${atomicnav_dir}/protocol.c" \
                "${atomicnav_dir}/p_http.c" \
                "${atomicnav_dir}/p_file.c" \
                ${app_ldflags} ${app_libs} -lresolv \
                -o "${atomicnav_dir}/atomicnav"
        fi
    } 2>&1 | tee "$APPS_BUILD_LOG"
}

# Compile keyboard layout sources (.kbs) into pgboard binary tables (.kb)
# via upstream's kbcompile.pl. The script reads from stdin, writes to
# stdout, and resolves PG_* symbols by parsing $PG_PATH/include/picogui/*.h
# at runtime — so we point it at the rootfs include tree we just installed.
# Only ship the layout pgboard actually loads (us_qwerty_scalable_color)
# to keep the JFFS2 image lean.
compile_picogui_keyboards() {
    local kb_compiler="$PICOGUI_SRC/pg1/apps/working/pgboard/kbcompile.pl"
    local kb_examples="$PICOGUI_SRC/pg1/apps/working/pgboard/examples"
    local kb_share="$ROOTFS/usr/share/pgboard"
    local pg_path="$ROOTFS/usr"
    local layout

    if [ ! -x "$kb_compiler" ] && [ ! -f "$kb_compiler" ]; then
        echo "WARNING: kbcompile.pl missing; skipping keyboard layout build" >&2
        return 0
    fi
    mkdir -p "$kb_share"

    for layout in us_qwerty_scalable_color; do
        local src="${kb_examples}/${layout}.kbs"
        local out="${kb_share}/${layout}.kb"
        if [ ! -f "$src" ]; then
            echo "WARNING: keyboard source $src missing" >&2
            continue
        fi
        # The .kbs is read from stdin; some layouts reference relative
        # img/ paths so cd into the examples dir first.
        ( cd "$kb_examples" && perl "$kb_compiler" -pg "$pg_path" < "$(basename "$src")" > "$out" )
        if [ ! -s "$out" ]; then
            echo "WARNING: kbcompile produced empty $out" >&2
        fi
    done
}

install_picogui_apps() {
    local working="$PICOGUI_SRC/pg1/apps/working"
    local test_apps_dir="$PICOGUI_SRC/pg1/apps/test"
    mkdir -p "$ROOTFS/usr/bin"
    for app in pgboard pterm picosm tpcal; do
        if [ -x "${working}/${app}/${app}" ]; then
            install -m 0755 "${working}/${app}/${app}" \
                            "$ROOTFS/usr/bin/${app}"
        else
            echo "WARNING: ${app} did not build (skipping install)" >&2
        fi
    done
    # pg-demo and pg-keytest live at the working/ root (board overlays).
    if [ -x "${working}/pg-demo" ]; then
        install -m 0755 "${working}/pg-demo" "$ROOTFS/usr/bin/pg-demo"
    fi
    if [ -x "${working}/pg-keytest" ]; then
        install -m 0755 "${working}/pg-keytest" "$ROOTFS/usr/bin/pg-keytest"
    fi
    if [ -x "${working}/pg-desktop" ]; then
        install -m 0755 "${working}/pg-desktop" "$ROOTFS/usr/bin/pg-desktop"
    fi
    # omnibar / canvastst live under apps/test, not apps/working
    for app in omnibar canvastst; do
        if [ -x "${test_apps_dir}/${app}/${app}" ]; then
            install -m 0755 "${test_apps_dir}/${app}/${app}" \
                            "$ROOTFS/usr/bin/${app}"
        else
            echo "WARNING: ${app} did not build (skipping install)" >&2
        fi
    done
    # atomicnav lives under apps/dev/atomicnav
    local atomicnav_bin="$PICOGUI_SRC/pg1/apps/dev/atomicnav/atomicnav"
    if [ -x "$atomicnav_bin" ]; then
        install -m 0755 "$atomicnav_bin" "$ROOTFS/usr/bin/atomicnav"
    else
        echo "WARNING: atomicnav did not build (skipping install)" >&2
    fi
}

# ---------------------------------------------------------------------
# Phase 14: themes + runtime config
# ---------------------------------------------------------------------

install_themes_and_runtime() {
    # Install one or two compact themes; pgserver needs at least one .th
    # to render.  bg_picogui.th is 100 KB and gives a recognizable look;
    # classique.th is 12 KB if we need the smaller default.  Ship both
    # and pick which to load via /etc/picogui/pgserverrc.
    if [ -d "$PICOGUI_SRC/media/themes" ]; then
        # aqua.th is the default loaded by pgserverrc; classique.th and
        # bg_picogui.th stay shipped as fallbacks (pgserver loads them
        # iff `themes = ...` references them).
        for t in aqua.th classique.th bg_picogui.th; do
            if [ -f "$PICOGUI_SRC/media/themes/$t" ]; then
                install -m 0644 "$PICOGUI_SRC/media/themes/$t" \
                    "$ROOTFS/usr/share/picogui/themes/$t"
            fi
        done
    fi

    mkdir -p "$ROOTFS/etc/picogui"
    install -m 0644 "$BOARD_DIR/pgserverrc" "$ROOTFS/etc/picogui/pgserverrc"
    if [ "$BE300_PICOGUI_DEFAULT_CALIBRATION" = "1" ]; then
        install -m 0644 "$BOARD_DIR/calibration.identity" \
                        "$ROOTFS/etc/picogui/calibration"
    fi

    # Populate /usr/share/picogui/appmenu/ with .app launcher scripts.
    # omnibar's btnAppMenu() opendir's this path, lists *.app entries,
    # and on selection execlp()s "<name>.app".  Each .app needs to be a
    # standalone executable; we ship tiny shell stubs so the menu is
    # non-empty and tapping an entry actually launches something.
    local appmenu="$ROOTFS/usr/share/picogui/appmenu"
    mkdir -p "$appmenu"
    for app in canvastst pterm tpcal pgboard; do
        cat > "$appmenu/$app.app" <<EOF_APP
#!/bin/sh
exec /usr/bin/$app "\$@"
EOF_APP
        chmod +x "$appmenu/$app.app"
    done
    # pgboard needs the .kb argument when launched from the menu.
    cat > "$appmenu/pgboard.app" <<'EOF_PGB'
#!/bin/sh
exec /usr/bin/pgboard /usr/share/pgboard/us_qwerty_scalable_color.kb
EOF_PGB
    chmod +x "$appmenu/pgboard.app"

    # atomicnav launcher — pre-loads a homepage so DNS + HTTP run on
    # first tap without the user needing to type a URL.  Without
    # --ne2000 on the emulator the connect() will fail and the status
    # bar will say "Connection failed".
    cat > "$appmenu/atomicnav.app" <<'EOF_ANV'
#!/bin/sh
exec /usr/bin/atomicnav http://frogfind.com/
EOF_ANV
    chmod +x "$appmenu/atomicnav.app"
    cat > "$appmenu/pg-keytest.app" <<'EOF_KT'
#!/bin/sh
exec /usr/bin/pg-keytest
EOF_KT
    chmod +x "$appmenu/pg-keytest.app"
    cat > "$appmenu/pg-desktop.app" <<'EOF_PD'
#!/bin/sh
exec /usr/bin/pg-desktop
EOF_PD
    chmod +x "$appmenu/pg-desktop.app"
}

# ---------------------------------------------------------------------
# Phase 15: strip + verify
# ---------------------------------------------------------------------

strip_picogui_artifacts() {
    local f
    for f in pgserver pgboard pterm picosm tpcal pg-demo pg-keytest pg-desktop omnibar canvastst atomicnav; do
        if [ -e "$ROOTFS/usr/bin/$f" ]; then
            be300_strip_binary "$ROOTFS/usr/bin/$f"
        fi
    done
    while IFS= read -r f; do
        be300_strip_binary "$f"
    done < <(find "$ROOTFS/usr/lib" -maxdepth 2 \
                 \( -name 'libpgui*.so*' -o -name 'libpgserver*.so*' \) \
                 2>/dev/null)
}

# ---------------------------------------------------------------------
# Drive
# ---------------------------------------------------------------------

# Defensive: pre-baked Dockerfile installs autoconf/automake/libtool, but if
# you're running against an older image, install them transiently here so
# autogen.sh works.  No-op once the rebuilt image is in use.
ensure_autotools() {
    if ! command -v aclocal >/dev/null 2>&1 \
       || ! command -v autoconf >/dev/null 2>&1 \
       || ! command -v libtoolize >/dev/null 2>&1; then
        echo "=== Installing autotools (transient: rebuild Docker image to bake in) ==="
        apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Use-Pty=0 -qq \
            autoconf automake libtool m4
    fi
}

ensure_autotools
prepare_support_libs
prepare_png_libs
resolve_picogui_sha
prepare_picogui_source
patch_picogui_source
overlay_evdev_driver
autogen_picogui_server
configure_picogui_server
build_picogui_server
install_picogui_server
autogen_picogui_client
configure_picogui_client
build_picogui_client
install_picogui_client
build_picogui_apps
install_picogui_apps
compile_picogui_keyboards
install_themes_and_runtime
strip_picogui_artifacts
verify_picogui_mips2

touch "$PICOGUI_SRC/$BE300_PICOGUI_BUILD_STAMP"

echo "=== PicoGUI rootfs build complete (jserv ${PICOGUI_SHA12}, ${BE300_LIBC}) ==="
