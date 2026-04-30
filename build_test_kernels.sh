#!/bin/bash
set -e

# Build 3 test kernels to compare single-page vs multi-page behavior.
# All use the same kernel patches; only /init differs.

KERNEL_SOURCE_URL="http://distro.ibiblio.org/tinycorelinux/7.x/x86/release/src/kernel/linux-4.2.9-patched.tar.xz"

###############################################################################
# Common init assembly fragments
###############################################################################

# Shared prologue: write, mount, pause syscall numbers
INIT_HEADER='
	.set noreorder
	.text
	.globl __start
	.type __start, @function

#define __NR_write  4004
#define __NR_mount  4021
#define __NR_pause  4029
#define __NR_mkdir  4039
'

# Test 1: Single-page OMAGIC - all text+data on one page
cat > /tmp/test1_init.S << ENDASM
${INIT_HEADER}
__start:
	li	\$v0, __NR_write
	li	\$a0, 1
	la	\$a1, msg
	li	\$a2, msg_len
	syscall
	nop

	/* mount proc */
	li	\$v0, __NR_mkdir
	la	\$a0, s_proc
	li	\$a1, 0755
	syscall
	nop
	li	\$v0, __NR_mount
	la	\$a0, s_proc
	la	\$a1, s_proc
	la	\$a2, s_procfs
	li	\$a3, 0
	addiu	\$sp, \$sp, -16
	sw	\$zero, 16(\$sp)
	syscall
	nop
	addiu	\$sp, \$sp, 16

	/* write cpuinfo header */
	li	\$v0, __NR_write
	li	\$a0, 1
	la	\$a1, msg2
	li	\$a2, msg2_len
	syscall
	nop

1:	li	\$v0, __NR_pause
	syscall
	nop
	b	1b
	nop

	.data
msg:	.ascii "\nTest1: OMAGIC single-page init ALIVE\n"
msg_len = . - msg
msg2:	.ascii "Data section readable!\n"
msg2_len = . - msg2
s_proc:		.asciz "/proc"
s_procfs:	.asciz "proc"
ENDASM

# Test 2: Normal linking - .data on separate page from .text
# Add enough text padding to push .data to a different page
cat > /tmp/test2_init.S << ENDASM
${INIT_HEADER}
__start:
	li	\$v0, __NR_write
	li	\$a0, 1
	la	\$a1, msg
	li	\$a2, msg_len
	syscall
	nop

	/* mount proc */
	li	\$v0, __NR_mkdir
	la	\$a0, s_proc
	li	\$a1, 0755
	syscall
	nop
	li	\$v0, __NR_mount
	la	\$a0, s_proc
	la	\$a1, s_proc
	la	\$a2, s_procfs
	li	\$a3, 0
	addiu	\$sp, \$sp, -16
	sw	\$zero, 16(\$sp)
	syscall
	nop
	addiu	\$sp, \$sp, 16

	/* write to confirm data section readable */
	li	\$v0, __NR_write
	li	\$a0, 1
	la	\$a1, msg2
	li	\$a2, msg2_len
	syscall
	nop

1:	li	\$v0, __NR_pause
	syscall
	nop
	b	1b
	nop

	.data
msg:	.ascii "\nTest2: Normal link multi-page init ALIVE\n"
msg_len = . - msg
msg2:	.ascii "Data section readable!\n"
msg2_len = . - msg2
s_proc:		.asciz "/proc"
s_procfs:	.asciz "proc"
ENDASM

# Test 3: uClibc C program (has GOT, separate data segment)
cat > /tmp/test3_init.c << 'ENDC'
#include <unistd.h>
#include <sys/mount.h>
int main(void) {
    write(1, "\nTest3: uClibc C program ALIVE\n", 31);
    mkdir("/proc", 0755);
    mount("proc", "/proc", "proc", 0, NULL);
    write(1, "GOT and libc working!\n", 22);
    while (1) pause();
    return 0;
}
ENDC

###############################################################################
# Build function - builds kernel with a given /init
###############################################################################
build_kernel() {
    local INIT_BIN="$1"
    local OUTPUT="$2"

    echo "========================================="
    echo "Building: ${OUTPUT}"
    echo "========================================="

    ROOTFS="/work/rootfs_be300"
    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"
    cd "$ROOTFS"
    mkdir -p proc sys dev mnt

    cp "$INIT_BIN" init
    chmod +x init

    cd /work

    # Skip kernel download/extract/patch if already done
    if [ ! -f linux-4.2.9/vmlinux ] && [ ! -f linux-4.2.9/.config ]; then
        # Full build needed
        /work/build_be300_kernel.sh
    else
        # Just rebuild with new initramfs
        cd linux-4.2.9

        INITRAMFS_LIST="${ROOTFS}/../initramfs_list.txt"
        cat > "$INITRAMFS_LIST" <<CPIO_LIST
dir /dev 0755 0 0
nod /dev/console 0622 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/zero 0666 0 0 c 1 5
nod /dev/tty 0666 0 0 c 5 0
nod /dev/tty0 0666 0 0 c 4 0
nod /dev/tty1 0666 0 0 c 4 1
CPIO_LIST

        sed -i '/CONFIG_INITRAMFS_SOURCE/d' .config
        echo "CONFIG_INITRAMFS_SOURCE=\"${ROOTFS} ${INITRAMFS_LIST}\"" >> .config

        # Rebuild (initramfs change forces re-link)
        make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- vmlinux -j1
        cd /work
    fi

    cp linux-4.2.9/vmlinux "/work/${OUTPUT}"
    echo "=== Saved: ${OUTPUT} ==="
    ls -l "/work/${OUTPUT}"
}

###############################################################################
# First do a full build to get the patched kernel tree
###############################################################################
echo "=== Full kernel build (establishes patched tree) ==="
rm -rf /work/rootfs_be300
mkdir -p /work/rootfs_be300/{proc,sys,dev,mnt}

# Build test1 init (OMAGIC)
mipsel-linux-gnu-gcc -nostdlib -static -march=mips1 -mfp32 -mabi=32 \
    -mno-abicalls -fno-pic -Wl,-N \
    -o /work/rootfs_be300/init /tmp/test1_init.S
chmod +x /work/rootfs_be300/init

cd /work
./build_be300_kernel.sh
cp linux-4.2.9/vmlinux /work/vmlinux-test1-omagic
echo "=== Saved: vmlinux-test1-omagic ==="

###############################################################################
# Test 2: Normal linking (multi-page)
###############################################################################
mipsel-linux-gnu-gcc -nostdlib -static -march=mips1 -mfp32 -mabi=32 \
    -mno-abicalls -fno-pic \
    -o /tmp/test2_init /tmp/test2_init.S

build_kernel /tmp/test2_init vmlinux-test2-multipage

###############################################################################
# Ensure uClibc sysroot is installed (ephemeral in Docker container)
###############################################################################
UCLIBC_PREFIX="/work/uclibc-mipsel"
UCLIBC_SRC="${UCLIBC_PREFIX}/usr/mips-linux-uclibc/usr"
SYSLIB="/usr/mipsel-linux-gnu/lib"
SYSINC="/usr/mipsel-linux-gnu/include"

if [ ! -f "${SYSLIB}/libc.a.glibc-backup" ]; then
    echo "--- Installing uClibc-ng into system sysroot ---"
    cp "${SYSLIB}/libc.a" "${SYSLIB}/libc.a.glibc-backup"
    cp -f "${UCLIBC_SRC}/lib/crt1.o" "${SYSLIB}/"
    cp -f "${UCLIBC_SRC}/lib/crti.o" "${SYSLIB}/"
    cp -f "${UCLIBC_SRC}/lib/crtn.o" "${SYSLIB}/"
    cp -f "${UCLIBC_SRC}/lib/libc.a" "${SYSLIB}/"
    cp -f "${UCLIBC_SRC}/lib/libm.a" "${SYSLIB}/" 2>/dev/null || true
    cp -f "${UCLIBC_SRC}/lib/libcrypt.a" "${SYSLIB}/" 2>/dev/null || true
    cp -f "${UCLIBC_SRC}/lib/libpthread.a" "${SYSLIB}/" 2>/dev/null || true
    rm -rf "${SYSINC}.glibc-backup"
    mv "${SYSINC}" "${SYSINC}.glibc-backup"
    cp -a "${UCLIBC_SRC}/include" "${SYSINC}"
    KERNEL_HEADERS="/work/uclibc-kernel-headers"
    cp -a "${KERNEL_HEADERS}/include/linux" "${SYSINC}/"
    cp -a "${KERNEL_HEADERS}/include/asm" "${SYSINC}/"
    cp -a "${KERNEL_HEADERS}/include/asm-generic" "${SYSINC}/"
fi

###############################################################################
# Test 3: uClibc C program (standard PIC/GOT)
###############################################################################
mipsel-linux-gnu-gcc -march=mips32 -fno-stack-protector -static \
    -o /tmp/test3_init /tmp/test3_init.c

# Verify it's actually uClibc
echo "test3 mips32r2 count: $(mipsel-linux-gnu-objdump -d /tmp/test3_init | grep -c -E '\b(ext|ins|seb|seh|wsbh|rdhwr)\b')"

build_kernel /tmp/test3_init vmlinux-test3-uclibc

###############################################################################
# Test 4: C program with custom _start, NO libc at all, multi-page .data
# This isolates whether the issue is uClibc or multi-page C binaries
###############################################################################
cat > /tmp/test4_init.S << 'ENDASM'
	.set noreorder
	.text
	.globl __start
	.type __start, @function

__start:
	/* write(1, msg, len) */
	li	$v0, 4004
	li	$a0, 1
	la	$a1, msg
	li	$a2, msg_len
	syscall
	nop

	/* Test reading from .data on a different page */
	la	$t0, testval
	lw	$t1, 0($t0)
	/* Write the value (should be 0xDEADBEEF) */
	/* Convert to hex string and write it */
	li	$v0, 4004
	li	$a0, 1
	la	$a1, msg2
	li	$a2, msg2_len
	syscall
	nop

	/* Check testval */
	la	$t0, testval
	lw	$t1, 0($t0)
	li	$t2, 0xDEADBEEF
	bne	$t1, $t2, bad
	nop

	/* Success */
	li	$v0, 4004
	li	$a0, 1
	la	$a1, msg_ok
	li	$a2, msg_ok_len
	syscall
	nop
	b	hang
	nop

bad:
	li	$v0, 4004
	li	$a0, 1
	la	$a1, msg_bad
	li	$a2, msg_bad_len
	syscall
	nop

hang:
1:	li	$v0, 4029
	syscall
	nop
	b	1b
	nop

	/* Pad .text to push .data to a different page */
	.space 4096

	.data
	.align 2
testval:	.word 0xDEADBEEF
msg:	.ascii "\nTest4: C (no libc) multi-page data test\n"
msg_len = . - msg
msg2:	.ascii "Reading .data from separate page... "
msg2_len = . - msg2
msg_ok:	.ascii "OK (0xDEADBEEF)\n"
msg_ok_len = . - msg_ok
msg_bad:	.ascii "FAIL (data corrupted!)\n"
msg_bad_len = . - msg_bad
ENDASM
mipsel-linux-gnu-gcc -nostdlib -static -march=mips1 -mfp32 -mabi=32 \
    -mno-abicalls -fno-pic \
    -o /tmp/test4_init /tmp/test4_init.S

build_kernel /tmp/test4_init vmlinux-test4-nolibc

echo ""
echo "=== All 4 test kernels built ==="
ls -l /work/vmlinux-test*
echo ""
echo "Test kernels are ELF vmlinux artifacts. To exercise them on the BE-300"
echo "emulator they must first be packed into a NAND image with the SPL"
echo "loader (see tools/mk_be300_nand.py)."
