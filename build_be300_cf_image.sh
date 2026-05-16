#!/bin/bash
set -euo pipefail

# Build a CompactFlash image that uses the stock BE-300 recovery path as a
# Linux bootstrap instead of as a NAND flasher. The CF card has an MBR, FAT16
# recovery/boot partition 1, and ext2 Linux root partition 2.

WORK=${WORK:-/work}
KERNEL_DIR=${KERNEL_DIR:-"$WORK/linux-4.2.9"}
VMLINUX=${VMLINUX:-"$KERNEL_DIR/vmlinux"}
OUT=${OUT:-"$KERNEL_DIR/linux_cf.img"}
BUILD_DIR=${BUILD_DIR:-"$KERNEL_DIR/cf_linux_build"}
PATCH_SERIES=${PATCH_SERIES:-"$WORK/patches/linux-4.2.9/be300/series"}
DEFCONFIG=${DEFCONFIG:-"$WORK/configs/be300_defconfig"}
CF_CONFIG=${CF_CONFIG:-"$WORK/configs/be300_cf.config"}
SIZE_MIB=${SIZE_MIB:-64}
FAT_SIZE_MIB=${FAT_SIZE_MIB:-16}
ROOTFS_SIZE_MIB=${ROOTFS_SIZE_MIB:-40}
ROOTFS_SRC=${ROOTFS_SRC:-"$WORK/rootfs_be300"}
CF_ROOT=${CF_ROOT:-"$BUILD_DIR/rootfs_cf"}
ROOTFS_EXT2=${ROOTFS_EXT2:-"$BUILD_DIR/rootfs.ext2"}
CF_INIT=${CF_INIT:-"$BUILD_DIR/cf-init"}
REBUILD_KERNEL=${REBUILD_KERNEL:-1}
SKIP_ISA_CHECK=${SKIP_ISA_CHECK:-0}

CC=${CC:-mipsel-linux-gnu-gcc}
LD=${LD:-mipsel-linux-gnu-ld}

if [ ! -d "$KERNEL_DIR" ]; then
	echo "ERROR: $KERNEL_DIR not found; run build_be300_kernel.sh first" >&2
	exit 1
fi

ensure_kernel_patched() {
	if grep -q "CASIO_BE300" "$KERNEL_DIR/arch/mips/vr41xx/Kconfig" 2>/dev/null; then
		if [ -f "$DEFCONFIG" ]; then
			cp "$DEFCONFIG" "$KERNEL_DIR/arch/mips/configs/be300_defconfig"
		fi
		cp "$WORK/board/casio-be300/setup.c" \
			"$KERNEL_DIR/arch/mips/vr41xx/casio-be300/setup.c"
		return
	fi
	"$WORK/scripts/apply_patch_series.sh" "$PATCH_SERIES" "$KERNEL_DIR"
	if [ -f "$DEFCONFIG" ]; then
		cp "$DEFCONFIG" "$KERNEL_DIR/arch/mips/configs/be300_defconfig"
	fi
	cp "$WORK/board/casio-be300/setup.c" \
		"$KERNEL_DIR/arch/mips/vr41xx/casio-be300/setup.c"
}

prepare_cf_rootfs() {
	if [ ! -d "$ROOTFS_SRC" ]; then
		echo "ERROR: $ROOTFS_SRC not found; run build_be300_kernel.sh first" >&2
		exit 1
	fi
	if [ ! -x "$ROOTFS_SRC/bin/busybox" ]; then
		echo "ERROR: $ROOTFS_SRC/bin/busybox missing; run build_be300_kernel.sh first" >&2
		exit 1
	fi
	if [ ! -x "$ROOTFS_SRC/bin/demo-hello" ]; then
		echo "ERROR: $ROOTFS_SRC/bin/demo-hello missing; run build_be300_kernel.sh first" >&2
		exit 1
	fi

	rm -rf "$CF_ROOT"
	mkdir -p "$CF_ROOT"
	cp -a "$ROOTFS_SRC/." "$CF_ROOT/"

	mkdir -p "$CF_ROOT"/{dev,etc,proc,sys,tmp,bin,sbin}
	chmod 1777 "$CF_ROOT/tmp"
	if [ ! -e "$CF_ROOT/sbin/init" ] && [ ! -L "$CF_ROOT/sbin/init" ]; then
		ln -s /bin/busybox "$CF_ROOT/sbin/init"
	fi

	cat >"$CF_ROOT/etc/inittab" <<'EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/echo "=== Casio BE-300 CF Linux 4.2.9 (BusyBox + Nano-X) ===" >/dev/console
::sysinit:/bin/echo "  rootfs: /dev/sda2 ext2" >/dev/console
::sysinit:/bin/echo "  Run /bin/start-microwindows for the Nano-X demo." >/dev/console
::respawn:/bin/sh -i </dev/console >/dev/console 2>&1
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
EOF

	cat >"$CF_ROOT/bin/start-microwindows" <<'EOF'
#!/bin/sh
export MWFONTDIR=/usr/share/microwindows/pcf
exec /bin/demo-hello "$@"
EOF
	chmod +x "$CF_ROOT/bin/start-microwindows"
}

build_cf_init() {
	$CC -march=mips2 -mabi=32 -mno-abicalls -fno-pic -nostdlib -static \
		-Wl,-e,_start \
		-o "$CF_INIT" \
		"$WORK/board/casio-be300/cf_init.S"
	mipsel-linux-gnu-strip "$CF_INIT"
	cp "$CF_INIT" "$CF_ROOT/sbin/cf-init"
	chmod +x "$CF_ROOT/sbin/cf-init"
}

check_rootfs_isa() {
	local bin bad rel failed

	if [ "$SKIP_ISA_CHECK" = 1 ]; then
		return
	fi
	if ! command -v mipsel-linux-gnu-objdump >/dev/null 2>&1; then
		return
	fi

	failed=0
	for bin in "$CF_ROOT/bin/busybox" "$CF_ROOT/bin/demo-hello" "$CF_ROOT/sbin/cf-init"; do
		[ -f "$bin" ] || continue
		bad=$(mipsel-linux-gnu-objdump -d "$bin" | awk '$3 ~ /^(mul|clz|clo|ext|ins|seb|seh|wsbh|rdhwr)$/ {print; exit}' || true)
		if [ -n "$bad" ]; then
			rel=${bin#"$CF_ROOT"/}
			echo "ERROR: $rel contains an unsupported MIPS32 instruction:" >&2
			echo "  $bad" >&2
			failed=1
		fi
	done
	if [ "$failed" != 0 ]; then
		echo "Rebuild the rootfs with build_be300_kernel.sh before packing the CF image." >&2
		exit 1
	fi
}

make_rootfs_ext2() {
	local rootfs_kib min_rootfs_mib

	if ! command -v mkfs.ext2 >/dev/null 2>&1; then
		echo "ERROR: mkfs.ext2 not found; rebuild the Docker image with e2fsprogs" >&2
		exit 1
	fi

	rootfs_kib=$(du -sk "$CF_ROOT" | awk '{print $1}')
	min_rootfs_mib=$(( (rootfs_kib * 13 / 10 + 1023) / 1024 + 4 ))
	if [ "$ROOTFS_SIZE_MIB" -lt "$min_rootfs_mib" ]; then
		echo "ERROR: ROOTFS_SIZE_MIB=$ROOTFS_SIZE_MIB is too small; need at least $min_rootfs_mib MiB" >&2
		exit 1
	fi

	rm -f "$ROOTFS_EXT2"
	dd if=/dev/zero of="$ROOTFS_EXT2" bs=1M count="$ROOTFS_SIZE_MIB" status=none
	mkfs.ext2 -q -F -E no_copy_xattrs -L BE300ROOT -d "$CF_ROOT" "$ROOTFS_EXT2"
}

if [ "$REBUILD_KERNEL" = 1 ]; then
	mkdir -p "$BUILD_DIR"

	cd "$KERNEL_DIR"
	ensure_kernel_patched
	if [ ! -f .config ]; then
		make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- be300_defconfig
	fi
	if [ ! -f "$CF_CONFIG" ]; then
		echo "ERROR: CF config fragment not found: $CF_CONFIG" >&2
		exit 1
	fi
	./scripts/kconfig/merge_config.sh -m .config "$CF_CONFIG"
	make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- olddefconfig
	make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- vmlinux -j"$(nproc)"
	cd "$WORK"
fi

if [ ! -f "$VMLINUX" ]; then
	echo "ERROR: $VMLINUX not found" >&2
	exit 1
fi

mkdir -p "$BUILD_DIR"
echo "=== Preparing CF ext2 rootfs ==="
prepare_cf_rootfs
build_cf_init
check_rootfs_isa
make_rootfs_ext2

eval "$(
python3 - "$VMLINUX" <<'PYEOF'
import struct
import sys

data = open(sys.argv[1], "rb").read()
e_entry = struct.unpack_from("<I", data, 24)[0]
e_phoff = struct.unpack_from("<I", data, 28)[0]
e_phnum = struct.unpack_from("<H", data, 44)[0]
loads = []
for i in range(e_phnum):
    off = e_phoff + i * 32
    p_type, p_offset, p_vaddr, p_paddr, p_filesz, *_ = struct.unpack_from("<IIIIIIII", data, off)
    if p_type == 1 and p_filesz:
        loads.append((p_vaddr, p_filesz))
base = min(addr for addr, _ in loads)
end = max(addr + size for addr, size in loads)
print(f"KERNEL_LOAD_VA=0x{base:08X}")
print(f"KERNEL_ENTRY_VA=0x{e_entry:08X}")
print(f"KERNEL_SIZE=0x{end - base:X}")
PYEOF
)"

echo "=== Building CF Linux bootstrap ==="
echo "  KERNEL_LOAD_VA=$KERNEL_LOAD_VA"
echo "  KERNEL_ENTRY_VA=$KERNEL_ENTRY_VA"
echo "  KERNEL_SIZE=$KERNEL_SIZE"
echo "  ROOTFS_EXT2=$ROOTFS_EXT2"

CF_CFLAGS="-march=mips2 -mabi=32 -mno-abicalls -fno-pic -mno-mips16 \
	-nostdlib -fno-builtin -ffreestanding -Os -g -fno-stack-protector \
	-DKERNEL_LOAD_VA=${KERNEL_LOAD_VA}u \
	-DKERNEL_ENTRY_VA=${KERNEL_ENTRY_VA}u \
	-DKERNEL_SIZE=${KERNEL_SIZE}u"

$CC $CF_CFLAGS -c -o "$BUILD_DIR/cf_linux_start.o" \
	"$WORK/board/casio-be300/cf_linux_start.S"
$CC $CF_CFLAGS -c -o "$BUILD_DIR/cf_linux_loader.o" \
	"$WORK/board/casio-be300/cf_linux_loader.c"
$LD -m elf32ltsmip -T "$WORK/board/casio-be300/cf_linux_loader.lds" \
	-o "$BUILD_DIR/cf_linux_loader.elf" \
	"$BUILD_DIR/cf_linux_start.o" "$BUILD_DIR/cf_linux_loader.o"

echo "=== Packing CF image ==="
python3 "$WORK/tools/mk_be300_cf_linux.py" \
	--loader "$BUILD_DIR/cf_linux_loader.elf" \
	--vmlinux "$VMLINUX" \
	--output "$OUT" \
	--size-mib "$SIZE_MIB" \
	--fat-size-mib "$FAT_SIZE_MIB" \
	--rootfs-ext2 "$ROOTFS_EXT2" \
	--force

echo ""
echo "Test with:"
echo "  ./bin/be300 --restore --cf linux-4.2.9/linux_cf.img --speed 0"
