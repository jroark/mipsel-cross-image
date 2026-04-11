#!/bin/bash
set -e

KERNEL_SOURCE_URL="http://distro.ibiblio.org/tinycorelinux/7.x/x86/release/src/kernel/linux-4.2.9-patched.tar.xz"
BUSYBOX_VERSION="1.24.2"

###############################################################################
# Phase 1: Build C test init with musl (tests data page mapping)
###############################################################################

echo "=== Phase 1: Building C test init ==="

ROOTFS="$(pwd)/rootfs_be300"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
cd "$ROOTFS"
mkdir -p proc sys dev

# Build minimal C init statically linked with musl.
# This tests whether data pages (separate from text) are readable
# from userspace — the key diagnostic for the data-page-zeros bug.
echo "--- Building C test init with musl ---"
# Build C test init with musl (normal linking, separate text+data segments).
# Tests whether ELF loader correctly maps the second LOAD segment.
mipsel-linux-gnu-gcc -static -march=mips32 -mabi=32 \
    -specs /work/musl-mipsel/lib/musl-gcc.specs \
    -o init /work/board/casio-be300/test_c_init.c
chmod +x init

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

# Copy board support files (setup.c, sfb.c framebuffer, Makefile)
mkdir -p arch/mips/vr41xx/casio-be300
cp /work/board/casio-be300/setup.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/sfb.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/keys.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/Makefile arch/mips/vr41xx/casio-be300/

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

# (Debug ELF loader prints removed — COW bug root cause identified and fixed)

# FIX: Always flush D-cache when Page_dcache_dirty is set in __update_cache.
# The stock kernel only flushes when pages_do_alias() returns true, but with
# a VIPT D-cache (VR4131: 16KB, 2-way), data written at the kernel VA (KSEG0)
# may be in cache at a different set index than the user VA. Without writeback,
# the user reads stale zeros from RAM instead of the kernel-written data.
# The pages_do_alias check only detects same-index conflicts, not the
# writeback-needed case where kernel and user VAs index different sets.
sed -i '/^void __update_cache/,/^}/ {
  s/if (exec || pages_do_alias(addr, address & PAGE_MASK))/if (1)/
}' arch/mips/mm/cache.c

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
load-$(CONFIG_CASIO_BE300)	+= 0xffffffff80004000
PLATFORM
fi

###############################################################################
# Phase 5: Configure kernel
###############################################################################

echo "=== Phase 5: Configuring kernel ==="

# Copy defconfig
cp /work/configs/be300_defconfig arch/mips/configs/be300_defconfig

# Create initramfs file list that includes the rootfs directory
# plus device nodes (avoids needing mknod privileges in Docker)
INITRAMFS_LIST="${ROOTFS}/../initramfs_list.txt"
cat > "$INITRAMFS_LIST" <<CPIO_LIST
# Include the rootfs directory
dir /dev 0755 0 0
nod /dev/console 0622 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/zero 0666 0 0 c 1 5
nod /dev/tty 0666 0 0 c 5 0
nod /dev/tty0 0666 0 0 c 4 0
nod /dev/tty1 0666 0 0 c 4 1
CPIO_LIST

# Set initramfs source: directory + device node list
sed -i '/CONFIG_INITRAMFS_SOURCE/d' arch/mips/configs/be300_defconfig
echo "CONFIG_INITRAMFS_SOURCE=\"${ROOTFS} ${INITRAMFS_LIST}\"" >> arch/mips/configs/be300_defconfig

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
    echo ""
    echo "Test with:"
    echo "  ./bin/be300 --kernel linux-4.2.9/vmlinux --cmdline \"mem=16M console=tty0 earlyprintk\""
else
    echo "=== FAILURE: vmlinux NOT created ==="
    exit 1
fi
