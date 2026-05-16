#!/bin/bash
set -e

# Build a 4.2.9 kernel for BE-300 with the known-good 2.4-era ext2 ramdisk
# embedded as a traditional initrd.

KERNEL_SOURCE_URL="http://distro.ibiblio.org/tinycorelinux/7.x/x86/release/src/kernel/linux-4.2.9-patched.tar.xz"
RAMDISK="/work/ramdisk-pgui-full.gz"

if [ ! -f "$RAMDISK" ]; then
    echo "ERROR: $RAMDISK not found"
    exit 1
fi

echo "=== Preparing kernel source ==="

if [ ! -f linux-4.2.9-patched.tar.xz ]; then
    wget "$KERNEL_SOURCE_URL"
fi

if [ ! -d linux-4.2.9 ]; then
    tar xf linux-4.2.9-patched.tar.xz
fi

cd linux-4.2.9

# GCC 10+/11+ compatibility fixes
if [ -f scripts/dtc/dtc-lexer.lex.c_shipped ]; then
    sed -i 's/^YYLTYPE yylloc;/extern YYLTYPE yylloc;/' scripts/dtc/dtc-lexer.lex.c_shipped
fi
find . -name "log2.h" -exec sed -i \
    's/____ilog2_NaN(void) __attribute__((noreturn, const))/____ilog2_NaN(void) __attribute__((noreturn))/g' {} +
grep -rl "\-Werror" . | xargs sed -i 's/\-Werror\([[:space:]]\|$\)/ /g' || true
grep -rl "\-Werror" . | xargs sed -i 's/=\-Werror/=/g' || true

echo "=== Injecting BE300 board support ==="

mkdir -p arch/mips/vr41xx/casio-be300
cp /work/board/casio-be300/setup.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/sfb.c arch/mips/vr41xx/casio-be300/
cp /work/board/casio-be300/Makefile arch/mips/vr41xx/casio-be300/

# Register 16MB in prom_init
sed -i '/^void __init prom_init(void)$/,/^}$/{
  /^}$/i\
\tadd_memory_region(0, 16 << 20, BOOT_MEM_RAM);
}' arch/mips/vr41xx/common/init.c

# Force 32-bit stores (emulator is 32-bit only)
sed -i 's/if (cpu_has_64bit_gp_regs || cpu_has_64bit_zero_reg)/if (0)/' arch/mips/mm/page.c
sed -i 's/if (cpu_has_64bit_gp_regs)/if (0)/' arch/mips/mm/page.c
sed -i 's/if (cpu_has_64bit_gp_regs && DADDI_WAR && r4k_daddiu_bug())/if (0)/' arch/mips/mm/page.c

# VR4131 cache bug fix
sed -i '/^static inline void flush_dcache_line(unsigned long addr)$/,/^}$/{
  s/cache_op(Hit_Writeback_Inv_D, addr);/cache_op(Hit_Writeback_D, addr);\n\tcache_op(Hit_Invalidate_D, addr);/
}' arch/mips/include/asm/r4kcache.h
sed -i '/^static inline void protected_flush_dcache_line(unsigned long addr)$/,/^}$/{
  s/protected_cache_op(Hit_Writeback_Inv_D, addr);/protected_cache_op(Hit_Writeback_D, addr);\n\tprotected_cache_op(Hit_Invalidate_D, addr);/
}' arch/mips/include/asm/r4kcache.h

# Kconfig
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

if ! grep -q "CASIO_BE300" arch/mips/vr41xx/Platform; then
    cat >> arch/mips/vr41xx/Platform <<'PLATFORM'

#
# CASIO CASSIOPEIA BE-300 (VR4131)
#
platform-$(CONFIG_CASIO_BE300)	+= vr41xx/casio-be300/
load-$(CONFIG_CASIO_BE300)	+= 0xffffffff80004000
PLATFORM
fi

echo "=== Configuring kernel ==="

cp /work/configs/be300_defconfig arch/mips/configs/be300_defconfig

# Create a cpio-format initramfs containing the ext2 ramdisk as a file,
# plus a minimal /init script and device nodes.
# The /init will decompress and load the ramdisk into /dev/ram0.
INITRAMFS_LIST="/work/initramfs_ramdisk_list.txt"
cat > "$INITRAMFS_LIST" <<CPIO_LIST
dir /dev 0755 0 0
nod /dev/console 0622 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/ram0 0660 0 0 b 1 0
nod /dev/tty 0666 0 0 c 5 0
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /mnt 0755 0 0
file /ramdisk.gz ${RAMDISK} 0644 0 0
CPIO_LIST

# We also need a /init and /bin/sh — use BusyBox if available,
# otherwise create a minimal assembly /init
if [ -d /work/busybox-1.24.2/_install_be300/bin ]; then
    # Add busybox and symlinks from the install dir
    BB=/work/busybox-1.24.2/_install_be300
    cat >> "$INITRAMFS_LIST" <<BBLIST
dir /bin 0755 0 0
file /bin/busybox \${BB}/bin/busybox 0755 0 0
slink /bin/sh busybox 0777 0 0
slink /bin/mount busybox 0777 0 0
slink /bin/gunzip busybox 0777 0 0
slink /bin/cat busybox 0777 0 0
slink /bin/ls busybox 0777 0 0
slink /bin/echo busybox 0777 0 0
dir /sbin 0755 0 0
slink /sbin/switch_root ../bin/busybox 0777 0 0
BBLIST
    # Resolve the variable in the list file
    sed -i "s|\\\${BB}|${BB}|g" "$INITRAMFS_LIST"
fi

# Create /init script
INIT_SCRIPT="/work/ramdisk_init.sh"
cat > "$INIT_SCRIPT" <<'INITSCRIPT'
#!/bin/sh
mount -t proc proc /proc
mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "=== BE-300 Linux 4.2.9 ==="
echo "Loading ext2 ramdisk..."
gunzip -c /ramdisk.gz > /dev/ram0
mount -t ext2 /dev/ram0 /mnt
if [ -x /mnt/sbin/init ]; then
    exec switch_root /mnt /sbin/init
elif [ -x /mnt/bin/sh ]; then
    exec switch_root /mnt /bin/sh
else
    echo "Ramdisk mounted at /mnt"
    exec /bin/sh
fi
INITSCRIPT
chmod +x "$INIT_SCRIPT"
echo "file /init ${INIT_SCRIPT} 0755 0 0" >> "$INITRAMFS_LIST"

sed -i '/CONFIG_INITRAMFS_SOURCE/d' arch/mips/configs/be300_defconfig
echo "CONFIG_INITRAMFS_SOURCE=\"${INITRAMFS_LIST}\"" >> arch/mips/configs/be300_defconfig

make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- be300_defconfig
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- olddefconfig

echo "=== Building kernel ==="

make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- vmlinux -j1 || true

if [ -f vmlinux ]; then
    echo "=== SUCCESS: vmlinux created ==="
    ls -l vmlinux
    echo ""
    echo "Pack as a NAND image and test with:"
    echo "  python3 /work/tools/mk_be300_nand.py --vmlinux /work/linux-4.2.9/vmlinux --out /work/linux-4.2.9/be300.nand"
    echo "  ./bin/be300 --nand linux-4.2.9/be300.nand"
else
    echo "=== FAILURE: vmlinux NOT created ==="
    exit 1
fi
