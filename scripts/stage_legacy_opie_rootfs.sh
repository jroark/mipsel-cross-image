#!/bin/bash
# scripts/stage_legacy_opie_rootfs.sh
#
# Build the BusyBox + Opie 1.2.5 / Qt-Embedded 2.3.10 JFFS2 rootfs for the
# legacy BE-300 kernels (Linux 2.4.18 and 2.6.8.1).  Shared by
# build_be300_2_4_kernel.sh (BE300_2_4_UI=opie) and
# build_be300_2_6_kernel.sh so both images carry the same userspace, apps
# and look as the 4.2.9 OPIE image.
#
# Steps:
#   1. Run build_be300_kernel.sh with BE300_UI=opie BE300_LIBC=uclibc
#      BE300_ROOTFS_ONLY=1: musl/uClibc-ng/BusyBox/Qt/Opie into
#      /work/rootfs_be300_opie, no 4.2.9 kernel build.  uClibc-ng carries
#      the ENOSYS fallbacks both legacy kernels need (no pselect6,
#      renameat2, clock_* on 2.4; no pselect6, renameat2 on 2.6.8) and
#      LinuxThreads, so no TLS/rdhwr support is required from the kernel.
#   2. Replace the 4.2.9 runtime files (inittab, rcS, start-opie) with the
#      legacy-kernel variants: no devtmpfs (static devtable), ttyS0 dock
#      UART shell, tmpfs /tmp and /root, static NE2000 address.
#   3. Optionally rewrite ELF e_flags (2.4.18 only, see below).
#   4. mkfs.jffs2 with the device table.
#
# Usage (inside the mips-dev container):
#   scripts/stage_legacy_opie_rootfs.sh \
#       --label 2.6.8.1 \
#       --devtable board/casio-be300/be300_2_6_devtable.txt \
#       --out linux-4.2.9/rootfs-2_6-opie.jffs2 \
#       [--console tty0|ttyS0] [--sysfs] [--fix-elf-flags]

set -euo pipefail

REPO=/work
LABEL=""
DEVTABLE=""
JFFS2_OUT=""
CONSOLE=tty0
MOUNT_SYSFS=0
FIX_ELF_FLAGS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL=$2; shift 2 ;;
        --devtable) DEVTABLE=$2; shift 2 ;;
        --out) JFFS2_OUT=$2; shift 2 ;;
        --console) CONSOLE=$2; shift 2 ;;
        --sysfs) MOUNT_SYSFS=1; shift ;;
        --fix-elf-flags) FIX_ELF_FLAGS=1; shift ;;
        *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    esac
done

[[ -n "$LABEL" && -n "$DEVTABLE" && -n "$JFFS2_OUT" ]] || {
    echo "usage: $0 --label <kver> --devtable <file> --out <jffs2> [--console tty0|ttyS0] [--sysfs] [--fix-elf-flags]" >&2
    exit 2
}
case "$CONSOLE" in
    tty0|ttyS0) ;;
    *) echo "ERROR: --console must be tty0 or ttyS0 (got '$CONSOLE')" >&2; exit 2 ;;
esac
[[ "$DEVTABLE" = /* ]] || DEVTABLE="$REPO/$DEVTABLE"
[[ "$JFFS2_OUT" = /* ]] || JFFS2_OUT="$REPO/$JFFS2_OUT"
[[ -f "$DEVTABLE" ]] || { echo "ERROR: $DEVTABLE missing" >&2; exit 1; }

OPIE_ROOTFS_DIR="/work/rootfs_be300_opie"

echo "--- Building BusyBox + Opie 1.2.5 rootfs via build_be300_kernel.sh ---"
BE300_UI=opie BE300_LIBC=uclibc BE300_ROOTFS_ONLY=1 \
    bash "$REPO/build_be300_kernel.sh"

[[ -d "$OPIE_ROOTFS_DIR" ]] || {
    echo "ERROR: build_be300_kernel.sh did not produce $OPIE_ROOTFS_DIR" >&2
    exit 1
}

# Stage the legacy-kernel runtime overlay on top of /work/rootfs_be300_opie.
# The 4.2.9 build wrote an inittab that mounts devpts and starts start-opie
# on tty0; rewrite it so the same intent works without devtmpfs, with
# /dev/ttyS0 instead of /dev/ttyVR0, and tmpfs on /tmp + /root because the
# JFFS2 mtdblock3 partition is read-mostly.
echo "--- Staging Linux $LABEL inittab + start-opie + pointercal ---"

rm -f "$OPIE_ROOTFS_DIR/etc/inittab"
rm -f "$OPIE_ROOTFS_DIR/etc/init.d/rcS"

mkdir -p "$OPIE_ROOTFS_DIR/etc/init.d" "$OPIE_ROOTFS_DIR/dev/pts" \
         "$OPIE_ROOTFS_DIR/tmp" "$OPIE_ROOTFS_DIR/root" \
         "$OPIE_ROOTFS_DIR/initrd" "$OPIE_ROOTFS_DIR/proc" \
         "$OPIE_ROOTFS_DIR/sys"

cat > "$OPIE_ROOTFS_DIR/etc/inittab" <<INITTAB
# BE-300 Linux $LABEL + Opie inittab.
# tty0 is the framebuffer console (be300-vtmode will flip it to
# KD_GRAPHICS once start-opie runs).
# ttyS0 is the VRC4173 companion SIU dock UART.  The BE-300 serial
# driver programs it as 115200 8N1, asserts DTR/RTS for the emulator
# serial1 bridge, and polls RX into the tty layer. Pair it with:
#   ./bin/be300 ... --serial1-bridge pty:auto
::sysinit:/etc/init.d/rcS
tty0::once:/bin/start-opie
ttyS0::askfirst:/bin/sh
::ctrlaltdel:/sbin/reboot
INITTAB
if [[ "$CONSOLE" == "ttyS0" ]]; then
    sed -i 's|^ttyS0::askfirst:/bin/sh$|# ttyS0 is the kernel console for this build; no askfirst shell here.|' \
        "$OPIE_ROOTFS_DIR/etc/inittab"
fi

SYSFS_MOUNT=""
if [[ "$MOUNT_SYSFS" == "1" ]]; then
    SYSFS_MOUNT='echo "rcS: mount sysfs"
mount -t sysfs sysfs /sys'
fi

cat > "$OPIE_ROOTFS_DIR/etc/init.d/rcS" <<RCSEOF
#!/bin/sh
# BE-300 Linux $LABEL + Opie boot script.
#
# Output goes to the inherited stdout (= /dev/console = tty0/fbcon).
# fbcon renders on the LCD framebuffer; we read it via the emulator
# screenshot path. Keep rcS output off /dev/ttyS0 in the default build so
# the askfirst shell owns the serial link cleanly.
echo "rcS: mount proc"
mount -t proc proc /proc
$SYSFS_MOUNT
echo "rcS: mount devpts"
mount -t devpts devpts /dev/pts
echo "rcS: mount tmpfs /tmp"
mount -t tmpfs tmpfs /tmp
echo "rcS: mount tmpfs /root"
mount -t tmpfs -o size=768k tmpfs /root
echo "rcS: mkdir /root/*"
mkdir -p /root/Settings /root/Applications /root/Documents
export LD_LIBRARY_PATH=/opt/QtPalmtop/lib:/lib
# Loopback (BusyBox ifconfig does not add the 127/8 route itself here).
/bin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up
/bin/route add -net 127.0.0.0 netmask 255.0.0.0 lo 2>/dev/null
# eth0 (NE2000 at 0x300 IRQ 72; boot with --ne2000).  The emulator's
# gxemul NAT is 10.0.0.0/8 with gateway/DNS at 10.0.0.254, as in the
# pgui/mw profiles.  /etc/resolv.conf links to /tmp/resolv.conf.
# printf, not echo: the console=ttyS0 build strips rcS "echo " lines.
if /bin/ifconfig eth0 10.0.0.1 netmask 255.0.0.0 up 2>/dev/null; then
    /bin/route add default gw 10.0.0.254 2>/dev/null
    printf 'nameserver 10.0.0.254\n' > /tmp/resolv.conf
fi
echo "=== Casio BE-300 Linux $LABEL (BusyBox + Opie) rcS done ==="
RCSEOF
sed -i '/^$/d;' "$OPIE_ROOTFS_DIR/etc/init.d/rcS"
chmod 0755 "$OPIE_ROOTFS_DIR/etc/init.d/rcS"
if [[ "$CONSOLE" == "ttyS0" ]]; then
    # Keep the kernel printk console on ttyS0, but avoid mixing rcS
    # progress output with the same serial login path.
    sed -i '/^echo /d' "$OPIE_ROOTFS_DIR/etc/init.d/rcS"
fi

# Identity pointercal so Qt's TPanel handler doesn't refuse to start
# if the user hasn't calibrated yet.
mkdir -p "$OPIE_ROOTFS_DIR/etc"
[[ -f "$OPIE_ROOTFS_DIR/etc/pointercal" ]] || \
    echo '1 0 0 0 1 0 1' > "$OPIE_ROOTFS_DIR/etc/pointercal"

# start-opie enters framebuffer graphics mode and then execs qpe so no
# resident shell remains in the 16 MiB profile.
cat > "$OPIE_ROOTFS_DIR/bin/start-opie" <<'OPIEEOF'
#!/bin/sh
export HOME=/root
export QTDIR=/opt/QtPalmtop
export QPEDIR=/opt/QtPalmtop
export OPIEDIR=/opt/QtPalmtop
export PATH=/opt/QtPalmtop/bin:/bin:/sbin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=/opt/QtPalmtop/lib:/lib
export QWS_DISPLAY="LinuxFb:/dev/fb0:mmWidth80:mmHeight106"
export QWS_SIZE="240x320"
# Touch is /dev/input/event1 and the Stowaway keyboard /dev/input/event0
# on both legacy kernels (driver registration order).  The "/dev/input/"
# prefix activates the patched Qt QVrTPanelHandlerPrivate evdev branch,
# identical to the 4.2.9 path.
export QWS_MOUSE_PROTO="${QWS_MOUSE_PROTO:-TPanel:/dev/input/event1}"
export QWS_KEYBOARD="${QWS_KEYBOARD:-USB:/dev/input/event0}"
export OPIE_NO_SOUND=1
export LD_BIND_NOW=1
export BE300_QWS_ACCEL="${BE300_QWS_ACCEL:-0}"

exec </dev/null

/bin/be300-vtmode graphics >/dev/null 2>&1 || true
printf '\033[?25l' >/dev/tty0 2>/dev/null || true
[ -x /bin/be300-fbrefresh ] && /bin/be300-fbrefresh -i 250 >/dev/null 2>&1 &
exec /opt/QtPalmtop/bin/qpe -qws >/tmp/qpe.log 2>&1
OPIEEOF
chmod 0755 "$OPIE_ROOTFS_DIR/bin/start-opie"

# mkfs.jffs2 in unprivileged Docker can't traverse char/block special
# files the 4.2.9 build left in $ROOTFS/dev -- strip them so --devtable
# is the sole source of truth.
rm -rf "$OPIE_ROOTFS_DIR/dev"
mkdir -p "$OPIE_ROOTFS_DIR/dev"

if [[ "$FIX_ELF_FLAGS" == "1" ]]; then
    # Rewrite ELF e_flags arch bits from mips32r2 (0x70000000) to mips2
    # (0x10000000) on every MIPS ELF in the rootfs.  Modern binutils
    # stamps -march=mips2 PIC output with the post-2009 renumbering
    # where 0x70000000 means mips32r2; 2.4.18's elf_check_arch uses the
    # original numbering where that bit pattern means MIPS64 and
    # rejects the binary with ENOEXEC.  The code is actually -march=mips2
    # (the toolchain wrapper forces it); only the metadata field is wrong.
    # 2.6.8.1's elf_check_arch only checks the ABI bits, so it does not
    # need this.
    echo "--- Rewriting ELF e_flags arch bits for 2.4.18 elf_check_arch ---"
    python3 - "$OPIE_ROOTFS_DIR" <<'PYEOF'
import os, struct, sys
root = sys.argv[1]
patched = 0
for dirpath, _, files in os.walk(root):
    for fn in files:
        p = os.path.join(dirpath, fn)
        try:
            if os.path.islink(p):
                continue
            with open(p, 'rb') as f:
                head = f.read(40)
            if head[:4] != b'\x7fELF':
                continue
            # ELF32 LE only; check EI_DATA (5) and EI_CLASS (4).
            if head[4] != 1 or head[5] != 1:
                continue
            # e_machine at offset 18, e_flags at offset 36.
            machine = struct.unpack_from('<H', head, 18)[0]
            if machine != 8:  # EM_MIPS
                continue
            ef = struct.unpack_from('<I', head, 36)[0]
            new = (ef & ~0xF0000000) | 0x10000000
            if new == ef:
                continue
            with open(p, 'r+b') as f:
                f.seek(36)
                f.write(struct.pack('<I', new))
            patched += 1
        except (OSError, struct.error):
            pass
print(f'patched {patched} ELF files (0x70000000 -> 0x10000000)')
PYEOF
fi

echo "--- Building JFFS2 image $JFFS2_OUT ---"
mkfs.jffs2 --root="$OPIE_ROOTFS_DIR" \
    --devtable="$DEVTABLE" \
    --eraseblock=16384 --pagesize=512 --no-cleanmarkers \
    --pad=0xB00000 --little-endian \
    --output="$JFFS2_OUT"
echo "  rootfs : $(ls -la "$JFFS2_OUT" | awk '{print $5, $9}')"
