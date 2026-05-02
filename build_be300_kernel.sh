#!/bin/bash
set -e

KERNEL_SOURCE_URL="http://distro.ibiblio.org/tinycorelinux/7.x/x86/release/src/kernel/linux-4.2.9-patched.tar.xz"
BUSYBOX_VERSION="1.24.2"
KERNEL_PATCH_SERIES="/work/patches/linux-4.2.9/be300/series"
BE300_UI="${BE300_UI:-microwindows}"
KERNEL_CONFIG_FRAGMENTS=""
OPIE_CONFIG="/work/board/opie/opie-be300.config"
OPIE_BUILD_STAMP=".be300-opie-built-v45"
OPIE_PROFILE="base"
OPIE_EXTRA_DEFS=""
case "$BE300_UI" in
    microwindows)
        ROOTFS="/work/rootfs_be300"
        ROOTFS_JFFS2_NAME="rootfs.jffs2"
        NAND_IMAGE_NAME="be300.nand"
        ;;
    opie)
        ROOTFS="/work/rootfs_be300_opie"
        ROOTFS_JFFS2_NAME="rootfs-opie.jffs2"
        NAND_IMAGE_NAME="be300-opie.nand"
        ;;
    opie64)
        ROOTFS="/work/rootfs_be300_opie64"
        ROOTFS_JFFS2_NAME="rootfs-opie64.jffs2"
        NAND_IMAGE_NAME="be300-opie64.nand"
        KERNEL_CONFIG_FRAGMENTS="/work/configs/be300_64m.config"
        OPIE_CONFIG="/work/board/opie/opie-be300-64m.config"
        OPIE_BUILD_STAMP=".be300-opie64-built-v6"
        OPIE_PROFILE="opie64"
        OPIE_EXTRA_DEFS="-DBE300_ENABLE_TASKBAR_PLUGINS"
        ;;
    *)
        echo "ERROR: BE300_UI must be 'microwindows', 'opie', or 'opie64' (got '$BE300_UI')" >&2
        exit 1
        ;;
esac

###############################################################################
# Phase 0a: Rebuild musl with -march=mips2 (no SPECIAL2 mul instruction)
###############################################################################
# VR4131 is MIPS III, which predates MIPS32. It does NOT implement the
# SPECIAL2 opcode space (where MIPS32 `mul rd, rs, rt` lives). The stock
# musl-mipsel built with -march=mips32 uses `mul` throughout, which raises
# a Reserved Instruction exception on VR4131 (both emulator and real HW).
# Rebuild with -march=mips2 which uses only mult/mflo.

MUSL_MIPS2="/work/musl-mipsel"
MUSL_SRC="/work/musl-1.2.5"

prepare_be300_libgcc() {
    # Patched libgcc.a: the stock libgcc (from the mips32r2 cross toolchain)
    # uses MIPS32-only instructions in several helper routines.  VR4131 is
    # MIPS III and raises Reserved Instruction on those opcodes.  Create a
    # private libgcc archive that strips the offending objects and adds
    # MIPS2-compiled replacements.
    mkdir -p /tmp/libgcc_patched
    LIBGCC_ORIG=$(mipsel-linux-gnu-gcc -print-libgcc-file-name)
    cp "$LIBGCC_ORIG" /tmp/libgcc_patched/libgcc.a
    mipsel-linux-gnu-ar d /tmp/libgcc_patched/libgcc.a \
        _mulsc3.o _muldc3.o \
        _divdi3.o _moddi3.o _udivdi3.o _umoddi3.o \
        _fixdfdi.o _fixunsdfdi.o _floatdidf.o _floatundidf.o \
        _lshrdi3.o _ashldi3.o _ashrdi3.o _negdi2.o \
        _clzsi2.o _clzdi2.o _ctzsi2.o _ctzdi2.o \
        _popcountsi2.o _popcountdi2.o _paritysi2.o _paritydi2.o \
        _ffssi2.o _ffsdi2.o \
        2>/dev/null || true
    mipsel-linux-gnu-gcc -march=mips2 -mfpxx -O2 -fPIC -ffreestanding -fno-builtin \
        -c -o /tmp/libgcc_helpers.o /work/board/casio-be300/libgcc_helpers.c
    mipsel-linux-gnu-ar rcs /tmp/libgcc_patched/libgcc.a /tmp/libgcc_helpers.o
    mipsel-linux-gnu-ar rcs /tmp/libgcc_patched/libbe300gcc.a /tmp/libgcc_helpers.o
}

unsupported_mips2_insn() {
    mipsel-linux-gnu-objdump -d "$1" 2>/dev/null \
        | awk '$3 ~ /^(mul|clz|clo|ext|ins|seb|seh|wsbh|rdhwr)$/ {print; exit}' || true
}

check_mips2_file() {
    local file="$1"
    local bad=""

    if [ ! -e "$file" ]; then
        echo "missing $file"
        return
    fi
    bad=$(unsupported_mips2_insn "$file")
    if [ -n "$bad" ]; then
        echo "$file: $bad"
    fi
}

prepare_be300_libgcc

MUSL_BAD_INSN=""
MUSL_BAD_INSN="$(
    check_mips2_file "$MUSL_MIPS2/lib/libc.a"
    check_mips2_file "$MUSL_MIPS2/lib/libc.so"
)"

if [ -z "$MUSL_BAD_INSN" ] \
        && [ -f "$MUSL_SRC/arch/mips/pthread_arch.h" ] \
        && grep -q "__be300_mips_tp" "$MUSL_SRC/arch/mips/pthread_arch.h"; then
    echo "--- musl-mipsel already MIPS2-compatible, skipping rebuild ---"
else
    if [ -n "$MUSL_BAD_INSN" ]; then
        echo "--- musl-mipsel needs rebuild: $MUSL_BAD_INSN ---"
    fi
    echo "=== Phase 0a: Rebuilding musl-mipsel with -march=mips2 ==="
    if [ ! -d "$MUSL_SRC" ]; then
        cd /work
        tar xf musl-1.2.5.tar.gz
    fi
    cp /work/board/casio-be300/musl_mips_pthread_arch.h \
        "$MUSL_SRC/arch/mips/pthread_arch.h"
    cp /work/board/casio-be300/musl_mips_set_thread_area.c \
        "$MUSL_SRC/src/thread/__set_thread_area.c"
    cd "$MUSL_SRC"
    make distclean 2>/dev/null || true
    # Explicitly set cross tools so musl doesn't try mipsel-linux-musl-*
    CROSS=mipsel-linux-gnu-
    CC="${CROSS}gcc -march=mips2 -mfpxx -B/tmp/libgcc_patched -L/tmp/libgcc_patched" \
    LIBCC="/tmp/libgcc_patched/libgcc.a" \
    AR="${CROSS}ar" \
    RANLIB="${CROSS}ranlib" \
    LD="${CROSS}ld" \
        ./configure --target=mipsel-linux-gnu \
            --prefix="$MUSL_MIPS2" 2>&1 | tail -5
    make CC="${CROSS}gcc -march=mips2 -mfpxx -B/tmp/libgcc_patched -L/tmp/libgcc_patched" \
         LIBCC="/tmp/libgcc_patched/libgcc.a" \
         AR="${CROSS}ar" \
         RANLIB="${CROSS}ranlib" \
         -j$(nproc) 2>&1 | tail -5
    make install 2>&1 | tail -5
    cd /work
fi
if [ -e "$MUSL_MIPS2/lib/libc.so" ] && [ ! -e "$MUSL_MIPS2/lib/ld-musl-mipsel.so.1" ]; then
    ln -sf libc.so "$MUSL_MIPS2/lib/ld-musl-mipsel.so.1"
fi
MUSL_BAD_INSN="$(
    check_mips2_file "$MUSL_MIPS2/lib/libc.a"
    check_mips2_file "$MUSL_MIPS2/lib/libc.so"
)"
if [ -n "$MUSL_BAD_INSN" ]; then
    echo "ERROR: musl-mipsel still contains unsupported VR4131 instructions:" >&2
    echo "$MUSL_BAD_INSN" >&2
    exit 1
fi

###############################################################################
# Phase 0: Prepare sanitized Linux UAPI headers for musl (needed by Phase 1)
###############################################################################

KHDRS="/work/musl-khdrs"
if [ ! -d "$KHDRS/include/linux" ]; then
    echo "=== Phase 0: Installing sanitized kernel headers for musl ==="
    # Use a separate untar to avoid touching the kernel build tree we will
    # configure later (the kernel tree gets blown away in Phase 2).
    if [ ! -f /work/linux-4.2.9-patched.tar.xz ]; then
        (cd /work && wget "$KERNEL_SOURCE_URL")
    fi
    mkdir -p /tmp/khdrs_src
    rm -rf /tmp/khdrs_src/linux-4.2.9
    tar xf /work/linux-4.2.9-patched.tar.xz -C /tmp/khdrs_src
    /work/scripts/apply_patch_series.sh "$KERNEL_PATCH_SERIES" \
        /tmp/khdrs_src/linux-4.2.9
    rm -rf "$KHDRS"
    mkdir -p "$KHDRS"
    make -C /tmp/khdrs_src/linux-4.2.9 \
        ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- \
        INSTALL_HDR_PATH="$KHDRS" headers_install 2>&1 | tail -5
fi

###############################################################################
# Phase 1: Build BusyBox with musl, install into the JFFS2 rootfs source tree
###############################################################################

echo "=== Phase 1: Building BusyBox with musl ==="

BBOX_DIR="/work/busybox-${BUSYBOX_VERSION}"
if [ ! -d "$BBOX_DIR" ]; then
    echo "ERROR: $BBOX_DIR not found — extract busybox-${BUSYBOX_VERSION}.tar.bz2 first"
    exit 1
fi

# Rebuild busybox from scratch with musl + mips32 (no mips32r2 instructions).
cd "$BBOX_DIR"
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- distclean || true
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- defconfig

enable_busybox_config() {
    cfg="$1"
    if grep -q "^# ${cfg} is not set" .config; then
        sed -i "s/^# ${cfg} is not set/${cfg}=y/" .config
    elif grep -q "^${cfg}=n" .config; then
        sed -i "s/^${cfg}=n/${cfg}=y/" .config
    elif ! grep -q "^${cfg}=" .config; then
        echo "${cfg}=y" >> .config
    fi
}

set_busybox_string_config() {
    cfg="$1"
    val="$2"
    if grep -q "^${cfg}=" .config; then
        sed -i "s@^${cfg}=.*@${cfg}=\"${val}\"@" .config
    else
        echo "${cfg}=\"${val}\"" >> .config
    fi
}

# Force static, disable NFS/RPC (not in musl), use internal crypt
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/^# CONFIG_USE_BB_CRYPT is not set/CONFIG_USE_BB_CRYPT=y/' .config
sed -i 's/^# CONFIG_USE_BB_CRYPT_SHA is not set/CONFIG_USE_BB_CRYPT_SHA=y/' .config
# Disable WTMP (musl's _PATH_WTMP not auto-included in libbb)
sed -i 's/^CONFIG_FEATURE_WTMP=y/CONFIG_FEATURE_WTMP=n/' .config
sed -i 's/^CONFIG_FEATURE_UTMP=y/CONFIG_FEATURE_UTMP=n/' .config
# Keep the NE2000 boot smoke test available on clean BusyBox rebuilds.
for cfg in CONFIG_ARP CONFIG_ARPING CONFIG_IFCONFIG CONFIG_IP \
    CONFIG_FEATURE_IP_ADDRESS CONFIG_FEATURE_IP_LINK CONFIG_FEATURE_IP_ROUTE \
    CONFIG_IPADDR CONFIG_IPLINK CONFIG_IPROUTE CONFIG_NSLOOKUP CONFIG_PING \
    CONFIG_ROUTE CONFIG_UDHCPC CONFIG_WGET; do
    enable_busybox_config "$cfg"
done
sed -i 's@^CONFIG_UDHCPC_DEFAULT_SCRIPT=.*@CONFIG_UDHCPC_DEFAULT_SCRIPT="/usr/share/udhcpc/default.script"@' .config
# Phase 0's libc-compat.h sed teaches the linux UAPI to keep its hands off
# struct definitions when musl already provides them, so most networking
# applets compile against -isystem $KHDRS/include now. Keep disabled only
# the applets that need niche kernel headers (linux/pkt_sched.h, if_vlan.h,
# if_bridge.h, if_tunnel.h, …) or runtime support we don't have (NFS/RPC,
# nanosleep — gettimeofday_ns).
for cfg in CONFIG_BRCTL CONFIG_DNSD CONFIG_FAKEIDENTD CONFIG_FTPD \
    CONFIG_HTTPD CONFIG_IFENSLAVE CONFIG_IFPLUGD CONFIG_IFUPDOWN \
    CONFIG_INETD CONFIG_IPTUNNEL CONFIG_NBDCLIENT CONFIG_NTPD \
    CONFIG_PSCAN CONFIG_SLATTACH CONFIG_TCPSVD CONFIG_TELNETD \
    CONFIG_TFTPD CONFIG_UDHCPD CONFIG_UDPSVD CONFIG_VCONFIG \
    CONFIG_ZCIP CONFIG_TUNCTL CONFIG_TC CONFIG_FEATURE_MOUNT_NFS \
    CONFIG_FEATURE_HAVE_RPC CONFIG_FEATURE_INETD_RPC \
    CONFIG_FEATURE_SYSLOGD_CFG CONFIG_RUNSV CONFIG_RUNSVDIR CONFIG_SV \
    CONFIG_SVLOGD CONFIG_CHPST CONFIG_ENVDIR CONFIG_ENVUIDGID \
    CONFIG_SETUIDGID CONFIG_SOFTLIMIT; do
    sed -i "s/^${cfg}=y/${cfg}=n/" .config
done

MUSL_SPECS="/work/musl-mipsel/lib/musl-gcc.specs"
set_busybox_string_config CONFIG_EXTRA_CFLAGS "-march=mips2 -specs $MUSL_SPECS -isystem $KHDRS/include"
set_busybox_string_config CONFIG_EXTRA_LDFLAGS "-B/tmp/libgcc_patched -L/tmp/libgcc_patched"
set_busybox_string_config CONFIG_EXTRA_LDLIBS ""

yes "" | make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- oldconfig

# Build with musl + mips2. Use musl-gcc wrapper
# via -specs. -nostdinc on the existing headers is not needed since musl
# specs handle include paths.
# musl doesn't ship Linux UAPI headers (linux/*.h); use sanitized headers
# from linux-4.2.9 via `make headers_install` (see Phase 0 above).
prepare_be300_libgcc

if ! grep -q 'BE300_FORCE_OBJECTS' scripts/trylink; then
    sed -i '/\$START_GROUP \$O_FILES \$A_FILES \$END_GROUP \\/a\
		$BE300_FORCE_OBJECTS \\' scripts/trylink
fi

export BE300_FORCE_OBJECTS="/tmp/libgcc_helpers.o"
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- busybox -j$(nproc) 2>&1 | tail -5
unset BE300_FORCE_OBJECTS
ls -l busybox
mipsel-linux-gnu-strip busybox

# Populate full rootfs (this becomes the JFFS2 mtd3 partition).
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,etc,root,mnt,usr/share/udhcpc}
cp busybox "$ROOTFS/bin/busybox"
chmod +x "$ROOTFS/bin/busybox"

# Phase A smoke test: a userspace mmap of /dev/fb0 that draws a checkerboard.
# Sanity-checks the sfb_mmap() path before any real GUI lib (Microwindows,
# Qt/E, SDL) tries to use it.
mipsel-linux-gnu-gcc -march=mips2 -O2 -static \
    -specs "$MUSL_SPECS" -isystem "$KHDRS/include" \
    -B/tmp/libgcc_patched \
    /work/board/casio-be300/fb_mmap_test.c \
    /tmp/libgcc_helpers.o \
    -o /tmp/fb_mmap_test
mipsel-linux-gnu-strip /tmp/fb_mmap_test
cp /tmp/fb_mmap_test "$ROOTFS/bin/fb_mmap_test"
chmod +x "$ROOTFS/bin/fb_mmap_test"

# Phase B smoke test: query the PIU touchscreen input_dev capabilities.
mipsel-linux-gnu-gcc -march=mips2 -O2 -static \
    -specs "$MUSL_SPECS" -isystem "$KHDRS/include" \
    -B/tmp/libgcc_patched \
    /work/board/casio-be300/touch_query_test.c \
    /tmp/libgcc_helpers.o \
    -o /tmp/touch_query_test
mipsel-linux-gnu-strip /tmp/touch_query_test
cp /tmp/touch_query_test "$ROOTFS/bin/touch_query_test"
chmod +x "$ROOTFS/bin/touch_query_test"

# VT mode helper used by framebuffer-owning GUIs. KD_GRAPHICS leaves fbcon
# active for boot/crash text but prevents it from repainting over /dev/fb0
# while Qt/Embedded or Nano-X owns the screen.
mipsel-linux-gnu-gcc -march=mips2 -Os -static \
    -specs "$MUSL_SPECS" -isystem "$KHDRS/include" \
    -B/tmp/libgcc_patched \
    /work/board/opie/be300_vtmode.c \
    /tmp/libgcc_helpers.o \
    -o /tmp/be300-vtmode
mipsel-linux-gnu-strip /tmp/be300-vtmode
cp /tmp/be300-vtmode "$ROOTFS/bin/be300-vtmode"
chmod +x "$ROOTFS/bin/be300-vtmode"

# Phase C' — optional GUI profile.  The default Microwindows / Nano-X path is
# pure C.  The OPIE profile replaces it with Qt/Embedded + curated OPIE apps.
if [ "$BE300_UI" = "microwindows" ]; then
# Microwindows / Nano-X (pure C, builds against musl + mips2,
# no libstdc++ needed). Builds the nano-X server plus a small client app set
# (launcher, terminal, browser, soft keyboard, and diagnostics). Input devices
# are discovered by evdev device name so optional keyboards do not change the
# touchscreen event path.
#
# Source tree layout: microwindows/ is a fresh extraction of
# ghaerr/microwindows; our overlays live at /work/board/microwindows/ and
# are copied + patched in here so the upstream tree stays clean.
echo "=== Building Microwindows / Nano-X for BE-300 ==="
if [ ! -f microwindows-master.tar.gz ]; then
    wget -q "https://github.com/ghaerr/microwindows/archive/refs/heads/master.tar.gz" \
        -O microwindows-master.tar.gz
fi
if [ ! -d microwindows ]; then
    tar xzf microwindows-master.tar.gz
    mv microwindows-master microwindows
fi
# Overlay our config + evdev drivers, idempotently
cp /work/board/microwindows/config.be300 \
   /work/microwindows/src/Configs/config.be300
cp /work/board/microwindows/kbd_evdev.c \
   /work/microwindows/src/drivers/kbd_evdev.c
cp /work/board/microwindows/mou_evdev.c \
   /work/microwindows/src/drivers/mou_evdev.c
cp /work/board/microwindows/nxweb.c \
   /work/microwindows/src/demos/nanox/nxweb.c
python3 - <<'PY'
from pathlib import Path

root = Path("/work/microwindows/src/demos/nanox")

path = root / "nxlaunch.h"
text = path.read_text()
text = text.replace("#define ITEM_WIDTH 100\n", "#define ITEM_WIDTH 112\n")
text = text.replace("#define ITEM_HEIGHT 60\n", "#define ITEM_HEIGHT 58\n")
text = text.replace("#define TEXT_Y_POSITION (ITEM_HEIGHT - 6)\n",
                    "#define TEXT_Y_POSITION (ITEM_HEIGHT - 8)\n")
path.write_text(text)

path = root / "nxlaunch.c"
text = path.read_text()
text = text.replace("""\
void reaper(int signum) {
\tpid_t pid;

\tsignal(SIGCHLD, &reaper);
\twhile((pid = waitpid(-1, NULL, WNOHANG) > 0))
\t\tif(pid == sspid) sspid = -1;
}
""", """\
void reaper(int signum) {
\tpid_t pid;

\t(void)signum;
\twhile((pid = waitpid(-1, NULL, WNOHANG)) > 0)
\t\tif(pid == sspid) sspid = -1;
}
""")
text = text.replace("case GR_EVENT_TYPE_BUTTON_DOWN:\n\t\t\thandle_mouse_event(state);\n\t\t\tbreak;",
                    "case GR_EVENT_TYPE_BUTTON_UP:\n\t\t\thandle_mouse_event(state);\n\t\t\tbreak;")
text = text.replace("GrSelectEvents(i->wid, GR_EVENT_MASK_EXPOSURE | GR_EVENT_MASK_BUTTON_DOWN);",
                    "GrSelectEvents(i->wid, GR_EVENT_MASK_EXPOSURE | GR_EVENT_MASK_BUTTON_UP);")
text = text.replace("\tsignal(SIGCHLD, &reaper);\n", "\tsignal(SIGCHLD, SIG_IGN);\n")
path.write_text(text)

path = root / "nxterm.c"
text = path.read_text()
old = """\
    col = stdcol;
    row = stdrow;
    scrolltop=0;
    scrollbottom = row;

    regFont = GrCreateFontEx(GR_FONT_SYSTEM_FIXED, 0, 0, NULL);
    /*regFont = GrCreateFontEx(GR_FONT_OEM_FIXED, 0, 0, NULL);*/
    /*boldFont = GrCreateFontEx(GR_FONT_SYSTEM_FIXED, 0, 0, NULL);*/
    GrGetFontInfo(regFont, &fi);
    winw = col*fi.maxwidth;
    winh = row*fi.height;
    w1 = GrNewWindowEx(GR_WM_PROPS_APPWINDOW, TITLE, GR_ROOT_WINDOW_ID, -1,-1,winw,winh,
\t\tstdbackground);
"""
new = """\
    col = stdcol;
    row = stdrow;
    scrolltop=0;

    regFont = GrCreateFontEx(GR_FONT_SYSTEM_FIXED, 0, 0, NULL);
    /*regFont = GrCreateFontEx(GR_FONT_OEM_FIXED, 0, 0, NULL);*/
    /*boldFont = GrCreateFontEx(GR_FONT_SYSTEM_FIXED, 0, 0, NULL);*/
    GrGetFontInfo(regFont, &fi);
#if BE300_TOUCHSCREEN
    {
        int fw = fi.maxwidth ? fi.maxwidth : 6;
        int fh = fi.height ? fi.height : 13;
        int maxcol = (si.cols - 12) / fw;
        int maxrow = (si.rows - 56) / fh;

        if (maxcol < 20)
            maxcol = 20;
        if (maxrow < 8)
            maxrow = 8;
        if (maxcol < col)
            col = maxcol;
        if (maxrow < row)
            row = maxrow;
    }
#endif
    scrollbottom = row;
    winw = col*fi.maxwidth;
    winh = row*fi.height;
    w1 = GrNewWindowEx(GR_WM_PROPS_APPWINDOW, TITLE, GR_ROOT_WINDOW_ID, 0, 0, winw, winh,
\t\tstdbackground);
"""
if old in text:
    text = text.replace(old, new)
path.write_text(text)

path = root / "nxclock.c"
text = path.read_text()
text = text.replace("#define CWIDTH\t\t200\n", "#define CWIDTH\t\t180\n")
text = text.replace("#define CHEIGHT\t\t200\n", "#define CHEIGHT\t\t180\n")
text = text.replace('GR_ROOT_WINDOW_ID,\n\t\t-1, -1, CWIDTH, CHEIGHT',
                    'GR_ROOT_WINDOW_ID,\n\t\t0, 0, CWIDTH, CHEIGHT')
path.write_text(text)

path = root / "nxcalc.c"
text = path.read_text()
text = text.replace('GR_ROOT_WINDOW_ID,\n                        10, 10, WIN_W, WIN_H',
                    'GR_ROOT_WINDOW_ID,\n                        0, 0, WIN_W, WIN_H')
path.write_text(text)
PY
# Patch Objects.rules to register EVDEVKBD and EVDEVMOUSE driver hooks
# (idempotent — only inserts when the marker line is absent)
if ! grep -q "MOUSE.*EVDEVMOUSE" /work/microwindows/src/drivers/Objects.rules; then
    sed -i '/^# FBE mouse driver$/i\
# Linux evdev mouse driver (touchscreen via /dev/input/eventN)\
ifeq ($(MOUSE), EVDEVMOUSE)\
MW_CORE_OBJS += $(MW_DIR_OBJ)/drivers/mou_evdev.o\
endif\
' /work/microwindows/src/drivers/Objects.rules
fi
if ! grep -q "KEYBOARD.*EVDEVKBD" /work/microwindows/src/drivers/Objects.rules; then
    sed -i '/^# FBE keyboard driver$/i\
# Linux evdev keyboard driver (/dev/input/eventN, BE-300 buttons / Stowaway)\
ifeq ($(KEYBOARD), EVDEVKBD)\
MW_CORE_OBJS += $(MW_DIR_OBJ)/drivers/kbd_evdev.o\
endif\
' /work/microwindows/src/drivers/Objects.rules
fi
if ! grep -q "BE300_TOUCHSCREEN hides the software cursor" /work/microwindows/src/nanox/srvmain.c; then
    sed -i '/^	GsRedrawScreen();$/a\
#if BE300_TOUCHSCREEN\
\t/* BE300_TOUCHSCREEN hides the software cursor for touch-only input. */\
\tGdHideCursor(psd);\
#endif\
' /work/microwindows/src/nanox/srvmain.c
fi
if ! grep -q "BE300_TOUCHSCREEN keeps Nano-X cursor hidden" /work/microwindows/src/engine/devmouse.c; then
    sed -i '/^GdShowCursor(PSD psd)$/,/^{$/{
/^{$/a\
#if BE300_TOUCHSCREEN\
\t/* BE300_TOUCHSCREEN keeps Nano-X cursor hidden for absolute touch. */\
\tcurvisible = 0;\
\tcurneedsrestore = FALSE;\
\treturn 0;\
#endif
}' /work/microwindows/src/engine/devmouse.c
    sed -i '/^GdHideCursor(PSD psd)$/,/^{$/{
/^{$/a\
#if BE300_TOUCHSCREEN\
\t/* BE300_TOUCHSCREEN keeps Nano-X cursor hidden for absolute touch. */\
\tcurvisible = 0;\
\tcurneedsrestore = FALSE;\
\treturn 0;\
#endif
}' /work/microwindows/src/engine/devmouse.c
fi
python3 - <<'PY'
from pathlib import Path

path = Path("/work/microwindows/src/nanox/srvmain.c")
text = path.read_text()

old_poll_marker = """\
#if BE300_TOUCHSCREEN
\t/* BE300_TOUCHSCREEN polls evdev input even if select() misses readiness. */
\twhile (GsCheckMouseEvent())
\t\tcontinue;
\twhile (GsCheckKeyboardEvent())
\t\tcontinue;
#endif

"""
old_timeout_marker = """\
#if BE300_TOUCHSCREEN
\t/*
\t * The BE-300 evdev input nodes can miss select() wakeups under this
\t * vintage kernel/emulator combination. Keep the server loop periodic so
\t * the polling block above drains touch and keyboard events.
\t */
\tif (to == NULL || tout.tv_sec != 0 || tout.tv_usec > 10000) {
\t\tto = &tout;
\t\ttout.tv_sec = 0;
\t\ttout.tv_usec = 10000;
\t}
#endif

"""
text = text.replace(old_poll_marker, "")
text = text.replace(old_timeout_marker, "")
logged_start = "\t/* BE300 active evdev polling: drain input even if select() misses readiness. */\n\t{\n\t\tstatic int be300_poll_logged;"
logged_end = "\twhile (GsCheckKeyboardEvent())\n\t\tcontinue;\n\n"
logged_pos = text.find(logged_start)
if logged_pos >= 0:
    logged_end_pos = text.find(logged_end, logged_pos)
    if logged_end_pos >= 0:
        text = text[:logged_pos] + text[logged_end_pos + len(logged_end):]

poll_marker = """\
\t/* BE300 active evdev polling: drain input even if select() misses readiness. */
\twhile (GsCheckMouseEvent())
\t\tcontinue;
\twhile (GsCheckKeyboardEvent())
\t\tcontinue;

"""
needle = "\t/* Set up the FDs for use in the main select(): */\n"
if poll_marker not in text:
    text = text.replace(needle, poll_marker + needle, 1)

timeout_marker = """\
\t/*
\t * The BE-300 evdev input nodes can miss select() wakeups under this
\t * vintage kernel/emulator combination. Keep the server loop periodic so
\t * the polling block above drains touch and keyboard events.
\t */
\tif (to == NULL || tout.tv_sec != 0 || tout.tv_usec > 10000) {
\t\tto = &tout;
\t\ttout.tv_sec = 0;
\t\ttout.tv_usec = 10000;
\t}

"""
needle = "\tif (updatecount) --updatecount;\n\n\t/* Wait for some input on any of the fds in the set or a timeout*/\n"
if timeout_marker not in text:
    text = text.replace(needle, timeout_marker + needle, 1)

path.write_text(text)
PY
if ! grep -q "nxweb" /work/microwindows/src/demos/nanox/Makefile; then
    sed -i '/$(MW_DIR_BIN)\/nxev \\/a\
\t$(MW_DIR_BIN)/nxweb \\
' /work/microwindows/src/demos/nanox/Makefile
fi

cd /work/microwindows/src
cp Configs/config.be300 config
make clean >/dev/null 2>&1 || true
make -C demos/nanox MW_DIR_SRC=/work/microwindows/src clean >/dev/null 2>&1 || true
MW_CC="mipsel-linux-gnu-gcc -march=mips2 -mfpxx -specs $MUSL_SPECS -isystem $KHDRS/include -B/tmp/libgcc_patched"
MW_EXTRAFLAGS="-DBE300_TOUCHSCREEN=1 -DFLIP_MOUSE_IN_PORTRAIT_MODE=0"
MW_BUILD_LOG=/tmp/microwindows_be300_build.log
if ! make -j$(nproc) default MIPSTOOLSPREFIX="" \
        COMPILER=gcc \
        CC="$MW_CC" \
        AR="mipsel-linux-gnu-ar" \
        LDFLAGS="-static" \
        EXTRAFLAGS="$MW_EXTRAFLAGS" \
        >"$MW_BUILD_LOG" 2>&1; then
    tail -40 "$MW_BUILD_LOG"
    exit 1
fi
MW_APPS="nano-X demo-hello nxev nxlaunch nxterm nxkbd nxweb nxclock nxcalc"
MW_NANOX_TARGETS=""
for app in $MW_APPS; do
    if [ "$app" != "nano-X" ]; then
        MW_NANOX_TARGETS="$MW_NANOX_TARGETS /work/microwindows/src/bin/$app"
    fi
done
if ! make -C demos/nanox -j$(nproc) $MW_NANOX_TARGETS MIPSTOOLSPREFIX="" \
        MW_DIR_SRC=/work/microwindows/src \
        COMPILER=gcc \
        CC="$MW_CC" \
        AR="mipsel-linux-gnu-ar" \
        LDFLAGS="-static" \
        EXTRAFLAGS="$MW_EXTRAFLAGS" \
        >>"$MW_BUILD_LOG" 2>&1; then
    tail -40 "$MW_BUILD_LOG"
    exit 1
fi
tail -3 "$MW_BUILD_LOG"
echo "--- Microwindows artifacts ---"
for app in $MW_APPS; do
    ls -la "/work/microwindows/src/bin/$app"
    mipsel-linux-gnu-strip "/work/microwindows/src/bin/$app"
    cp "/work/microwindows/src/bin/$app" "$ROOTFS/bin/$app"
    chmod +x "$ROOTFS/bin/$app"
done
# Stage a minimal font set so MWFONTDIR-less demos can fall back to disk if
# the built-in font picker misses.
mkdir -p "$ROOTFS/usr/share/microwindows/pcf"
cp /work/microwindows/src/fonts/pcf/*.pcf.gz "$ROOTFS/usr/share/microwindows/pcf/" 2>/dev/null || true

cat > "$ROOTFS/etc/nxlaunch.cnf" << 'NXLAUNCH_CNF'
# BE-300 Nano-X launcher. Use '-' for iconless buttons to save rootfs space.
$window_background_colour BLACK
Terminal - /bin/mw-terminal
Browser - /bin/mw-browser http://example.com/
Keyboard - /bin/mw-keyboard
Events - /bin/mw-events
Clock - /bin/mw-clock
Calc - /bin/mw-calc
NXLAUNCH_CNF

cat > "$ROOTFS/bin/mw-terminal" << 'MW_TERMINAL'
#!/bin/sh
exec /bin/nxterm "$@"
MW_TERMINAL
chmod +x "$ROOTFS/bin/mw-terminal"

cat > "$ROOTFS/bin/mw-browser" << 'MW_BROWSER'
#!/bin/sh
url="${1:-http://example.com/}"
exec /bin/nxweb "$url"
MW_BROWSER
chmod +x "$ROOTFS/bin/mw-browser"

cat > "$ROOTFS/bin/mw-keyboard" << 'MW_KEYBOARD'
#!/bin/sh
exec /bin/nxkbd "$@"
MW_KEYBOARD
chmod +x "$ROOTFS/bin/mw-keyboard"

cat > "$ROOTFS/bin/mw-events" << 'MW_EVENTS'
#!/bin/sh
exec /bin/nxev "$@"
MW_EVENTS
chmod +x "$ROOTFS/bin/mw-events"

cat > "$ROOTFS/bin/mw-clock" << 'MW_CLOCK'
#!/bin/sh
exec /bin/nxclock "$@"
MW_CLOCK
chmod +x "$ROOTFS/bin/mw-clock"

cat > "$ROOTFS/bin/mw-calc" << 'MW_CALC'
#!/bin/sh
exec /bin/nxcalc "$@"
MW_CALC
chmod +x "$ROOTFS/bin/mw-calc"

cat > "$ROOTFS/bin/start-microwindows" << 'MW_START'
#!/bin/sh
export HOME=/root
export MWFONTDIR=/usr/share/microwindows/pcf

/bin/be300-vtmode graphics >/dev/null 2>&1 || true
printf '\033[?25l' >/dev/tty0 2>/dev/null || true
exec </dev/null >/tmp/microwindows.log 2>&1
/bin/rm -f /tmp/.nano-X

/bin/nano-X &
server_pid=$!
client_pids=

cleanup() {
    for pid in $client_pids; do
        kill "$pid" 2>/dev/null
    done
    kill "$server_pid" 2>/dev/null
    /bin/be300-vtmode text >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_server() {
    count=0
    while [ ! -e /tmp/.nano-X ]; do
        kill -0 "$server_pid" 2>/dev/null || return 1
        count=$((count + 1))
        [ "$count" -lt 2000000 ] || return 1
    done
    return 0
}

if ! wait_server; then
    echo "nano-X did not create /tmp/.nano-X" >&2
    exit 1
fi

case "$1" in
terminal)
    /bin/nxterm
    ;;
browser)
    /bin/nxkbd &
    client_pids="$client_pids $!"
    /bin/nxweb "${2:-http://example.com/}"
    ;;
keyboard)
    /bin/nxkbd
    ;;
all)
    /bin/nxkbd &
    kb_pid=$!
    client_pids="$client_pids $kb_pid"
    /bin/nxweb "${2:-http://example.com/}" &
    web_pid=$!
    client_pids="$client_pids $web_pid"
    /bin/nxterm &
    term_pid=$!
    client_pids="$client_pids $term_pid"
    wait "$web_pid" "$term_pid"
    kill "$kb_pid" 2>/dev/null
    ;;
launcher|"")
    while :; do
        /bin/nxlaunch /etc/nxlaunch.cnf
        echo "nxlaunch exited; restarting"
    done
    ;;
*)
    echo "usage: start-microwindows [launcher|terminal|browser [url]|keyboard|all [url]]" >&2
    exit 2
    ;;
esac
MW_START
chmod +x "$ROOTFS/bin/start-microwindows"
cd /work
else
echo "=== Building Qt/Embedded + OPIE for BE-300 ==="
OPIE_CONFIG="$OPIE_CONFIG" \
OPIE_BUILD_STAMP="$OPIE_BUILD_STAMP" \
OPIE_PROFILE="$OPIE_PROFILE" \
OPIE_EXTRA_DEFS="$OPIE_EXTRA_DEFS" \
    /work/board/opie/build_opie_rootfs.sh "$ROOTFS" "$MUSL_SPECS" "$KHDRS"
cd /work
fi

# Create standard busybox symlinks. We can't run ./busybox on the host
# (different arch), so use a hardcoded list of the applets we need.
for applet in sh ash mount umount echo cat ls ln cp mv rm mkdir rmdir \
              pwd chmod chown uname date ps kill sleep \
              dmesg true false clear printf head tail wc grep sed awk \
              mknod sync poweroff reboot halt which env find test \
              vi more less switch_root pivot_root \
              dd hexdump od xxd \
              ifconfig ip route arp arping ping ping6 hostname netstat \
              nslookup wget telnet ftpget ftpput nc traceroute udhcpc \
              ipcalc nameif; do
    ln -sf /bin/busybox "$ROOTFS/bin/$applet"
done

# BusyBox 1.24.2's wget applet faults on this VR4131/musl build after DNS.
# Keep BusyBox for the rest of the network tools, but replace /bin/wget with a
# small static HTTP fetcher so the boot smoke test can verify TCP/HTTP.
mipsel-linux-gnu-gcc -march=mips2 -Os -static \
    -specs "$MUSL_SPECS" -isystem "$KHDRS/include" \
    -B/tmp/libgcc_patched \
    -o /tmp/be300-wget /work/board/casio-be300/be300_wget.c \
    /tmp/libgcc_helpers.o
mipsel-linux-gnu-strip /tmp/be300-wget
/bin/rm -f "$ROOTFS/bin/wget"
cp /tmp/be300-wget "$ROOTFS/bin/wget"
chmod +x "$ROOTFS/bin/wget"

# busybox-as-init reads /etc/inittab. The kernel mounts JFFS2 as `/` and execs
# /sbin/init.
ln -sf /bin/busybox "$ROOTFS/sbin/init"

mkdir -p "$ROOTFS/etc"
ln -sf /tmp/resolv.conf "$ROOTFS/etc/resolv.conf"

cat > "$ROOTFS/usr/share/udhcpc/default.script" << 'UDHCPC_SCRIPT'
#!/bin/sh

RESOLV_CONF=/tmp/resolv.conf

case "$1" in
deconfig)
    /bin/ifconfig "$interface" 0.0.0.0
    ;;

bound|renew)
    if [ -n "$broadcast" ]; then
        /bin/ifconfig "$interface" "$ip" netmask "$subnet" broadcast "$broadcast"
    else
        /bin/ifconfig "$interface" "$ip" netmask "$subnet"
    fi

    while /bin/route del default gw 0.0.0.0 dev "$interface" 2>/dev/null; do
        :
    done

    metric=0
    for gw in $router; do
        /bin/route add default gw "$gw" dev "$interface" metric "$metric"
        metric=$(($metric + 1))
    done

    tmp_resolv="${RESOLV_CONF}.$$"
    : > "$tmp_resolv"
    if [ -n "$domain" ]; then
        echo "search $domain" >> "$tmp_resolv"
    fi
    if [ -n "$dns" ]; then
        for ns in $dns; do
            echo "nameserver $ns" >> "$tmp_resolv"
        done
    else
        echo "nameserver 10.0.0.254" >> "$tmp_resolv"
    fi
    /bin/mv "$tmp_resolv" "$RESOLV_CONF"
    ;;
esac
UDHCPC_SCRIPT
chmod +x "$ROOTFS/usr/share/udhcpc/default.script"

cat > "$ROOTFS/bin/start-network" << 'NET_START'
#!/bin/sh

LOG=/tmp/network.log

log() {
    echo "[net] $*"
    echo "[net] $*" >>"$LOG"
    echo "[net] $*" >/dev/kmsg 2>/dev/null || true
}

: >"$LOG"
/bin/ifconfig lo 127.0.0.1 up 2>>"$LOG" || true

if [ ! -d /sys/class/net/eth0 ]; then
    log "eth0 not present; boot with --ne2000 to enable networking"
    exit 0
fi

log "bringing up eth0"
if ! /bin/ifconfig eth0 up >>"$LOG" 2>&1; then
    log "could not bring eth0 up"
    exit 0
fi

log "starting DHCP on eth0"
(
    /bin/udhcpc -i eth0 -s /usr/share/udhcpc/default.script \
        -p /tmp/udhcpc.eth0.pid -q -t 5 -T 3
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[net] DHCP configured eth0" >>"$LOG"
        echo "[net] DHCP configured eth0" >/dev/kmsg 2>/dev/null || true
    else
        echo "[net] DHCP failed on eth0 rc=$rc" >>"$LOG"
        echo "[net] DHCP failed on eth0 rc=$rc" >/dev/kmsg 2>/dev/null || true
    fi
) &

exit 0
NET_START
chmod +x "$ROOTFS/bin/start-network"

cat > "$ROOTFS/bin/ne2000-net-test" << 'NET_TEST'
#!/bin/sh

log() {
    echo "[net] $*"
    echo "[net] $*" >/dev/kmsg 2>/dev/null || true
}

fail() {
    log "FAIL $*"
    exit 1
}

log "starting NE2000 DHCP/wget smoke test"
/bin/ifconfig lo 127.0.0.1 up 2>/dev/null || true

[ -d /sys/class/net/eth0 ] || fail "eth0 not present; boot with --ne2000"

log "bringing up eth0"
/bin/ifconfig eth0 up || fail "could not bring eth0 up"

log "requesting DHCP lease on eth0"
/bin/udhcpc -i eth0 -s /usr/share/udhcpc/default.script \
    -p /tmp/udhcpc.eth0.pid -q -n -t 5 -T 3 || fail "DHCP lease failed"

log "eth0 configuration"
/bin/ifconfig eth0 || true
/bin/route -n || true
[ -f /etc/resolv.conf ] && /bin/cat /etc/resolv.conf

log "checking DNS"
/bin/nslookup google.com || fail "nslookup google.com failed"

log "fetching google.com"
/bin/rm -f /tmp/google.html
/bin/wget -T 30 -O /tmp/google.html google.com || fail "wget google.com failed"
[ -s /tmp/google.html ] || fail "wget google.com produced an empty file"

log "PASS wget google.com"
NET_TEST
chmod +x "$ROOTFS/bin/ne2000-net-test"

if [ "$BE300_UI" = "opie" ] || [ "$BE300_UI" = "opie64" ]; then
cat > "$ROOTFS/etc/inittab" << 'INITTAB'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/mount -t tmpfs -o size=768k tmpfs /root
::sysinit:/bin/mkdir -p /root/Settings /root/Applications /root/Documents
::sysinit:/bin/echo "=== Casio BE-300 Linux 4.2.9 (BusyBox + OPIE) ==="
::sysinit:/bin/echo "  OPIE starts on tty0; serial shell is ttyVR0."
::sysinit:/bin/start-network
tty0::once:/bin/start-opie
ttyVR0::respawn:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
INITTAB
else
cat > "$ROOTFS/etc/inittab" << 'INITTAB'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -o remount,rw /
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/echo "=== Casio BE-300 Linux 4.2.9 (BusyBox + Nano-X) ==="
::sysinit:/bin/echo "  Microwindows starts on tty0; serial shell is ttyVR0."
::sysinit:/bin/start-network
tty0::respawn:/bin/start-microwindows
ttyVR0::respawn:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
INITTAB
fi

# The kernel boots straight off the JFFS2 rootfs in NAND mtd3 — no embedded
# initramfs. Clean up artifacts from older runs that did build one.
rm -rf /work/initramfs_be300 /work/initramfs_list.txt

cd /work

# Keep the old ramdisk init approach commented out for reference.
# To revert, replace the above with the ramdisk_init.S approach.
if false; then
cat > /dev/null << 'INITASM_DISABLED'
	.set noreorder
	.text
	.globl __start
	.type __start, @function

#define __NR_read       4003
#define __NR_write      4004
#define __NR_open       4005
#define __NR_close      4006
#define __NR_mount      4021
#define __NR_mkdir      4039
#define __NR_chdir      4012
#define __NR_pivot_root 4216
#define __NR_chroot     4061
#define __NR_execve     4011
#define __NR_pause      4029
#define __NR_dup        4041

__start:
	/* Print banner */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_banner
	li	$a2, msg_banner_len
	syscall
	nop

	/* mount devtmpfs on /dev */
	li	$v0, __NR_mount
	la	$a0, s_devtmpfs
	la	$a1, s_dev
	la	$a2, s_devtmpfs
	li	$a3, 0
	addiu	$sp, $sp, -16
	sw	$zero, 16($sp)
	syscall
	nop
	addiu	$sp, $sp, 16

	/* Print B */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_b
	li	$a2, 2
	syscall
	nop

	/* open /ramdisk.gz */
	li	$v0, __NR_open
	la	$a0, s_ramdisk_gz
	li	$a1, 0		/* O_RDONLY */
	syscall
	nop
	move	$s0, $v0
	bltz	$s0, err1
	nop

	/* Print C */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_c
	li	$a2, 2
	syscall
	nop

	/* open /dev/ram0 */
	li	$v0, __NR_open
	la	$a0, s_ram0
	li	$a1, 1		/* O_WRONLY */
	syscall
	nop
	move	$s1, $v0
	bltz	$s1, err2
	nop

	/* Print D */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_d
	li	$a2, 2
	syscall
	nop

	/* Copy loop: ramdisk.gz -> /dev/ram0 */
	addiu	$sp, $sp, -512
	move	$s2, $sp
copy_loop:
	li	$v0, __NR_read
	move	$a0, $s0
	move	$a1, $s2
	li	$a2, 512
	syscall
	nop
	move	$s3, $v0
	blez	$s3, copy_done
	nop

	li	$v0, __NR_write
	move	$a0, $s1
	move	$a1, $s2
	move	$a2, $s3
	syscall
	nop
	b	copy_loop
	nop

copy_done:
	li	$v0, __NR_close
	move	$a0, $s0
	syscall
	nop
	li	$v0, __NR_close
	move	$a0, $s1
	syscall
	nop

	/* Print E */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_e
	li	$a2, 2
	syscall
	nop

	/* mkdir /mnt */
	li	$v0, __NR_mkdir
	la	$a0, s_mnt
	li	$a1, 0755
	syscall
	nop

	/* mount /dev/ram0 as ext2 on /mnt */
	li	$v0, __NR_mount
	la	$a0, s_ram0
	la	$a1, s_mnt
	la	$a2, s_ext2
	li	$a3, 0
	addiu	$sp, $sp, -16
	sw	$zero, 16($sp)
	syscall
	nop
	addiu	$sp, $sp, 16
	bnez	$v0, err3
	nop

	/* Print F */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_f
	li	$a2, 2
	syscall
	nop

	/* chdir /mnt, pivot_root, chroot */
	li	$v0, __NR_chdir
	la	$a0, s_mnt
	syscall
	nop

	li	$v0, __NR_mkdir
	la	$a0, s_oldroot
	li	$a1, 0755
	syscall
	nop

	li	$v0, __NR_pivot_root
	la	$a0, s_dot
	la	$a1, s_oldroot
	syscall
	nop

	li	$v0, __NR_chroot
	la	$a0, s_dot
	syscall
	nop

	/* Print G */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_g
	li	$a2, 2
	syscall
	nop

	/* Reopen console in new root */
	li	$v0, __NR_close
	li	$a0, 0
	syscall
	nop
	li	$v0, __NR_close
	li	$a0, 1
	syscall
	nop
	li	$v0, __NR_close
	li	$a0, 2
	syscall
	nop
	li	$v0, __NR_open
	la	$a0, s_dev_console
	li	$a1, 2		/* O_RDWR */
	syscall
	nop
	li	$v0, __NR_dup
	li	$a0, 0
	syscall
	nop
	li	$v0, __NR_dup
	li	$a0, 0
	syscall
	nop

	/* Print H + newline */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_h
	li	$a2, 3
	syscall
	nop

	/* exec /sbin/init */
	li	$v0, __NR_execve
	la	$a0, s_sbin_init
	la	$a1, argv_init
	li	$a2, 0
	syscall
	nop

	/* exec /bin/sh fallback */
	li	$v0, __NR_execve
	la	$a0, s_bin_sh
	la	$a1, argv_sh
	li	$a2, 0
	syscall
	nop

	/* Print X = exec failed */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_x
	li	$a2, 3
	syscall
	nop
	b	hang
	nop

err1:
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_e1
	li	$a2, msg_e1_len
	syscall
	nop
	b	hang
	nop

err2:
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_e2
	li	$a2, msg_e2_len
	syscall
	nop
	b	hang
	nop

err3:
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_e3
	li	$a2, msg_e3_len
	syscall
	nop
	b	hang
	nop

hang:
1:	li	$v0, __NR_pause
	syscall
	nop
	b	1b
	nop

	.data
	.align 2
msg_banner:	.ascii "\n=== BE-300 Linux 4.2.9 ===\nInit: "
msg_banner_len = . - msg_banner
msg_b:	.ascii "B "
msg_c:	.ascii "C "
msg_d:	.ascii "D "
msg_e:	.ascii "E "
msg_f:	.ascii "F "
msg_g:	.ascii "G "
msg_h:	.ascii "H\n"
msg_x:	.ascii "X\n"
msg_e1:	.ascii "ERR: open ramdisk.gz\n"
msg_e1_len = . - msg_e1
msg_e2:	.ascii "ERR: open /dev/ram0\n"
msg_e2_len = . - msg_e2
msg_e3:	.ascii "ERR: mount ext2 (expected)\n"
msg_e3_len = . - msg_e3
s_devtmpfs:	.asciz "devtmpfs"
s_dev:		.asciz "/dev"
s_dev_console:	.asciz "/dev/console"
s_ramdisk_gz:	.asciz "/ramdisk.gz"
s_ram0:		.asciz "/dev/ram0"
s_mnt:		.asciz "/mnt"
s_oldroot:	.asciz "oldroot"
s_dot:		.asciz "."
s_ext2:		.asciz "ext2"
s_sbin_init:	.asciz "/sbin/init"
s_bin_sh:	.asciz "/bin/sh"
s_proc:		.asciz "/proc"
s_procfs:	.asciz "proc"
	.align 2
argv_init:	.word s_sbin_init, 0
argv_sh:	.word s_bin_sh, 0

	/* no BSS - use stack for copy buffer */
INITASM_DISABLED
fi
# End of disabled ramdisk init approach

###############################################################################
# Phase 2: Download and extract kernel
###############################################################################

echo "=== Phase 2: Preparing kernel source ==="

echo "--- Downloading kernel source ---"
if [ ! -f linux-4.2.9-patched.tar.xz ]; then
    wget "$KERNEL_SOURCE_URL"
fi

echo "--- Extracting kernel (clean) ---"
rm -rf linux-4.2.9
tar xf linux-4.2.9-patched.tar.xz

cd linux-4.2.9

###############################################################################
# Phase 3: Apply BE-300 kernel patch series
###############################################################################

echo "=== Phase 3: Applying BE-300 kernel patch series ==="
/work/scripts/apply_patch_series.sh "$KERNEL_PATCH_SERIES" /work/linux-4.2.9
cp /work/board/casio-be300/touch_be300.c \
   /work/linux-4.2.9/arch/mips/vr41xx/casio-be300/touch_be300.c
cp /work/board/casio-be300/logo_linux4be_clut224.ppm \
   /work/linux-4.2.9/drivers/video/logo/logo_linux4be_clut224.ppm

###############################################################################
# Phase 5: Configure kernel
###############################################################################

echo "=== Phase 5: Configuring kernel ==="

# Generate .config
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- be300_defconfig

for fragment in $KERNEL_CONFIG_FRAGMENTS; do
    if [ ! -f "$fragment" ]; then
        echo "ERROR: kernel config fragment not found: $fragment" >&2
        exit 1
    fi
    ./scripts/kconfig/merge_config.sh -m .config "$fragment"
done

# Resolve any missing options
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- olddefconfig

# cfb helpers are now selected by CASIO_BE300 in Kconfig

###############################################################################
# Phase 6: Build kernel
###############################################################################

echo "=== Phase 6: Building kernel ==="

# Using -j1 to avoid "Too many open files" in constrained environments
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- vmlinux -j1 || true

if [ -f vmlinux ]; then
    echo "=== SUCCESS: vmlinux created ==="
    ls -l vmlinux
else
    echo "=== FAILURE: vmlinux NOT created ==="
    exit 1
fi

###############################################################################
# Phase 7: Build the stage-1 SPL and pack it together with the kernel into a
# NAND image bootable through `./bin/be300 --nand`.
#
# The boot ROM's record walker is sized for a small SPL (empirical limit
# around 352 KB of NAND traffic per run), so we don't try to package a 3 MB
# kernel as a single B000FF container. Instead:
#   - Stage-1 SPL (board/casio-be300/spl.c + spl_start.S, linked at
#     0x80F00000) is wrapped as the B000FF container at NAND offset 0x4000
#     and is what the boot ROM actually loads.
#   - The kernel is laid out raw at NAND offset 0x14000 (partition 2). The
#     SPL reads it page-by-page via the VRC4173 SPL transfer engine and
#     jumps to kernel_entry.
###############################################################################

echo ""
echo "=== Phase 7: Building stage-1 SPL ==="

cd /work/board/casio-be300
SPL_DIR=/work/linux-4.2.9/spl_build
mkdir -p "$SPL_DIR"

# Extract kernel constants from vmlinux for the SPL to embed.
python3 - <<'PYEOF' >"$SPL_DIR/kernel_consts.txt"
import struct, sys
data = open('/work/linux-4.2.9/vmlinux','rb').read()
e_entry = struct.unpack_from('<I', data, 24)[0]
e_phoff = struct.unpack_from('<I', data, 28)[0]
e_phnum = struct.unpack_from('<H', data, 44)[0]
loads = []
for i in range(e_phnum):
    o = e_phoff + i*32
    p_type, p_offset, p_vaddr, p_paddr, p_filesz, *_ = struct.unpack_from("<IIIIIIII", data, o)
    if p_type == 1 and p_filesz:
        loads.append((p_vaddr, p_filesz))
base = min(a for a, _ in loads)
end = max(a + s for a, s in loads)
print(f"KERNEL_LOAD_VA=0x{base:08X}")
print(f"KERNEL_ENTRY_VA=0x{e_entry:08X}")
print(f"KERNEL_SIZE=0x{end - base:X}")
PYEOF

# shellcheck disable=SC1091
. "$SPL_DIR/kernel_consts.txt"

echo "  KERNEL_LOAD_VA=$KERNEL_LOAD_VA"
echo "  KERNEL_ENTRY_VA=$KERNEL_ENTRY_VA"
echo "  KERNEL_SIZE=$KERNEL_SIZE"

CC=mipsel-linux-gnu-gcc
LD=mipsel-linux-gnu-ld
SPL_CFLAGS="-march=mips2 -mabi=32 -mno-abicalls -fno-pic -nostdlib \
    -fno-builtin -ffreestanding -Os -g -fno-stack-protector \
    -DKERNEL_LOAD_VA=${KERNEL_LOAD_VA}u \
    -DKERNEL_ENTRY_VA=${KERNEL_ENTRY_VA}u \
    -DKERNEL_SIZE=${KERNEL_SIZE}u"

$CC $SPL_CFLAGS -c -o "$SPL_DIR/spl_start.o" /work/board/casio-be300/spl_start.S
$CC $SPL_CFLAGS -c -o "$SPL_DIR/spl.o"      /work/board/casio-be300/spl.c
$LD -m elf32ltsmip -T /work/board/casio-be300/spl.lds \
    -o "$SPL_DIR/spl.elf" "$SPL_DIR/spl_start.o" "$SPL_DIR/spl.o"

ls -l "$SPL_DIR/spl.elf"

cd /work

echo ""
echo "=== Phase 7b: Building JFFS2 rootfs image ==="
# mtd3 is 0xB00000 bytes (11 MiB) starting at NAND offset 0x500000.
# NAND geometry: 32 pages × 512 B = 16 KiB erase block; 512 B page.
# --no-cleanmarkers is the right call for NAND (mtd's NAND wbuf path
# regenerates them at runtime). --little-endian matches the kernel.
ROOTFS_JFFS2="/work/linux-4.2.9/${ROOTFS_JFFS2_NAME}"
mkfs.jffs2 \
    --root="$ROOTFS" \
    --output="$ROOTFS_JFFS2" \
    --eraseblock=16384 \
    --pagesize=512 \
    --no-cleanmarkers \
    --pad=0xB00000 \
    --little-endian
ls -l "$ROOTFS_JFFS2"

echo ""
echo "=== Phase 7c: Packing NAND image ==="

python3 /work/tools/mk_be300_nand.py \
    --vmlinux /work/linux-4.2.9/vmlinux \
    --spl "$SPL_DIR/spl.elf" \
    --rootfs "$ROOTFS_JFFS2" \
    --out "/work/linux-4.2.9/${NAND_IMAGE_NAME}"

ls -l "/work/linux-4.2.9/${NAND_IMAGE_NAME}"
echo ""
echo "Test with:"
if [ "$BE300_UI" = "opie64" ]; then
    echo "  ./bin/be300 --sdram 64 --nand linux-4.2.9/${NAND_IMAGE_NAME} --speed 0"
    echo "  ./bin/be300 --sdram 64 --nand linux-4.2.9/${NAND_IMAGE_NAME} --cf cf.img"
    echo "  ./bin/be300 --sdram 64 --nand linux-4.2.9/${NAND_IMAGE_NAME} --ne2000 --net-mac 02:de:ad:be:ef:01"
else
    echo "  ./bin/be300 --nand linux-4.2.9/${NAND_IMAGE_NAME}"
    echo "  ./bin/be300 --nand linux-4.2.9/${NAND_IMAGE_NAME} --cf cf.img"
    echo "  ./bin/be300 --nand linux-4.2.9/${NAND_IMAGE_NAME} --ne2000 --net-mac 02:de:ad:be:ef:01"
fi
