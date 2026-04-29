#!/bin/bash
set -e

KERNEL_SOURCE_URL="http://distro.ibiblio.org/tinycorelinux/7.x/x86/release/src/kernel/linux-4.2.9-patched.tar.xz"
BUSYBOX_VERSION="1.24.2"

###############################################################################
# Phase 0a: Rebuild musl with -march=mips2 (no SPECIAL2 mul instruction)
###############################################################################
# VR4131 is MIPS III, which predates MIPS32. It does NOT implement the
# SPECIAL2 opcode space (where MIPS32 `mul rd, rs, rt` lives). The stock
# musl-mipsel built with -march=mips32 uses `mul` throughout, which raises
# a Reserved Instruction exception on VR4131 (both emulator and real HW).
# Rebuild with -march=mips2 which uses only mult/mflo.

MUSL_MIPS2="/work/musl-mipsel"
if ! mipsel-linux-gnu-objdump -d "$MUSL_MIPS2/lib/libc.a" 2>/dev/null \
        | grep -qE '^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]+mul[[:space:]]'; then
    echo "--- musl-mipsel already mul-free, skipping rebuild ---"
else
    echo "=== Phase 0a: Rebuilding musl-mipsel with -march=mips2 ==="
    MUSL_SRC="/work/musl-1.2.5"
    if [ ! -d "$MUSL_SRC" ]; then
        cd /work
        tar xf musl-1.2.5.tar.gz
    fi
    cd "$MUSL_SRC"
    make distclean 2>/dev/null || true
    # Explicitly set cross tools so musl doesn't try mipsel-linux-musl-*
    CROSS=mipsel-linux-gnu-
    CC="${CROSS}gcc -march=mips2" \
    AR="${CROSS}ar" \
    RANLIB="${CROSS}ranlib" \
    LD="${CROSS}ld" \
        ./configure --target=mipsel-linux-gnu \
            --prefix="$MUSL_MIPS2" \
            --disable-shared 2>&1 | tail -5
    make CC="${CROSS}gcc -march=mips2" \
         AR="${CROSS}ar" \
         RANLIB="${CROSS}ranlib" \
         -j$(nproc) 2>&1 | tail -5
    make install 2>&1 | tail -5
    cd /work
fi

###############################################################################
# Phase 0: Prepare sanitized Linux UAPI headers for musl (needed by Phase 1)
###############################################################################

KHDRS="/work/musl-khdrs"
if [ ! -d "$KHDRS/include/linux" ]; then
    echo "=== Phase 0: Installing sanitized kernel headers for musl ==="
    # Use a separate untar to avoid touching the kernel build tree we will
    # configure later (the kernel tree gets blown away in Phase 2).
    mkdir -p /tmp/khdrs_src
    if [ ! -d /tmp/khdrs_src/linux-4.2.9 ]; then
        tar xf /work/linux-4.2.9-patched.tar.xz -C /tmp/khdrs_src
    fi
    # libc-compat.h in 4.2.9 only handles __GLIBC__. Musl sets _NETINET_IN_H
    # in its <netinet/in.h> too, so widen the outer guard so the inner
    # _NETINET_IN_H check applies for any libc. Without this, including
    # both musl's netinet/in.h and linux/in.h conflicts on sockaddr_in,
    # in_addr, etc. — which is what blocks BusyBox networking applets.
    sed -i 's@^#if defined(__GLIBC__)$@#if defined(__GLIBC__) || defined(_NETINET_IN_H)@' \
        /tmp/khdrs_src/linux-4.2.9/include/uapi/linux/libc-compat.h
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

yes "" | make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- oldconfig

# Build with musl + mips32 (no r2 instructions). Use musl-gcc wrapper
# via -specs. -nostdinc on the existing headers is not needed since musl
# specs handle include paths.
MUSL_SPECS="/work/musl-mipsel/lib/musl-gcc.specs"
# musl doesn't ship Linux UAPI headers (linux/*.h); use sanitized headers
# from linux-4.2.9 via `make headers_install` (see Phase 0 above).
# Patched libgcc.a: the stock libgcc (from the mips32r2 cross toolchain)
# uses the MIPS32 SPECIAL2 `mul` instruction in __divdi3/__moddi3/__udivdi3
# etc. VR4131 is MIPS III and doesn't support SPECIAL2 — it raises
# Reserved Instruction (SIGILL). Create a private libgcc.a that strips
# those .o files and adds mips2-compiled replacements.
mkdir -p /tmp/libgcc_patched
LIBGCC_ORIG=$(mipsel-linux-gnu-gcc -print-libgcc-file-name)
cp "$LIBGCC_ORIG" /tmp/libgcc_patched/libgcc.a
# Remove the offending .o files (those using SPECIAL2 mul)
mipsel-linux-gnu-ar d /tmp/libgcc_patched/libgcc.a \
    _divdi3.o _moddi3.o _udivdi3.o _umoddi3.o \
    _fixdfdi.o _fixunsdfdi.o _floatdidf.o _floatundidf.o \
    _lshrdi3.o _ashldi3.o _ashrdi3.o _negdi2.o \
    2>/dev/null || true
# Compile our replacements with -march=mips2 and add them to the patched archive
mipsel-linux-gnu-gcc -march=mips2 -O2 -c -o /tmp/libgcc_helpers.o \
    /work/board/casio-be300/libgcc_helpers.c
mipsel-linux-gnu-ar rcs /tmp/libgcc_patched/libgcc.a /tmp/libgcc_helpers.o

make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- \
    EXTRA_CFLAGS="-march=mips2 -specs $MUSL_SPECS -isystem $KHDRS/include" \
    EXTRA_LDFLAGS="-specs $MUSL_SPECS -B/tmp/libgcc_patched" \
    busybox -j$(nproc) 2>&1 | tail -5
ls -l busybox
mipsel-linux-gnu-strip busybox

# Populate full rootfs (this becomes the JFFS2 mtd3 partition).
ROOTFS="/work/rootfs_be300"
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
    -o /tmp/fb_mmap_test
mipsel-linux-gnu-strip /tmp/fb_mmap_test
cp /tmp/fb_mmap_test "$ROOTFS/bin/fb_mmap_test"
chmod +x "$ROOTFS/bin/fb_mmap_test"

# Phase B smoke test: query the PIU touchscreen input_dev capabilities.
mipsel-linux-gnu-gcc -march=mips2 -O2 -static \
    -specs "$MUSL_SPECS" -isystem "$KHDRS/include" \
    -B/tmp/libgcc_patched \
    /work/board/casio-be300/touch_query_test.c \
    -o /tmp/touch_query_test
mipsel-linux-gnu-strip /tmp/touch_query_test
cp /tmp/touch_query_test "$ROOTFS/bin/touch_query_test"
chmod +x "$ROOTFS/bin/touch_query_test"

# Phase C' — Microwindows / Nano-X (pure C, builds against musl + mips2,
# no libstdc++ needed). Builds the libnano-X.a static lib and a small set
# of demos with the server linked into each binary (LINK_APP_INTO_SERVER=Y),
# so each demo is a self-contained executable. Input devices wire through
# evdev: /dev/input/event0 (BE-300 buttons) and event1 (PIU touchscreen).
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

cd /work/microwindows/src
cp Configs/config.be300 config
make clean >/dev/null 2>&1 || true
MW_CC="mipsel-linux-gnu-gcc -march=mips2 -mfpxx -specs $MUSL_SPECS -isystem $KHDRS/include -B/tmp/libgcc_patched"
make -j$(nproc) MIPSTOOLSPREFIX="" \
    COMPILER=gcc \
    CC="$MW_CC" \
    AR="mipsel-linux-gnu-ar" \
    LDFLAGS="-static" \
    EXTRAFLAGS="" \
    2>&1 | tail -3 || true
echo "--- Microwindows artifacts ---"
ls -la /work/microwindows/src/lib/libnano-X.a /work/microwindows/src/bin/demo-hello 2>/dev/null
# Stage demo-hello into rootfs (stripped, ~400 KB)
mipsel-linux-gnu-strip /work/microwindows/src/bin/demo-hello
cp /work/microwindows/src/bin/demo-hello "$ROOTFS/bin/demo-hello"
chmod +x "$ROOTFS/bin/demo-hello"
# Stage a minimal font set so MWFONTDIR-less demos can fall back to disk if
# the built-in font picker misses.
mkdir -p "$ROOTFS/usr/share/microwindows/pcf"
cp /work/microwindows/src/fonts/pcf/*.pcf.gz "$ROOTFS/usr/share/microwindows/pcf/" 2>/dev/null || true
cd /work

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
    -o /tmp/be300-wget /work/board/casio-be300/be300_wget.c
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

cat > "$ROOTFS/etc/inittab" << 'INITTAB'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/echo "=== Casio BE-300 Linux 4.2.9 (BusyBox + Nano-X) ==="
::sysinit:/bin/echo "  Run /bin/demo-hello to launch a Nano-X demo."
::sysinit:/bin/ne2000-net-test
tty0::respawn:/bin/sh
ttyVR0::respawn:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
INITTAB

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
# Phase 3: Apply GCC 10+/11+ compatibility fixes
###############################################################################

echo "=== Phase 3: Applying GCC compatibility fixes ==="

# FIX 1: multiple definition of 'yylloc' (GCC 10+)
if [ -f scripts/dtc/dtc-lexer.lex.c_shipped ]; then
    sed -i 's/^YYLTYPE yylloc;/extern YYLTYPE yylloc;/' scripts/dtc/dtc-lexer.lex.c_shipped
fi

# FIX 2: GCC 11+ noreturn/const conflict in log2.h
find . -name "log2.h" -exec sed -i \
    's/____ilog2_NaN(void) __attribute__((noreturn, const))/____ilog2_NaN(void) __attribute__((noreturn))/g' {} +

# FIX 3: Disable -Werror
grep -rl "\-Werror" . | xargs sed -i 's/\-Werror\([[:space:]]\|$\)/ /g' || true
grep -rl "\-Werror" . | xargs sed -i 's/=\-Werror/=/g' || true

###############################################################################
# Phase 4: Inject BE300 board support
###############################################################################

echo "=== Phase 4: Injecting BE300 board support ==="

# Copy board support files (setup.c, sfb.c framebuffer, nand.c MTD glue,
# irq.c GIRQ0 demuxer, keys.c button driver, Makefile)
mkdir -p arch/mips/vr41xx/casio-be300
cp /work/board/casio-be300/setup.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/sfb.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/keys.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/nand.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/irq.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/stowaway_serio.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/touch_be300.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/Makefile arch/mips/vr41xx/casio-be300/

# Slow down kernel auto-repeat for the in-tree Stowaway keyboard driver.
# Defaults are REP_DELAY=250ms / REP_PERIOD=33ms (~30 Hz), which feels
# runaway-fast on the BE-300's slow framebuffer console. Set 400ms delay
# and 100ms period (10 Hz) on the input device right after EV_REP is
# advertised in skbd_connect.
sed -i 's@input_dev->evbit\[0\] = BIT_MASK(EV_KEY) | BIT_MASK(EV_REP);@&\n\tinput_dev->rep[REP_DELAY] = 400;\n\tinput_dev->rep[REP_PERIOD] = 100;@' \
    drivers/input/keyboard/stowaway.c

# Patch Kconfig: add CASIO_BE300 entry before endchoice
if ! grep -q "CASIO_BE300" arch/mips/vr41xx/Kconfig; then
    sed -i '/^endchoice$/i\
config CASIO_BE300\
\tbool "CASIO CASSIOPEIA BE-300"\
\tselect CEVT_R4K\
\tselect CSRC_R4K\
\tselect DMA_NONCOHERENT\
\tselect IRQ_MIPS_CPU\
\tselect ISA\
\tselect HAVE_PATA_PLATFORM\
\tselect SYS_SUPPORTS_32BIT_KERNEL\
\tselect SYS_SUPPORTS_LITTLE_ENDIAN\
\tselect SYS_HAS_EARLY_PRINTK\
\tselect FB_CFB_FILLRECT if FB\
\tselect FB_CFB_COPYAREA if FB\
\tselect FB_CFB_IMAGEBLIT if FB\
\tselect INPUT_POLLDEV\
' arch/mips/vr41xx/Kconfig
fi

# Add BE300 memory region in prom_init (common/init.c doesn't add memory,
# and mem= on command line seems to cause the kernel to allocate pages
# beyond physical RAM). Add explicit add_memory_region call.
# Register 16MB RAM.
sed -i '/^void __init prom_init(void)$/,/^}$/{
  /^}$/i\
\tadd_memory_region(0, 16 << 20, BOOT_MEM_RAM);
}' arch/mips/vr41xx/common/init.c

# The ~20 "Bad page state" pages have nonzero mapcount from an unknown
# source. Rather than hiding the symptom, reserve them so they're never
# allocated. Mark them as reserved during mem_init so the buddy allocator
# skips them entirely.
#
# Root cause: unknown. The corrupted PFNs scale with registered memory
# size (always the top ~2MB). Needs further investigation but reserving
# them prevents corrupted pages from being handed to userspace.
cat >> arch/mips/mm/init.c << 'BADPAGE_FIX'

/* BE300: Reserve pages with corrupted state so buddy allocator skips them */
#include <linux/mm.h>
static void __init be300_reserve_bad_pages(void)
{
	unsigned long pfn;
	int count = 0;

	for (pfn = 0; pfn < max_mapnr; pfn++) {
		struct page *page = pfn_to_page(pfn);
		if (page_mapcount(page) != 0) {
			SetPageReserved(page);
			init_page_count(page);
			page_mapcount_reset(page);
			count++;
		}
	}
	if (count)
		pr_info("BE300: reserved %d pages with bad mapcount\n", count);
}
BADPAGE_FIX

# Add forward declaration and call before free_all_bootmem
sed -i '/free_all_bootmem/{
  i\
\t{ extern void be300_reserve_bad_pages(void); be300_reserve_bad_pages(); }
}' arch/mips/mm/init.c
# Remove 'static' from the function definition
sed -i 's/static void __init be300_reserve_bad_pages/void __init be300_reserve_bad_pages/' arch/mips/mm/init.c

# Force clear_page and copy_page to use 32-bit stores (sw) instead of
# 64-bit stores (sd). The VR4131 is a 64-bit CPU but the emulator
# only runs 32-bit code (verified: known-good kernels have zero 64-bit instrs).
sed -i 's/if (cpu_has_64bit_gp_regs || cpu_has_64bit_zero_reg)/if (0)/' arch/mips/mm/page.c
sed -i 's/if (cpu_has_64bit_gp_regs)/if (0)/' arch/mips/mm/page.c

# Also disable the 64-bit pg_addiu path (daddu) — use 32-bit addiu only
sed -i 's/if (cpu_has_64bit_gp_regs && DADDI_WAR && r4k_daddiu_bug())/if (0)/' arch/mips/mm/page.c

# Replace dynamically generated clear_page with a simple C function.
# The dynamic code generation writes to __clear_page_start which may
# interact badly with the emulator. The C version is safer.
cat >> arch/mips/mm/page.c <<'CLEAR_PAGE_PATCH'

/* BE300: Simple C clear_page replacement */
void clear_page_simple(void *page)
{
	unsigned int *p = (unsigned int *)page;
	unsigned int *end = (unsigned int *)((char *)page + PAGE_SIZE);
	while (p < end) {
		*p++ = 0; *p++ = 0; *p++ = 0; *p++ = 0;
	}
}
CLEAR_PAGE_PATCH

# Patch build_clear_page ONLY (not build_copy_page!) to install a jump to
# the C clear_page_simple. Using sed range to limit to build_clear_page.
# BUG FIX 2026-04-11: Previously the sed pattern was applied to BOTH
# build_clear_page AND build_copy_page (because memset(labels,...) appears
# in both), causing copy_page to zero destination pages instead of copying.
# This broke COW for MAP_PRIVATE file mappings — data segment pages read
# as zeros in userspace because the COW copy zeroed the new page.
sed -i '/^void build_clear_page/,/^void build_copy_page/{
  /memset(labels, 0, sizeof(labels));/i\
\t/* BE300: use C clear_page instead of dynamic code */\n\t{\n\t\textern void clear_page_simple(void *);\n\t\tunsigned long fn = (unsigned long)clear_page_simple;\n\t\tbuf[0] = 0x08000000 | ((fn >> 2) \& 0x03ffffff);\n\t\tbuf[1] = 0x00000000;\n\t\treturn;\n\t}
}' arch/mips/mm/page.c

# NOTE: copy_page left as dynamically generated (C replacement broke test2 on real HW)

# Disable VDSO — uses vmap (KSEG2/TLB-mapped)
sed -i '/^int arch_setup_additional_pages/,/^}/c\
int arch_setup_additional_pages(struct linux_binprm *bprm, int uses_interp)\n{\n\treturn 0;\n}' arch/mips/kernel/vdso.c

# Add NOPs after tlbwr for VR4131 (hazard between tlbwr and eret)
sed -i '/case CPU_VR4131:/,/break;/{
  s/tlbw(p);/tlbw(p);\n\t\tuasm_i_nop(p);\n\t\tuasm_i_nop(p);/
}' arch/mips/mm/tlbex.c

# VR4131 cache bug fix: split Hit_Writeback_Inv_D into separate
# Hit_Writeback_D + Hit_Invalidate_D. Required for real VR4131 silicon
# (combined op has a hardware bug). Also works on the emulator.
sed -i '/^static inline void flush_dcache_line/,/^}/ {
  s/cache_op(Hit_Writeback_Inv_D, addr);/cache_op(Hit_Writeback_D, addr);\n\tcache_op(Hit_Invalidate_D, addr);/
}' arch/mips/include/asm/r4kcache.h

sed -i '/^static inline void protected_writeback_dcache_line/,/^}/ {
  s/protected_cachee_op(Hit_Writeback_Inv_D, addr);/protected_cachee_op(Hit_Writeback_D, addr);\n\tprotected_cachee_op(Hit_Invalidate_D, addr);/
  s/protected_cache_op(Hit_Writeback_Inv_D, addr);/protected_cache_op(Hit_Writeback_D, addr);\n\tprotected_cache_op(Hit_Invalidate_D, addr);/
}' arch/mips/include/asm/r4kcache.h

# NOTE: EntryLo1 workaround for emulator removed - testing on real HW first

# NOTE: __update_cache left as stock behavior (exec || pages_do_alias).
# An earlier attempt at unconditional `if (1)` per-page D-cache flush
# was not what fixed the data-page-zeros bug — that turned out to be
# the build_copy_page / clear_page_simple sed mishap (COW zeroing the
# destination). Per-page flush here is also known to break real HW
# (the kernel hangs at "Calibrating delay loop..." / timer-interrupt
# path, see CLAUDE.md and git history).

# FIX: Force _PAGE_VALID in set_pte for VR41xx.
# The lazy-VALID mechanism relies on TLB Invalid exceptions (handle_tlbl)
# to set VALID on first access. The BE-300 emulator doesn't properly
# generate TLB Invalid exceptions, so the TLB refill handler always loads
# PTEs with Valid=0, causing infinite faults. Fix: set _PAGE_VALID in
# the PTE whenever _PAGE_PRESENT is set, so the TLB refill handler always
# installs valid TLB entries. This disables ACCESSED-bit tracking but
# that's acceptable for this platform.
sed -i '0,/\*ptep = pteval;/{s/\*ptep = pteval;/if (pte_val(pteval) \& _PAGE_PRESENT) pte_val(pteval) |= _PAGE_VALID | _PAGE_ACCESSED;\n\t\*ptep = pteval;/}' arch/mips/include/asm/pgtable.h
# Apply to the second set_pte as well (32-bit path)
sed -i '0,/\*ptep = pteval;/{s/\*ptep = pteval;/if (pte_val(pteval) \& _PAGE_PRESENT) pte_val(pteval) |= _PAGE_VALID | _PAGE_ACCESSED;\n\t\*ptep = pteval;/}' arch/mips/include/asm/pgtable.h

# FIX: vr41xx/common/irq.c::irq_dispatch unconditionally calls
# chip->irq_ack() on the cascade path. The SYSINT1 / SYSINT2 chips defined
# right next door (icu.c) only provide irq_mask/irq_unmask — they have no
# irq_ack — so this NULL-derefs the moment a *cascaded* SYSINT1 IRQ fires
# (notably SYSINT1_IRQ(8), the GIU summary). Make the call conditional.
sed -i 's|^\t\t\tchip->irq_ack(idata);$|\t\t\tif (chip->irq_ack) chip->irq_ack(idata);|' \
    arch/mips/vr41xx/common/irq.c

# FIX: gpio-vr41xx.c giu_probe has an inverted error check around
# gpiochip_add() — the `if (!ret)` branch tears down and returns -ENODEV
# when the call SUCCEEDED. The intent was clearly `if (ret)`. Without
# this fix, the GIU IRQ chips never get installed, and any chained
# handler attached to GIU_IRQ(0) sees no_irq_chip and warns.
sed -i 's|ret = gpiochip_add(&vr41xx_gpio_chip);\n\tif (!ret) {|ret = gpiochip_add(\&vr41xx_gpio_chip);\n\tif (ret) {|' \
    drivers/gpio/gpio-vr41xx.c
# sed doesn't handle multiline easily; do it as two sequential pattern matches:
sed -i '/ret = gpiochip_add(&vr41xx_gpio_chip);/{n;s|^\tif (!ret) {|\tif (ret) {|}' \
    drivers/gpio/gpio-vr41xx.c

# FIX: Adjust VR41xx pfn_pte/pte_pfn shift in pgtable-32.h.
# The VR41xx EntryLo has PFN starting at bit 8 (not bit 6 like standard
# R4000), matching its 1KB-granularity TLB. In 2.4 Linux, _PAGE_GLOBAL
# was at bit 6, and pfn_pte at PAGE_SHIFT+2=14 produced correct EntryLo:
#   PFN at PTE bit 14, SRL by 6 → PFN at EntryLo bit 8 ✓
# In 4.2.9, _PAGE_GLOBAL moved to bit 5 (no _PAGE_FILE between MODIFIED
# and GLOBAL), so SRL is now by 5. With PFN still at bit 14:
#   PFN at PTE bit 14, SRL by 5 → PFN at EntryLo bit 9 ✗ (1 bit too high)
# Fix: change PAGE_SHIFT+2 to PAGE_SHIFT+1 (bit 13), so after SRL by 5:
#   PFN at PTE bit 13, SRL by 5 → PFN at EntryLo bit 8 ✓
sed -i 's/PAGE_SHIFT + 2/PAGE_SHIFT + 1/g' arch/mips/include/asm/pgtable-32.h

# Patch Platform: add build rules
if ! grep -q "CASIO_BE300" arch/mips/vr41xx/Platform; then
    cat >> arch/mips/vr41xx/Platform <<'PLATFORM'

#
# CASIO CASSIOPEIA BE-300 (VR4131)
#
platform-$(CONFIG_CASIO_BE300)	+= vr41xx/casio-be300/
# Load above the BE-300 boot ROM's RAM scratch zone. The ROM's MIPS16
# record walker keeps state in 0x80010000-0x80010300 and reads from the
# stack at 0x80003800. Loading the kernel at 0x80020000 (PA 0x20000,
# 128 KiB into SDRAM) leaves both regions untouched while the walker is
# copying records into RAM, so the walker can finish and write the
# 0x24FC mailbox correctly.
load-$(CONFIG_CASIO_BE300)	+= 0xffffffff80020000
PLATFORM
fi

# Suppress the legacy ISA NE2000 autoprobe path in drivers/net/Space.c.
# Space.c::net_olddevs_init -> ethif_probe2 -> ne_probe(unit) iterates units
# 0..7 and registers MAX_NE_CARDS=4 dummy ne.0..ne.3 platform devices with
# no IRQ resource. ne_drv_probe then runs probe_irq_on/probe_irq_off against
# each dummy, which on the BE-300 emulator briefly sets the NE2000 IMR=0x50
# and triggers a remote-DMA read (RREAD). The 10ms mdelay during this probe
# is what causes the storm: cf_giu_source_bits keeps GIRQ0 bit 0 high while
# (isr & imr) != 0, the cascade fires, and our chained handler in
# board/casio-be300/irq.c isn't installed until late_initcall. Killing the
# legacy entry leaves our own platform_device (id=-1, with IORESOURCE_IRQ)
# as the only path into ne_drv_probe — single-shot at 0x300, no autoprobe.
sed -i 's@^\(\s*\){ne_probe, 0},@\1/* {ne_probe, 0}, removed for BE-300 */@' \
    drivers/net/Space.c

###############################################################################
# Phase 5: Configure kernel
###############################################################################

echo "=== Phase 5: Configuring kernel ==="

# Copy defconfig
cp /work/configs/be300_defconfig arch/mips/configs/be300_defconfig

# Generate .config
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- be300_defconfig

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
ROOTFS_JFFS2="/work/linux-4.2.9/rootfs.jffs2"
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
    --out /work/linux-4.2.9/be300.nand

ls -l /work/linux-4.2.9/be300.nand
echo ""
echo "Test with:"
echo "  ./bin/be300 --nand linux-4.2.9/be300.nand"
echo "  ./bin/be300 --nand linux-4.2.9/be300.nand --cf cf.img"
echo "  ./bin/be300 --nand linux-4.2.9/be300.nand --ne2000 --net-mac 02:de:ad:be:ef:01"
