#!/bin/bash
set -e

KERNEL_SOURCE_URL="http://distro.ibiblio.org/tinycorelinux/7.x/x86/release/src/kernel/linux-4.2.9-patched.tar.xz"
BUSYBOX_VERSION="1.24.2"

###############################################################################
# Phase 1: Build BusyBox and create initramfs directory
###############################################################################

echo "=== Phase 1: Building BusyBox and initramfs ==="

# Build BusyBox for MIPS III (VR4131 ISA).
# The default mipsel-linux-gnu- toolchain targets MIPS32r2 which has
# instructions (ext, ins, seb, seh) not available on the VR4131.
# We rebuild with -march=mips3 -mabi=32 to match the VR4131's ISA.
if [ ! -d "busybox-${BUSYBOX_VERSION}/_install_be300/bin" ]; then
    echo "--- Building BusyBox for VR4131 (MIPS III) ---"
    ./build_busybox.sh

    # Rebuild with correct ISA — save .config, do mrproper, restore
    cd "busybox-${BUSYBOX_VERSION}"
    cp .config .config.saved
    make mrproper
    cp .config.saved .config
    # Use -march=mips32 (Release 1, no r2 extensions like ext/ins/seb/seh)
    # to avoid MIPS32r2 instructions that the VR4131 doesn't support.
    # Can't use -march=mips3 because the toolchain libc is built for mips32r2.
    sed -i 's|^CONFIG_EXTRA_CFLAGS=.*|CONFIG_EXTRA_CFLAGS="-march=mips32"|' .config
    sed -i 's|^CONFIG_EXTRA_LDFLAGS=.*|CONFIG_EXTRA_LDFLAGS="-march=mips32"|' .config
    yes "" | make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- oldconfig
    make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- -j$(nproc)
    make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- CONFIG_PREFIX=_install_be300 install
    cd /work
fi
BB_INSTALL="$(pwd)/busybox-${BUSYBOX_VERSION}/_install_be300"

# Create initramfs directory structure
ROOTFS="$(pwd)/rootfs_be300"
# BB_INSTALL is set after BusyBox build above

echo "--- Creating initramfs directory ---"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
cd "$ROOTFS"
mkdir -p bin sbin etc proc sys dev usr/bin usr/sbin root tmp var lib

echo "--- Copying BusyBox files ---"
cp -a "$BB_INSTALL"/* .

# Ensure /bin/sh exists (BusyBox symlink)
if [ ! -e bin/sh ]; then
    ln -s busybox bin/sh
fi

echo "--- Creating /etc/fstab ---"
cat > etc/fstab <<'FSTAB'
proc            /proc        proc    defaults          0       0
sysfs           /sys         sysfs   defaults          0       0
devtmpfs        /dev         devtmpfs  defaults        0       0
FSTAB

echo "--- Creating /init (pure MIPS-I assembly, no libc) ---"
mipsel-linux-gnu-gcc -nostdlib -static -march=mips1 -mfp32 -mabi=32 \
    -mno-abicalls -fno-pic \
    -o init /work/board/casio-be300/test_init.S
chmod +x init

cd /work

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
' arch/mips/vr41xx/Kconfig
fi

# Add BE300 memory region in prom_init (common/init.c doesn't add memory,
# and mem= on command line seems to cause the kernel to allocate pages
# beyond physical RAM). Add explicit add_memory_region call.
# Register memory in prom_init. Register 16MB to match BE300 hardware.
# The "OOB writes" previously observed were actually caused by the VR41xx
# PFN mismatch (PTE physical addresses 8x too high, pointing beyond RAM).
# With the pfn_pte fix, all mappings stay within the 16MB physical range.
sed -i '/^void __init prom_init(void)$/,/^}$/{
  /^}$/i\
\tadd_memory_region(0, 16 << 20, BOOT_MEM_RAM);
}' arch/mips/vr41xx/common/init.c

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

# Patch build_clear_page to install a jump to the C version
sed -i '/memset(labels, 0, sizeof(labels));/i\
\t/* BE300: use C clear_page instead of dynamic code */\n\t{\n\t\textern void clear_page_simple(void *);\n\t\tunsigned long fn = (unsigned long)clear_page_simple;\n\t\tbuf[0] = 0x08000000 | ((fn >> 2) \& 0x03ffffff);\n\t\tbuf[1] = 0x00000000;\n\t\treturn;\n\t}' arch/mips/mm/page.c

# Disable VDSO — uses vmap (KSEG2/TLB-mapped)
sed -i '/^int arch_setup_additional_pages/,/^}/c\
int arch_setup_additional_pages(struct linux_binprm *bprm, int uses_interp)\n{\n\treturn 0;\n}' arch/mips/kernel/vdso.c

# Add NOPs after tlbwr for VR4131 (hazard between tlbwr and eret)
sed -i '/case CPU_VR4131:/,/break;/{
  s/tlbw(p);/tlbw(p);\n\t\tuasm_i_nop(p);\n\t\tuasm_i_nop(p);/
}' arch/mips/mm/tlbex.c

# VR4131 cache bug fix: DISABLED for emulator testing.
# The real VR4131 needs Hit_Writeback_Inv_D split into separate ops,
# but the emulator may only implement the combined op. The 2.4/2.6
# kernels use the combined op and work on the emulator.
# This fix should be RE-ENABLED for real hardware.

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
