#!/bin/bash
# build_be300_2_4_kernel.sh
#
# Build a BE-300 NAND boot image for the Linux 2.4.18-mips kernel.
#
# Two modes, selected by BE300_2_4_MODE (default: rebuild):
#
#   BE300_2_4_MODE=prebuilt — Phase 1 path: wrap kernels/vmlinux-2.4 in the
#       existing SPL + B000FF container so it boots on bin/be300 --nand.
#       Useful for sanity-checking the SPL flow without a kernel rebuild.
#
#   BE300_2_4_MODE=rebuild  — Phase 2 path: extract
#       archives/linux4be-2.4.18-20021129.tar.gz into linux-2.4.18/, apply
#       the modern-toolchain patch series, populate the embedded ramdisk
#       from the prebuilt kernel's __rd_start..__rd_end (its initrd is
#       carried by the second PT_LOAD segment), build vmlinux with the
#       Debian mipsel-linux-gnu cross toolchain, then pack.
#
# Phase-2/2.5 status: the source rebuild produces a vmlinux that boots
# end-to-end through SPL → start_kernel → init/1 → do_basic_setup → all
# initcalls → ext2 root mount → "Algorithmics/MIPS FPU Emulator v1.5"
# → BusyBox `Welcome to Linux4BE / Please press Enter to activate this
# console.` on the framebuffer console (the earlier "black screen"
# observation was just the LCD inactivity blanker after ~60s).
#
# Phase-3 BE-300 hw driver progress (alongside Phase-2 modern-GCC
# patches in patches/linux-2.4.18-be300/0001-modern-toolchain-fixes.patch):
#   * Serial driver (SERIAL_BE300 + SERIAL_BE300_CONSOLE): enabled.
#     Prints `Casio Cassiopeia BE-300 Serial Driver version 0.01 / tty00
#     at 0xAA008680 (irq = 19) is a NEC D89041F1001 UART`. Needed a
#     `static`->extern fix on generic_serial.c's `gs_debug`.
#   * Buttons driver (BUTTONS + VR41XX_GPIO_BUTTONS): enabled. Prints
#     `VR41xx button input driver version 0.1.1`. Needed a new
#     include/asm-mips/vr4131/vr4131.h header (the linux4be tree shipped
#     without one) that aliases the VR4122 BCU/CMU/ICU/PMU/GIU register
#     layout as `__vr41xx_preg16` pointer macros plus VR41XX_IRQ_POWER.
#   * NAND/MTD/JFFS2 (CASIO_BE300_NAND + MTD + JFFS2_FS): enabled.
#     New file arch/mips/vr41xx/vr4131/casio-be300/nand_be300.c is a
#     custom mtd_info driver that drives the VRC4173 XFER engine
#     directly (PA 0x0A00A4xx + 0x0A00B000), bypassing the 2.4 NAND
#     framework (which only supports direct-IO CLE/ALE/NCE). Boot
#     registers: `BE-300 NAND: 16 MiB Samsung K9F2808 (XFER engine) /
#     Creating 4 MTD partitions on "BE-300 NAND" / 0x00000000-0x00004000
#     : "ptable" / 0x00004000-0x00014000 : "spl" / 0x00014000-0x00500000
#     : "kernel" / 0x00500000-0x01000000 : "rootfs"` plus the JFFS2
#     module loads. Mounting JFFS2-on-NAND as root requires (a) writing
#     a JFFS2 blob into the rebuilt NAND's mtd3 region and (b) adding
#     `root=/dev/mtdblock3 rootfstype=jffs2` to the kernel cmdline —
#     both build-pipeline tasks (see board/casio-be300/spl_start.S
#     a0..a3 zeroing for the cmdline channel).
#   * Touchscreen (CASIO_BE300_TOUCH): enabled. New file
#     arch/mips/vr41xx/vr4131/casio-be300/touch_be300.c — VRC4173 PIU
#     touchscreen driver ported from 4.2.9's board/casio-be300/touch_be300.c.
#     Uses polled scan via kernel timer (50 Hz) because the 2.4 linux4be
#     tree never wired the VRC4173 GIRQ0 cascade. Exposes /dev/be300tpanel
#     (misc minor 170) returning u16 x,y,down,_pad records. Boot prints
#     `BE-300 touchscreen: VRC4173 PIU @ PA 0x0A000300, polled at 50 Hz`.
#   * Stowaway keyboard (CASIO_BE300_STOWAWAY): enabled. New file
#     arch/mips/vr41xx/vr4131/casio-be300/stowaway_be300.c — 2.4 port of
#     board/casio-be300/stowaway_serio.c that collapses the 4.2.9 serio +
#     drivers/input/keyboard/stowaway.c pair into one self-contained
#     module because 2.4 has the input layer but no serio framework.
#     Polls SIU UART at 20 ms, runs the 4.2.9 probe handshake, decodes
#     scancodes against the same skbd_keycode table, emits input events.
#     Also flips CONFIG_INPUT/INPUT_KEYBDEV/INPUT_EVDEV on. Probe only
#     completes when the emulator runs with --stowaway-keyboard.
#   * CF host (CASIO_BE300_CF): enabled. New file
#     arch/mips/vr41xx/vr4131/casio-be300/cf_be300.c — board-specific
#     IDE host that provides struct ide_ops be300_ide_ops (replacing the
#     broken `&std_ide_ops` reference in setup.c) and `set_io_port_base(
#     KSEG1ADDR(0x0A00C000))` so the 2.4 IDE layer's inb(0x170)/inb(0x376)
#     hits PA 0x0A00C170 / 0x0A00C376 — same CF taskfile as 4.2.9's
#     cf_linux_loader.c. Also opens up the CONFIG_IDE Kconfig gate
#     (previously ISA/PCI-only) to admit CONFIG_CASIO_BE300. Boot log
#     with --cf <image> shows `hda: BE-300 RECOVERY CF, ATA DISK drive
#     / ide0 at 0x170-0x177,0x376 on irq 49 / hda: 16514064 sectors
#     (8455 MB), CHS=16383/16/63`. Actual reads fail with
#     DriveStatusError because the placeholder IRQ never fires — the
#     IDE state machine times out. Wiring the real VRC4173 GIRQ0 cascade
#     (SYSINT1 bit 8 -> GIU pin 0 -> VRC4173 GIRQ0 status) is a follow-on.
#
#   * IRQ cascade (CASIO_BE300_IRQ_CASCADE): enabled. New file
#     arch/mips/vr41xx/vr4131/casio-be300/irq_be300.c — VRC4173 GIRQ0
#     second-level demuxer. SYSINT1.bit8 -> GIU pin 0 -> GIRQ0 status
#     at PA 0x0A000004 -> per-bit sub-IRQ from VRC4173_IRQ_BASE (72).
#     Installed via the vr41xx `board_irq_init` function pointer hook
#     from nec_vr41xx_setup(), which runs after init_IRQ sets up the
#     GIU but before any driver initcall — exactly when CF's
#     request_irq(VRC4173_IRQ_BASE+0) needs the chip in place. Boot
#     prints `BE-300 IRQ: VRC4173 GIRQ0 demux at PA 0x0A000004 ->
#     VRC4173_IRQ_BASE..87 (cascade on GIU_IRQ(0))`. CF then registers
#     `ide0 at 0x170-0x177,0x376 on irq 72`. CF reads still fail with
#     DriveStatusError — not a cascade defect, but the emulator's
#     CF model implementing only IDENTIFY + READ_SECTORS while the 2.4
#     legacy IDE driver issues unsupported SET_GEOMETRY /
#     INITIALIZE_DEVICE_PARAMETERS commands during init.
#
# Five new chip-specific source files under
# arch/mips/vr41xx/vr4131/casio-be300/ (nand_be300, touch_be300,
# stowaway_be300, cf_be300, irq_be300) plus
# include/asm-mips/vr4131/vr4131.h are all carried in
# patches/linux-2.4.18-be300/0001-modern-toolchain-fixes.patch
# (54 files, ~3294 lines).
#
# Intended invocation:
#   docker-compose run --rm mips-dev bash -c "BE300_2_4_MODE=prebuilt ./build_be300_2_4_kernel.sh"
#   docker-compose run --rm mips-dev bash -c "./build_be300_2_4_kernel.sh"   # rebuild

set -euo pipefail

REPO=/work
MODE="${BE300_2_4_MODE:-rebuild}"
PREBUILT_VMLINUX="$REPO/kernels/vmlinux-2.4"
SOURCE_DIR="$REPO/linux-2.4.18"
BUILT_VMLINUX="$SOURCE_DIR/vmlinux"
PATCH_SERIES="$REPO/patches/linux-2.4.18-be300/series"
TARBALL="$REPO/archives/linux4be-2.4.18-20021129.tar.gz"
SPL_BUILD="$SOURCE_DIR/spl_build"

if [[ "$MODE" == "prebuilt" ]]; then
    OUT="${BE300_2_4_NAND:-$REPO/linux-4.2.9/be300-2_4.nand}"
    VMLINUX="$PREBUILT_VMLINUX"
    SPL_BUILD="${BE300_2_4_SPL_BUILD:-$REPO/linux-4.2.9/spl_build_2_4}"

    echo "=== build_be300_2_4_kernel.sh (prebuilt mode) ==="
    echo "  VMLINUX = $VMLINUX"
    echo "  OUT     = $OUT"
    [[ -f "$VMLINUX" ]] || { echo "ERROR: $VMLINUX missing" >&2; exit 1; }

    python3 "$REPO/tools/pack_legacy_kernel_nand.py" \
        --vmlinux "$VMLINUX" \
        --out "$OUT" \
        --build-dir "$SPL_BUILD"
    ls -l "$OUT"
    exit 0
fi

# Rebuild mode
OUT="${BE300_2_4_NAND:-$REPO/linux-4.2.9/be300-2_4-rebuilt.nand}"

# BE300_2_4_ROOT={initrd|nand}: root filesystem source.
#   initrd (default) — kernel mounts the embedded ext2 ramdisk lifted
#                      from kernels/vmlinux-2.4's __rd_start..__rd_end.
#                      cmdline: root=/dev/ram rootfstype=ext2 init=/sbin/init
#   nand             — kernel mounts JFFS2 from /dev/mtdblock3 (NAND
#                      offset 0x500000 in the packed image). cmdline:
#                      root=/dev/mtdblock3 rootfstype=jffs2 rootwait.
#                      A fresh JFFS2 image is built from the same
#                      initrd contents (busybox + hw_test + the
#                      /dev/console / /dev/tty0 / /dev/input/* device
#                      nodes), via mkfs.jffs2 --devtable.
ROOT_MODE="${BE300_2_4_ROOT:-initrd}"

# BE300_2_4_UI=opie selects the dynamically-linked uClibc-ng Opie 1.2.5 /
# Qt-Embedded 2.3.10 userspace stack on top of the 2.4.18 kernel. It
# forces ROOT_MODE=opie (a JFFS2 rootfs on /dev/mtdblock3 produced via
# board/opie/build_opie_rootfs.sh) and routes through the existing 4.2.9
# BusyBox + Opie pipeline by invoking build_be300_kernel.sh with
# BE300_ROOTFS_ONLY=1 — only the rootfs phase runs; the 4.2.9 kernel
# build is skipped because we supply our own 2.4.18 vmlinux below.
BE300_2_4_UI="${BE300_2_4_UI:-none}"
case "$BE300_2_4_UI" in
    none) ;;
    opie)
        ROOT_MODE="opie"
        OUT="${BE300_2_4_NAND:-$REPO/linux-4.2.9/be300-2_4-opie.nand}"
        ;;
    *)
        echo "ERROR: BE300_2_4_UI must be 'none' or 'opie' (got '$BE300_2_4_UI')" >&2
        exit 2
        ;;
esac

BE300_2_4_CONSOLE="${BE300_2_4_CONSOLE:-tty0}"
case "$BE300_2_4_CONSOLE" in
    tty0|ttyS0)
        ;;
    *)
        echo "ERROR: BE300_2_4_CONSOLE must be 'tty0' or 'ttyS0' (got '$BE300_2_4_CONSOLE')" >&2
        exit 2
        ;;
esac

if [[ "$ROOT_MODE" != "initrd" && "$ROOT_MODE" != "nand" && "$ROOT_MODE" != "cf" && "$ROOT_MODE" != "opie" ]]; then
    echo "ERROR: BE300_2_4_ROOT must be 'initrd', 'nand', 'cf', or 'opie' (got '$ROOT_MODE')" >&2
    exit 2
fi

echo "=== build_be300_2_4_kernel.sh (rebuild mode) ==="
echo "  source   = $SOURCE_DIR"
echo "  patches  = $PATCH_SERIES"
echo "  out      = $OUT"
echo "  root     = $ROOT_MODE"
echo "  ui       = $BE300_2_4_UI"
echo "  console  = $BE300_2_4_CONSOLE"

# 1. Stage source tree
if [[ ! -f "$SOURCE_DIR/Makefile" ]]; then
    echo "--- Extracting $TARBALL ---"
    [[ -f "$TARBALL" ]] || { echo "ERROR: $TARBALL missing" >&2; exit 1; }
    mkdir -p "$SOURCE_DIR"
    # Tarball top-level is linux4be-2.4.18-20021129/; flatten into $SOURCE_DIR
    TMP=$(mktemp -d)
    tar -xzf "$TARBALL" -C "$TMP"
    INNER=$(find "$TMP" -maxdepth 2 -name Makefile -path '*/2.4*/Makefile' | head -1 | xargs dirname 2>/dev/null || true)
    [[ -z "$INNER" ]] && INNER=$(ls -d "$TMP"/*/ | head -1)
    cp -a "$INNER"/. "$SOURCE_DIR"/
    rm -rf "$TMP"
fi

# 2. Apply modern-toolchain patch series. Wraps git apply, idempotent.
"$REPO/scripts/apply_patch_series.sh" "$PATCH_SERIES" "$SOURCE_DIR"

# 2b. Force a kernel object clean.  $SOURCE_DIR lives on the host-mounted
# /work volume, so the extracted/patched tree (and its .o files) persists
# across `docker compose run` invocations — section 1 only re-extracts
# when $SOURCE_DIR/Makefile is absent.  2.4's `.depend` machinery does
# NOT track include/linux/autoconf.h, so a .config change (e.g. toggling
# CONFIG_SERIAL_BE300_CONSOLE in section 4) does NOT cause `make vmlinux`
# to recompile the affected objects — stale serial_be300.o/etc. get
# re-linked and the kernel behaves as if the config never changed (only
# prom.o rebuilt, because the cmdline sed in section 3a edits prom.c
# content).  A kernel `make clean` here (before ramdisk staging and the
# section-4 config assembly) removes stale .o without touching .config /
# autoconf.h, so the subsequent `make vmlinux` rebuilds everything
# against the freshly generated autoconf.h.  No-op on a first extract.
if [[ -f "$SOURCE_DIR/Makefile" ]]; then
    echo "--- make clean (propagate config changes; persistent /work tree) ---"
    ( cd "$SOURCE_DIR" && make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- clean >/dev/null 2>&1 ) || true
fi

# 3. Drop the embedded ramdisk into arch/mips/ramdisk/ramdisk.gz.
#
# ROOT_MODE=opie boots DIRECTLY from /dev/mtdblock3 with no initrd,
# matching the 4.2.9 NAND boot pattern and the real BE-300 hardware
# (16 MiB SDRAM, no ramdisk overhead).  We disable CONFIG_BLK_DEV_INITRD
# in the kernel config (see configs/be300_2_4_opie.config) and skip
# the ramdisk extract / inject sections below.  The 2.4 kernel needs
# arch/mips/ramdisk/ramdisk.gz to exist at link time only because the
# stock Makefile in this tree always links arch/mips/ramdisk/ — drop
# in a 20-byte gzip-of-empty placeholder so the link succeeds while
# CONFIG_BLK_DEV_INITRD=n keeps the kernel from probing it.
RAMDISK_GZ="$SOURCE_DIR/arch/mips/ramdisk/ramdisk.gz"
if [[ "$ROOT_MODE" == "opie" ]]; then
    if [[ ! -f "$RAMDISK_GZ" ]]; then
        mkdir -p "$(dirname "$RAMDISK_GZ")"
        printf '\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
            > "$RAMDISK_GZ"
    fi
fi
if [[ "$ROOT_MODE" != "opie" && ! -f "$RAMDISK_GZ" ]]; then
    echo "--- Extracting initrd from $PREBUILT_VMLINUX into $RAMDISK_GZ ---"
    [[ -f "$PREBUILT_VMLINUX" ]] || { echo "ERROR: $PREBUILT_VMLINUX missing" >&2; exit 1; }
    python3 - <<PYEOF
import struct
data = open("$PREBUILT_VMLINUX","rb").read()
e_shoff = struct.unpack_from('<I', data, 32)[0]
e_shentsize = struct.unpack_from('<H', data, 46)[0]
e_shnum = struct.unpack_from('<H', data, 48)[0]
e_shstrndx = struct.unpack_from('<H', data, 50)[0]
sec_shstr = struct.unpack_from('<IIIIIIIIII', data, e_shoff + e_shstrndx*e_shentsize)
shstr_off = sec_shstr[4]
def get_str(off): return data[shstr_off+off:].split(b'\x00',1)[0].decode()
sections=[]
for i in range(e_shnum):
    o = e_shoff + i*e_shentsize
    s = struct.unpack_from('<IIIIIIIIII', data, o)
    sections.append((get_str(s[0]), s))
symtab = next(s for n,s in sections if n=='.symtab')
strtab = sections[symtab[6]][1]
def get_strtab(off): return data[strtab[4]+off:].split(b'\x00',1)[0].decode()
nsyms = symtab[5] // symtab[9]
rd_start = rd_end = None
for i in range(nsyms):
    o = symtab[4] + i*symtab[9]
    st_name, st_value, *_ = struct.unpack_from('<IIIBBH', data, o)
    name = get_strtab(st_name)
    if name == '__rd_start': rd_start = st_value
    if name == '__rd_end':   rd_end   = st_value
e_phoff = struct.unpack_from('<I', data, 28)[0]
e_phnum = struct.unpack_from('<H', data, 44)[0]
for i in range(e_phnum):
    o = e_phoff + i*32
    p_type, p_offset, p_vaddr, p_paddr, p_filesz, *_ = struct.unpack_from('<IIIIIIII', data, o)
    if p_type == 1 and p_vaddr <= rd_start < p_vaddr + p_filesz:
        rel = rd_start - p_vaddr
        open("$RAMDISK_GZ","wb").write(data[p_offset+rel : p_offset+rel + (rd_end-rd_start)])
        print(f'wrote $RAMDISK_GZ ({rd_end-rd_start} bytes)')
        break
PYEOF
fi

if [[ "$ROOT_MODE" != "opie" ]]; then

# 3a. Build the userspace HW test program and inject it into the initrd.
#
# The prebuilt vmlinux-2.4's initrd is a 4 MiB ext2 image with BusyBox,
# 40+ char device nodes (console, tty0, ttyS0, null, …), and an
# /etc/init.d/rcS that just prints "Welcome to Linux4BE". We inject
# /usr/bin/be300_hw_test and a small rcS suffix that runs it once
# before askfirst hands control to /bin/sh, then write the result back
# out to $RAMDISK_GZ.
#
# Use debugfs(8) in -w (read/write) mode instead of rdump + mke2fs:
# rdump silently drops device nodes when extracting to a host
# directory (they need CAP_MKNOD on the destination FS), so a
# round-trip through that path produces a /dev with only symlinks and
# the MAKEBEDEVS script, and the kernel then prints "Warning: unable
# to open an initial console." right after init starts. debugfs -w
# edits the ext2 image in place and keeps every original inode.
#
# Idempotency: $RAMDISK_GZ.orig is the pristine ramdisk extracted
# straight from kernels/vmlinux-2.4's __rd_start..__rd_end (refreshed
# only if missing). $RAMDISK_GZ.hwstamp records the sha1 of
# be300_hw_test.c; when it matches the current source, we trust the
# existing $RAMDISK_GZ and skip the inject step.
HWTEST_SRC="$REPO/board/casio-be300/be300_hw_test.c"
HWTEST_STAMP="$RAMDISK_GZ.hwstamp"
RAMDISK_ORIG="$RAMDISK_GZ.orig"
HWTEST_HASH=$(sha1sum "$HWTEST_SRC" | awk '{print $1}')

# Snapshot the pristine extracted ramdisk on first build so we can
# re-inject from a known-good base every subsequent run.
if [[ ! -f "$RAMDISK_ORIG" ]]; then
    cp "$RAMDISK_GZ" "$RAMDISK_ORIG"
fi

if [[ ! -f "$HWTEST_STAMP" || "$(cat "$HWTEST_STAMP" 2>/dev/null)" != "$HWTEST_HASH" ]]; then
    echo "--- Building be300_hw_test and injecting into initrd ---"
    HWTEST_BIN="$REPO/linux-2.4.18/be300_hw_test"

    # Patch libgcc.a: the Debian mipsel-linux-gnu libgcc.a uses MIPS32
    # SPECIAL2 opcodes (mul, clz, etc.) in its 64-bit/float helpers, and
    # VR4131 raises Reserved Instruction on those. Same patching the
    # 4.2.9 build does in Phase 0a — see board/casio-be300/libgcc_helpers.c
    # + build_be300_kernel.sh::prepare_be300_libgcc(). Idempotent: skip
    # if already patched in this container.
    if [[ ! -f /tmp/libgcc_patched/libgcc.a ]]; then
        mkdir -p /tmp/libgcc_patched
        LIBGCC_ORIG=$(mipsel-linux-gnu-gcc -print-libgcc-file-name)
        cp "$LIBGCC_ORIG" /tmp/libgcc_patched/libgcc.a
        mipsel-linux-gnu-ar d /tmp/libgcc_patched/libgcc.a \
            _mulsc3.o _muldc3.o \
            eqsf2.o nesf2.o gesf2.o gtsf2.o lesf2.o ltsf2.o unordsf2.o \
            eqdf2.o nedf2.o gedf2.o gtdf2.o ledf2.o ltdf2.o unorddf2.o \
            _divdi3.o _moddi3.o _udivdi3.o _umoddi3.o \
            _fixdfdi.o _fixunsdfdi.o _floatdidf.o _floatundidf.o \
            _lshrdi3.o _ashldi3.o _ashrdi3.o _negdi2.o \
            _clz.o _clzsi2.o _clzdi2.o _ctzsi2.o _ctzdi2.o \
            _popcount_tab.o _popcountsi2.o _popcountdi2.o _paritysi2.o _paritydi2.o \
            _ffssi2.o _ffsdi2.o \
            _bswapsi2.o _bswapdi2.o \
            2>/dev/null || true
        mipsel-linux-gnu-gcc -march=mips2 -msoft-float -O2 -fPIC -ffreestanding -fno-builtin \
            -c -o /tmp/libgcc_helpers.o /work/board/casio-be300/libgcc_helpers.c
        mipsel-linux-gnu-ar rcs /tmp/libgcc_patched/libgcc.a /tmp/libgcc_helpers.o
    fi

    # -Wl,--entry=_start: gcc inlines _start's small static helpers,
    # which can leave the linker picking the FIRST text address (the
    # inlined helper) as the entry. That made the entry land on _puts
    # — first instruction tried to use argc as a pointer and SEGV'd
    # before any output appeared. Force the entry symbol so it's stable
    # regardless of inlining order.
    mipsel-linux-gnu-gcc -march=mips2 -static -nostdlib -nostdinc \
        -fno-pic -mno-abicalls -fomit-frame-pointer -Os -Wall \
        -Wl,--entry=_start \
        -o "$HWTEST_BIN" "$HWTEST_SRC"
    mipsel-linux-gnu-strip "$HWTEST_BIN"

    # Also build be300_linuxrc — a 2-instruction binary used as /linuxrc
    # in NAND mode (replaces the busybox symlink, which would otherwise
    # block change_root indefinitely as the init applet).
    LINUXRC_BIN="$REPO/linux-2.4.18/be300_linuxrc"
    mipsel-linux-gnu-gcc -march=mips2 -static -nostdlib -nostdinc \
        -fno-pic -mno-abicalls -fomit-frame-pointer -Os -Wall \
        -Wl,--entry=_start \
        -o "$LINUXRC_BIN" "$REPO/board/casio-be300/be300_linuxrc.c"
    mipsel-linux-gnu-strip "$LINUXRC_BIN"

    # Rewrite the ELF e_flags MIPS-arch field.
    #
    # Modern binutils stamps -march=mips2 PIC-linked output with
    # arch bits 0x70000000 (the post-2009 EF_MIPS_ARCH renumbering's
    # `mips32r2`). 2.4.18's include/asm-mips/elf.h uses the original
    # numbering where 0x70000000 is `mips64`, and elf_check_arch()
    # rejects anything that isn't mips1/2/32/32r2 — so execve() fails
    # and the shell falls through to interpreting the ELF bytes as a
    # script ("Syntax error: ')' unexpected" in the boot log).
    #
    # The code is already MIPS-II by -march=mips2; only the metadata
    # is wrong. Force the arch bits to EF_MIPS_ARCH_2 (0x10000000),
    # preserving the low ABI/PIC/CPIC flags.
    python3 - "$HWTEST_BIN" "$LINUXRC_BIN" <<'PYEOF'
import struct, sys
for p in sys.argv[1:]:
    b = bytearray(open(p,'rb').read())
    # ELF32 e_flags is at offset 36, little-endian on mipsel.
    ef = struct.unpack_from('<I', b, 36)[0]
    new = (ef & ~0xF0000000) | 0x10000000
    struct.pack_into('<I', b, 36, new)
    open(p,'wb').write(b)
    print(f'patched {p}: e_flags 0x{ef:08x} -> 0x{new:08x}')
PYEOF
    echo "  built  $(ls -la "$HWTEST_BIN" | awk '{print $5, $9}')"

    # Quick mips32-opcode safety scan. VR4131 SIGILLs on SPECIAL2 integer
    # mul/clz/clo and on MIPS32 conditional moves. Use exact-match anchors
    # (^opcode$) so FPU mul.d / mul.s don't false-positive — those are
    # plain MIPS I FPU instructions trapped by the kernel's FPU emulator,
    # which is fine on VR4131 (Algorithmics MIPS FPU Emulator v1.5).
    UNSUPPORTED=$(mipsel-linux-gnu-objdump -d "$HWTEST_BIN" 2>/dev/null | \
        awk '$3 ~ /^(mul|clz|clo|ext|ins|movf|movn|movt|movz|seb|seh|wsbh|rdhwr)$/ {print; n++} END{print "COUNT="(n+0)}' | \
        tail -1 | sed 's/COUNT=//')
    if [[ "$UNSUPPORTED" != "0" ]]; then
        echo "ERROR: $HWTEST_BIN contains $UNSUPPORTED VR4131-unsupported opcodes" >&2
        mipsel-linux-gnu-objdump -d "$HWTEST_BIN" 2>/dev/null | \
            awk '$3 ~ /^(mul|clz|clo|ext|ins|movf|movn|movt|movz|seb|seh|wsbh|rdhwr)$/ {print}' | head -10 >&2
        exit 1
    fi

    # Inject via debugfs -w directly into the original ext2 image so
    # every device node from MAKEBEDEVS (console, tty0, ttyS0, null,
    # zero, fb0, ram0/1, ptya0..f, ttya0..f, tty0..9, kmem, mem, …)
    # is preserved.
    RD_WORK=$(mktemp -d)
    trap "rm -rf $RD_WORK" EXIT
    cp "$RAMDISK_ORIG" "$RD_WORK/ramdisk.gz"
    gunzip -f "$RD_WORK/ramdisk.gz"

    # Dump the original rcS, append the hw-test invocation.
    debugfs -R "dump /etc/init.d/rcS $RD_WORK/rcS" "$RD_WORK/ramdisk" >/dev/null
    cat "$RD_WORK/rcS" > "$RD_WORK/rcS.new"
    cat >> "$RD_WORK/rcS.new" <<'RCS_EOF'

# BE-300 HW smoke test — added by build_be300_2_4_kernel.sh.
# debugfs(8)'s mknod allocates inodes but doesn't link them into the
# directory entry, and the original 2003 initrd predates MTD entirely,
# so create /dev/input/eventN and /dev/mtd{,block}N with BusyBox mknod
# at boot. MTD char major is 90, mtdblock major is 31, evdev major 13.
mkdir -p /dev/input
[ -c /dev/input/event0 ] || mknod /dev/input/event0 c 13 64
[ -c /dev/input/event1 ] || mknod /dev/input/event1 c 13 65
[ -c /dev/input/event2 ] || mknod /dev/input/event2 c 13 66
[ -c /dev/input/event3 ] || mknod /dev/input/event3 c 13 67
[ -c /dev/mtd0 ] || mknod /dev/mtd0 c 90 0
[ -c /dev/mtd1 ] || mknod /dev/mtd1 c 90 2
[ -c /dev/mtd2 ] || mknod /dev/mtd2 c 90 4
[ -c /dev/mtd3 ] || mknod /dev/mtd3 c 90 6
[ -b /dev/mtdblock0 ] || mknod /dev/mtdblock0 b 31 0
[ -b /dev/mtdblock1 ] || mknod /dev/mtdblock1 b 31 1
[ -b /dev/mtdblock2 ] || mknod /dev/mtdblock2 b 31 2
[ -b /dev/mtdblock3 ] || mknod /dev/mtdblock3 b 31 3

echo "--- be300_hw_test (fb mmap) ---"
/usr/bin/be300_hw_test
echo "--- be300_hw_test exit=$? ---"
echo "--- proc/mtd ---"
cat /proc/mtd
echo "--- input event nodes ---"
ls -l /dev/input 2>/dev/null
echo "--- mtd0 first 32 bytes ---"
dd if=/dev/mtd0 bs=32 count=1 2>/dev/null | od -An -tx1 -N32
echo "--- date / RTC ---"
date
echo "--- be300_hw_test rcS section done ---"
RCS_EOF

    # /linuxrc in the original initrd is a symlink to "bin/busybox".
    # When the kernel runs /linuxrc as the initrd→root pivot helper,
    # BusyBox 0.60.5 falls through to its init applet because there's
    # no "linuxrc" applet — and init never exits, so the kernel
    # waits forever for /linuxrc, blocking the change_root() to the
    # JFFS2 NAND partition. Replace the symlink with a pointer to
    # /bin/true (busybox's true applet exits 0 immediately), which
    # lets the kernel proceed to change_root.
    # In NAND mode, replace /linuxrc with a shell script that mounts
    # JFFS2 from /dev/mtdblock3 and chroot-execs the real /sbin/init,
    # bypassing the kernel's change_root() path which hangs silently
    # in this configuration. The kernel_thread running /linuxrc execs
    # into the chrooted /sbin/init and never exits — that's fine, the
    # rest of init() (free_initmem, execve fallback chain) just stays
    # waiting on wait(), which is the documented "exec-from-initrd"
    # variant of the 2.4 boot.
    if [[ "$ROOT_MODE" == "opie" ]]; then
        # Mount JFFS2 from /dev/mtdblock3, chroot+exec the Opie init.
        # Same approach as nand mode; the kernel keeps the initrd mount
        # alive while busybox-init runs in the chrooted JFFS2 view.
        cat > "$RD_WORK/linuxrc" <<'LRCEOF'
#!/bin/sh
exec >/dev/console 2>/dev/console
echo "linuxrc: opie nand-root pivot: mounting jffs2 from /dev/mtdblock3"
mkdir -p /newroot
[ -c /dev/mtdblock3 ] || mknod /dev/mtdblock3 b 31 3
mount -t jffs2 /dev/mtdblock3 /newroot
echo "linuxrc: chroot into /newroot and exec /sbin/init"
cd /newroot
exec /bin/busybox chroot . /sbin/init
LRCEOF
        chmod 0755 "$RD_WORK/linuxrc"
        LINUXRC_TARGET="$RD_WORK/linuxrc"
    elif [[ "$ROOT_MODE" == "nand" ]]; then
        # mknod a /dev/mtdblock3 inside the initrd's /dev so the shell
        # has a path to mount, plus a /newroot mount point.
        cat > "$RD_WORK/linuxrc" <<'LRCEOF'
#!/bin/sh
exec >/dev/console 2>/dev/console
echo "linuxrc: nand-root pivot: mounting jffs2 from /dev/mtdblock3"
mkdir -p /newroot
[ -c /dev/mtdblock3 ] || mknod /dev/mtdblock3 b 31 3
mount -t jffs2 /dev/mtdblock3 /newroot
echo "linuxrc: chroot into /newroot and exec /sbin/init"
cd /newroot
exec /bin/busybox chroot . /sbin/init
LRCEOF
        chmod 0755 "$RD_WORK/linuxrc"
        LINUXRC_TARGET="$RD_WORK/linuxrc"
    else
        LINUXRC_TARGET="$LINUXRC_BIN"
    fi
    debugfs -w -f - "$RD_WORK/ramdisk" >/dev/null 2>&1 <<EOF
rm /etc/init.d/rcS
write $RD_WORK/rcS.new /etc/init.d/rcS
set_inode_field /etc/init.d/rcS mode 0100755
write $HWTEST_BIN /usr/bin/be300_hw_test
set_inode_field /usr/bin/be300_hw_test mode 0100755
rm /linuxrc
write $LINUXRC_TARGET /linuxrc
set_inode_field /linuxrc mode 0100755
EOF

    gzip -9 -n "$RD_WORK/ramdisk"
    cp "$RD_WORK/ramdisk.gz" "$RAMDISK_GZ"
    echo "$HWTEST_HASH" > "$HWTEST_STAMP"
    echo "  packed $(ls -la "$RAMDISK_GZ" | awk '{print $5, $9}')"
fi

fi  # end ROOT_MODE != opie guard around section 3a

# 3b. NAND-root cmdline swap. Patch 0002 hardcodes
# `root=/dev/ram rootfstype=ext2 init=/sbin/init` in prom.c. Swap that
# to the JFFS2 NAND mtd3 path when BE300_2_4_ROOT=nand, then restore on
# exit so the source tree stays the same regardless of how the build
# was invoked. (Cleaner long-term: have the SPL pass a real cmdline in
# argv. For now, prom.c carries the default and we mutate it briefly.)
PROM_C="$SOURCE_DIR/arch/mips/vr41xx/vr4131/casio-be300/prom.c"
if [[ "$ROOT_MODE" == "nand" ]]; then
    cp "$PROM_C" "$PROM_C.cmdline-bak"
    trap '[[ -f "'"$PROM_C"'.cmdline-bak" ]] && mv "'"$PROM_C"'.cmdline-bak" "'"$PROM_C"'" || true' EXIT
    # Use the documented 2.4 initrd-to-root pivot path: keep
    # mount_initrd enabled so the kernel mounts the embedded ramdisk,
    # runs /linuxrc as process 1, then transparently switches root to
    # `real_root_dev` (mtdblock3) via change_root(). The original
    # initrd's /linuxrc symlinks to /bin/busybox; busybox invoked as
    # "linuxrc" has no matching applet and exits non-zero, which is
    # fine — the kernel proceeds with change_root regardless.
    # Drop `rootfstype=`: it's a global setting in 2.4, so specifying
    # rootfstype=jffs2 makes mount_root try jffs2 on the initrd's
    # /dev/ram0 too (which is ext2 → panic). Without rootfstype,
    # mount_root iterates every registered filesystem. ext2 for the
    # initrd, then jffs2 for mtdblock3 after change_root.
    sed -i 's|root=/dev/ram rootfstype=ext2 init=/sbin/init|root=/dev/mtdblock3 init=/sbin/init|' "$PROM_C"
    echo "--- patched prom.c for NAND root cmdline ---"
elif [[ "$ROOT_MODE" == "cf" ]]; then
    cp "$PROM_C" "$PROM_C.cmdline-bak"
    trap '[[ -f "'"$PROM_C"'.cmdline-bak" ]] && mv "'"$PROM_C"'.cmdline-bak" "'"$PROM_C"'" || true' EXIT
    sed -i 's|root=/dev/ram rootfstype=ext2 init=/sbin/init|noinitrd root=/dev/hda1 rootfstype=ext2 rw|' "$PROM_C"
    echo "--- patched prom.c for CF root cmdline ---"
elif [[ "$ROOT_MODE" == "opie" ]]; then
    # Opie boots DIRECTLY from JFFS2 on /dev/mtdblock3 — no initrd,
    # no /linuxrc pivot, matching the 4.2.9 NAND boot path and the real
    # BE-300 16 MiB hardware.  prepare_namespace() calls mount_root()
    # which uses the ROOT_DEV parsed from root=/dev/mtdblock3.
    # `noinitrd` tells the kernel to skip the initrd handler even though
    # CONFIG_BLK_DEV_INITRD must remain on (legacy ramdisk.gz link).
    # The askfirst UART must NOT also be a kernel console=.  inittab runs
    # ttyS0::askfirst:/bin/sh — if the kernel also mirrors printk into
    # ttyS0, the askfirst shell reads boot-log lines
    # as its stdin, tries to exec them, dies, and respawns: a prompt
    # flood, never a usable console.  Same class as the 4.2.9
    # console=ttyVR0 + ttyVR0::askfirst conflict, fixed there by shipping
    # console=tty0 only (configs/be300_defconfig).
    #
    # The earlier theory that serial_be300's tty_driver "hangs on close
    # drain" was WRONG.  That symptom was uClibc-ng _exit() issuing
    # exit_group (o32 syscall 4246), absent in stock 2.4.18 -> -ENOSYS ->
    # uClibc's `break 0xff` guard -> SIGTRAP on every process exit.
    # Root-caused and fixed by
    # patches/linux-2.4.18-be300/0008-be300-2_4-add-exit_group-syscall.patch
    # (present and active in the series); serial_be300 is not the culprit.
    #
    # Default to console=tty0 only.  It is the sole console=, so /dev/console
    # still resolves to fbcon and userspace echo still lands on the LCD
    # for screenshots; ttyS0 stays a clean UART whose askfirst shell is
    # interactive.  This intentionally drops the serial printk
    # mirror — the same tradeoff 4.2.9 accepts (boot log goes to
    # fbcon/LCD).  For serial boot-log capture, build with
    # BE300_2_4_CONSOLE=ttyS0; the rootfs overlay below then suppresses
    # the ttyS0 askfirst shell so the kernel console owns that UART.
    cp "$PROM_C" "$PROM_C.cmdline-bak"
    trap '[[ -f "'"$PROM_C"'.cmdline-bak" ]] && mv "'"$PROM_C"'.cmdline-bak" "'"$PROM_C"'" || true' EXIT
    OPIE_CMDLINE="consoleblank=0 noinitrd root=/dev/mtdblock3 rootfstype=jffs2 init=/sbin/init console=${BE300_2_4_CONSOLE}"
    sed -i "s|console=tty0 consoleblank=0 root=/dev/ram rootfstype=ext2 init=/sbin/init|$OPIE_CMDLINE|" "$PROM_C"
    echo "--- patched prom.c for Opie direct JFFS2 root cmdline (${BE300_2_4_CONSOLE}) ---"
fi

# 4. Configure
echo "--- make oldconfig ---"
cp "$SOURCE_DIR/config_be300" "$SOURCE_DIR/.config"

# CF mode overlay: re-enable CASIO_BE300_CF + CONFIG_IDE (turned off in
# 0003 to keep the default NAND profile from hanging on `hda: lost
# interrupt` without --cf attached). Merge configs/be300_2_4_cf.config
# over .config — later occurrences win in 2.4 oldconfig.
if [[ "$ROOT_MODE" == "cf" ]]; then
    if [[ -f "$REPO/configs/be300_2_4_cf.config" ]]; then
        echo "--- merging configs/be300_2_4_cf.config for CF mode ---"
        # Strip the disable lines, then append overrides.
        sed -i \
            -e '/# CONFIG_CASIO_BE300_CF is not set/d' \
            -e '/# CONFIG_IDE is not set/d' \
            -e '/# CONFIG_BLK_DEV_IDE is not set/d' \
            -e '/# CONFIG_BLK_DEV_IDEDISK is not set/d' \
            -e '/# CONFIG_IDEDISK_MULTI_MODE is not set/d' \
            "$SOURCE_DIR/.config"
        grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$REPO/configs/be300_2_4_cf.config" \
            >> "$SOURCE_DIR/.config"
    else
        echo "WARNING: $REPO/configs/be300_2_4_cf.config missing" >&2
    fi
fi

# Opie overlay: adds CONFIG_TMPFS/RAMFS/DEVPTS_FS so /etc/init.d/rcS can
# mount tmpfs on /tmp + /root and devpts on /dev/pts before /bin/start-opie
# spawns qpe.  CONFIG_BLK_DEV_INITRD stays on (the kernel tree assumes
# it everywhere — rd_init, real_root_dev, setup.c::initrd_start are all
# unconditionally referenced).  `noinitrd` on the cmdline tells the
# kernel to skip mounting the bogus 20-byte placeholder ramdisk at
# boot, so the 1.25 MiB allocation that was happening with the legacy
# initrd is gone — only the preallocation structs remain.
if [[ "$ROOT_MODE" == "opie" ]]; then
    if [[ -f "$REPO/configs/be300_2_4_opie.config" ]]; then
        echo "--- merging configs/be300_2_4_opie.config for Opie mode ---"
        sed -i \
            -e '/# CONFIG_TMPFS is not set/d' \
            -e '/# CONFIG_RAMFS is not set/d' \
            -e '/# CONFIG_DEVPTS_FS is not set/d' \
            "$SOURCE_DIR/.config"
        grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$REPO/configs/be300_2_4_opie.config" \
            >> "$SOURCE_DIR/.config"
    else
        echo "WARNING: $REPO/configs/be300_2_4_opie.config missing" >&2
    fi
fi

# Opie serial-console fix (2026-05-15).  serial_be300.c registers
# be300_sercons via register_console() in be300_console_init(), which
# tty_io.c calls while preferred_console < 0 (before the cmdline
# console= is applied).  2.4's register_console() therefore SELF-ENABLES
# it as the default boot console on index 0 = ttyS0 and pins
# CON_PRINTBUFFER printk to that UART for the rest of the boot —
# regardless of console=tty0.  inittab runs ttyS0::askfirst:/bin/sh on
# that same UART, so the getty is drowned in kernel printk and never
# usable (verified: <4> FPU-emulator printk on the ttyS0 pty, no
# askfirst banner).  Unlike 4.2.9's mainline vr41xx_siu console (which
# honors the console= preferred mechanism, so dropping console=ttyVR0
# was enough there), this one cannot be turned off from the cmdline.
# Disable the *console* while keeping the tty driver
# (CONFIG_SERIAL_BE300=y -> RX poll + /dev/ttyS0 + askfirst shell).
# This is the true 2.4 analogue of 4.2.9's working state.  Same tradeoff
# already accepted above: no early-boot kernel printk over serial
# (fbcon/LCD only).  The dep_bool has no `default y`, so disabling it in
# the seed .config survives `make oldconfig`.
if [[ "$ROOT_MODE" == "opie" && "$BE300_2_4_CONSOLE" != "ttyS0" ]]; then
    sed -i 's|^CONFIG_SERIAL_BE300_CONSOLE=y$|# CONFIG_SERIAL_BE300_CONSOLE is not set|' \
        "$SOURCE_DIR/.config"
    echo "--- disabled CONFIG_SERIAL_BE300_CONSOLE (clean getty UARTs) ---"
elif [[ "$ROOT_MODE" == "opie" ]]; then
    echo "--- keeping CONFIG_SERIAL_BE300_CONSOLE for ttyS0 console ---"
fi
# `yes ""` keeps writing after `make oldconfig` closes its stdin, which raises
# SIGPIPE on yes — with `set -o pipefail` that would fail the whole pipeline
# even though make exited 0. Disable pipefail just for this line so we accept
# yes's 141 if oldconfig succeeded.
( cd "$SOURCE_DIR" && set +o pipefail && yes "" | make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- oldconfig >/dev/null )
( cd "$SOURCE_DIR" && make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- dep >/dev/null 2>&1 )

# 5. Build vmlinux
echo "--- make vmlinux ---"
( cd "$SOURCE_DIR" && make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- vmlinux )
[[ -f "$BUILT_VMLINUX" ]] || { echo "ERROR: build did not produce $BUILT_VMLINUX" >&2; exit 1; }
mipsel-linux-gnu-size "$BUILT_VMLINUX"

# 5a. Build the JFFS2 NAND rootfs in nand or opie mode.
#
#   nand — rdumps the existing prebuilt initrd, walks /dev to build a
#          devtable, and runs mkfs.jffs2 with the same content.
#   opie — invokes build_be300_kernel.sh BE300_ROOTFS_ONLY=1 BE300_UI=opie
#          BE300_LIBC=uclibc to build a fresh BusyBox + uClibc-ng + Opie
#          rootfs into /work/rootfs_be300_opie, stages a 2.4-flavored
#          /etc/inittab + start-opie + pointercal, then mkfs.jffs2 with
#          board/casio-be300/be300_2_4_devtable.txt (because 2.4.18 has
#          no devtmpfs to auto-populate the device nodes).
JFFS2_ROOTFS=""
if [[ "$ROOT_MODE" == "nand" ]]; then
    echo "--- Building JFFS2 rootfs from initrd contents ---"
    JFFS2_ROOTFS="$REPO/linux-4.2.9/rootfs-2_4.jffs2"
    JFFS2_WORK=$(mktemp -d)
    # Re-extend the EXIT trap to also clean this up.
    trap '[[ -f "'"$PROM_C"'.cmdline-bak" ]] && mv "'"$PROM_C"'.cmdline-bak" "'"$PROM_C"'" || true; rm -rf "'"$JFFS2_WORK"'"' EXIT

    # Decompress the (already injected) initrd, rdump to a directory.
    cp "$RAMDISK_GZ" "$JFFS2_WORK/rd.gz"
    gunzip -f "$JFFS2_WORK/rd.gz"
    mkdir "$JFFS2_WORK/root"
    debugfs -R "rdump / $JFFS2_WORK/root" "$JFFS2_WORK/rd" >/dev/null

    # Walk /dev in the ext2 image and emit a mkfs.jffs2 devtable.
    # Format: <path> <type c|b|p> <mode> <uid> <gid> <major> <minor> <start> <inc> <count>
    python3 - "$JFFS2_WORK/rd" > "$JFFS2_WORK/devtable" <<'PYEOF'
import subprocess, sys, re
img = sys.argv[1]
out = subprocess.check_output(['debugfs', '-R', 'ls -l /dev', img], stderr=subprocess.DEVNULL).decode()
# /dev itself is also part of the dump but we recreate /dev/* nodes.
for line in out.splitlines():
    m = re.match(r'\s*\d+\s+(\d+)\s+\(\d+\)\s+(\d+)\s+(\d+)\s+\d+\s+\d+-\w+-\d+\s+\d+:\d+\s+(\S+)', line)
    if not m: continue
    mode, uid, gid, name = m.groups()
    if name in ('.', '..'): continue
    mode = int(mode, 8)
    type_bits = mode & 0o170000
    perm = mode & 0o7777
    if type_bits == 0o020000:
        t = 'c'
    elif type_bits == 0o060000:
        t = 'b'
    else:
        continue
    # Major/minor: read via stat
    s = subprocess.check_output(['debugfs', '-R', f'stat /dev/{name}', img], stderr=subprocess.DEVNULL).decode()
    mm = re.search(r'Device major/minor number:\s*(\d+):(\d+)', s)
    if not mm: continue
    major, minor = int(mm.group(1)), int(mm.group(2))
    print(f'/dev/{name} {t} {perm:o} {uid} {gid} {major} {minor} - - -')
PYEOF
    echo "  devtable: $(wc -l < "$JFFS2_WORK/devtable") device nodes"

    # mkfs.jffs2: drop the host-fs /dev entries that rdump created (they
    # are regular files for symlinks like /dev/fb -> fb0 plus broken
    # placeholders for char devs). Keep symlinks where appropriate; the
    # devtable will re-create the char/block nodes.
    find "$JFFS2_WORK/root/dev" -maxdepth 1 -type f -delete 2>/dev/null || true

    mkfs.jffs2 --root="$JFFS2_WORK/root" \
        --devtable="$JFFS2_WORK/devtable" \
        --eraseblock=16384 --pagesize=512 --no-cleanmarkers \
        --pad=0xB00000 --little-endian \
        --output="$JFFS2_ROOTFS"
    echo "  rootfs : $(ls -la "$JFFS2_ROOTFS" | awk '{print $5, $9}')"
fi

if [[ "$ROOT_MODE" == "opie" ]]; then
    echo "--- Building BusyBox + Opie 1.2.5 rootfs via build_be300_kernel.sh ---"
    OPIE_ROOTFS_DIR="/work/rootfs_be300_opie"
    JFFS2_ROOTFS="$REPO/linux-4.2.9/rootfs-2_4-opie.jffs2"
    DEVTABLE="$REPO/board/casio-be300/be300_2_4_devtable.txt"

    [[ -f "$DEVTABLE" ]] || { echo "ERROR: $DEVTABLE missing" >&2; exit 1; }

    # Delegate to the 4.2.9 build script in rootfs-only mode.  It runs
    # Phase 0/0a/0b (musl rebuild, kernel headers install, uClibc-ng
    # build) + Phase 1 (BusyBox) + the BE300_UI=opie Qt/Embedded + Opie
    # 1.2.5 build, then exits before Phase 2 (4.2.9 kernel build) because
    # of the BE300_ROOTFS_ONLY=1 short-circuit.  The 4.2.9 kernel headers
    # used to build uClibc-ng are header-compatible with 2.4.18 syscall
    # numbering on mipsel — verify at runtime by checking for `Function
    # not implemented` errors in dmesg.
    BE300_UI=opie BE300_LIBC=uclibc BE300_ROOTFS_ONLY=1 \
        bash "$REPO/build_be300_kernel.sh"

    [[ -d "$OPIE_ROOTFS_DIR" ]] || {
        echo "ERROR: build_be300_kernel.sh did not produce $OPIE_ROOTFS_DIR" >&2
        exit 1
    }

    # 5b. Stage the 2.4-flavored runtime overlay on top of /work/rootfs_be300_opie.
    #     The 4.2.9 build wrote an inittab that mounts devpts and starts
    #     start-opie on tty0; we rewrite it so the same intent works on
    #     2.4.18 (no devtmpfs, /dev/ttyS0 instead of /dev/ttyVR0, tmpfs on
    #     /tmp + /root because the JFFS2 mtdblock3 partition is read-mostly).
    echo "--- Staging 2.4 inittab + start-opie + pointercal ---"

    # Strip the 4.2.9-era runtime files we're about to overwrite so the
    # JFFS2 image carries the 2.4 variants only.
    rm -f "$OPIE_ROOTFS_DIR/etc/inittab"
    rm -f "$OPIE_ROOTFS_DIR/etc/init.d/rcS"

    mkdir -p "$OPIE_ROOTFS_DIR/etc/init.d" "$OPIE_ROOTFS_DIR/dev/pts" \
             "$OPIE_ROOTFS_DIR/tmp" "$OPIE_ROOTFS_DIR/root" \
             "$OPIE_ROOTFS_DIR/initrd" "$OPIE_ROOTFS_DIR/proc" \
             "$OPIE_ROOTFS_DIR/sys"

    # /initrd is the kernel's move-to point for the old initrd after
    # change_root().  Without this directory, handle_initrd() prints
    # "Change root to /initrd: error -2" and panics with "No init found".
    [[ -d "$OPIE_ROOTFS_DIR/initrd" ]] || mkdir -p "$OPIE_ROOTFS_DIR/initrd"

    cat > "$OPIE_ROOTFS_DIR/etc/inittab" <<'INITTAB'
# BE-300 Linux 2.4.18 + Opie inittab.
# tty0 is the framebuffer console (be300-vtmode will flip it to
# KD_GRAPHICS once start-opie runs).
# ttyS0 is the VRC4173 companion SIU dock UART.  The patched 2.4
# serial_be300 driver programs it as 115200 8N1, asserts DTR/RTS for the
# emulator serial1 bridge, and polls RX into the tty layer. Pair it with:
#   ./bin/be300 ... --serial1-bridge pty:auto
::sysinit:/etc/init.d/rcS
tty0::once:/bin/start-opie
ttyS0::askfirst:/bin/sh
::ctrlaltdel:/sbin/reboot
INITTAB
    if [[ "$BE300_2_4_CONSOLE" == "ttyS0" ]]; then
        sed -i 's|^ttyS0::askfirst:/bin/sh$|# ttyS0 is the kernel console for this build; no askfirst shell here.|' \
            "$OPIE_ROOTFS_DIR/etc/inittab"
    fi

    cat > "$OPIE_ROOTFS_DIR/etc/init.d/rcS" <<'RCSEOF'
#!/bin/sh
# BE-300 Linux 2.4.18 + Opie boot script.
#
# Output goes to the inherited stdout (= /dev/console = tty0/fbcon).
# fbcon renders on the LCD framebuffer; we read it via the emulator
# screenshot path. Keep rcS output off /dev/ttyS0 in the default build so
# the askfirst shell owns the serial link cleanly. /dev/kmsg is a 2.6+
# device and does not exist in 2.4.18.
echo "rcS: mount proc"
mount -t proc proc /proc
echo "rcS: mount devpts"
mount -t devpts devpts /dev/pts
echo "rcS: mount tmpfs /tmp"
mount -t tmpfs tmpfs /tmp
echo "rcS: mount tmpfs /root"
mount -t tmpfs -o size=768k tmpfs /root
echo "rcS: mkdir /root/*"
mkdir -p /root/Settings /root/Applications /root/Documents
export LD_LIBRARY_PATH=/opt/QtPalmtop/lib:/lib
echo "=== Casio BE-300 Linux 2.4.18 (BusyBox + Opie) rcS done ==="
RCSEOF
    chmod 0755 "$OPIE_ROOTFS_DIR/etc/init.d/rcS"
    if [[ "$BE300_2_4_CONSOLE" == "ttyS0" ]]; then
        # Keep the kernel printk console on ttyS0, but avoid mixing rcS
        # progress output with the same serial login path.
        sed -i '/^echo /d' "$OPIE_ROOTFS_DIR/etc/init.d/rcS"
    fi

    # Identity pointercal so Qt's TPanel handler doesn't refuse to start
    # if the user hasn't calibrated yet.
    mkdir -p "$OPIE_ROOTFS_DIR/etc"
    [[ -f "$OPIE_ROOTFS_DIR/etc/pointercal" ]] || \
        echo '1 0 0 0 1 0 1' > "$OPIE_ROOTFS_DIR/etc/pointercal"

    # Use a 2.4-flavored start-opie that enters framebuffer graphics mode
    # and then execs qpe so no resident shell remains in the 16 MiB profile.
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
export QWS_MOUSE_PROTO="${QWS_MOUSE_PROTO:-TPanel:/dev/be300tpanel}"
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
    # files the 4.2.9 build left in $ROOTFS/dev — strip them so --devtable
    # is the sole source of truth.
    rm -rf "$OPIE_ROOTFS_DIR/dev"
    mkdir -p "$OPIE_ROOTFS_DIR/dev"

    # Bare-syscall mount(2) reproducer for diagnosing the rcS proc-mount
    # stall.  Same compile flags as be300_hw_test (line ~336 above); the
    # e_flags rewriter below also touches /usr/bin so the mips32r2 -> mips2
    # metadata fix lands automatically.
    TMP_MOUNT_BIN="$OPIE_ROOTFS_DIR/usr/bin/test_mount_proc"
    mkdir -p "$OPIE_ROOTFS_DIR/usr/bin"
    mipsel-linux-gnu-gcc -march=mips2 -static -nostdlib -nostdinc \
        -fno-pic -mno-abicalls -fomit-frame-pointer -Os -Wall \
        -Wl,--entry=_start \
        -o "$TMP_MOUNT_BIN" "$REPO/board/casio-be300/test_mount_proc.c"
    mipsel-linux-gnu-strip "$TMP_MOUNT_BIN"
    chmod 0755 "$TMP_MOUNT_BIN"

    # Dynamic-link minimal hello-world test.  Built against uClibc-ng
    # (the same libc qpe uses) with normal libc startup.  Goal: isolate
    # whether the qpe pre-main SIGSEGV is general to dynamic-link
    # binaries on 2.4.18 + BE-300, or Qt-specific.
    TMP_DYN_BIN="$OPIE_ROOTFS_DIR/usr/bin/test_dyn_hello"
    /work/mipsel-uclibc-gcc -march=mips2 -O0 -Wall \
        -o "$TMP_DYN_BIN" "$REPO/board/casio-be300/test_dyn_hello.c"
    mipsel-linux-gnu-strip "$TMP_DYN_BIN"
    chmod 0755 "$TMP_DYN_BIN"
    echo "  built test_dyn_hello: $(ls -la "$TMP_DYN_BIN" | awk '{print $5, $9}')"

    # Dynamic-link C++ test with global constructors.  Bisects whether
    # the qpe pre-main SIGSEGV is specific to Qt or general to any C++
    # static-init on this kernel.  Uses the uClibc-ng g++ wrapper.
    TMP_CPP_BIN="$OPIE_ROOTFS_DIR/usr/bin/test_dyn_cpp"
    /work/mipsel-uclibc-g++ -march=mips2 -O0 -Wall \
        -o "$TMP_CPP_BIN" "$REPO/board/casio-be300/test_dyn_cpp.cpp"
    mipsel-linux-gnu-strip "$TMP_CPP_BIN"
    chmod 0755 "$TMP_CPP_BIN"
    echo "  built test_dyn_cpp: $(ls -la "$TMP_CPP_BIN" | awk '{print $5, $9}')"

    # Minimal dynamic-link C++ test linked against libqte.  If libqte's
    # global init is what crashes qpe pre-main, this will reproduce.
    TMP_QTE_BIN="$OPIE_ROOTFS_DIR/usr/bin/test_dyn_qte"
    QTE_LIB_DIR="$OPIE_ROOTFS_DIR/opt/QtPalmtop/lib"
    /work/mipsel-uclibc-g++ -march=mips2 -O0 -Wall \
        -I"$OPIE_ROOTFS_DIR/opt/QtPalmtop/include" \
        -L"$QTE_LIB_DIR" -Wl,-rpath-link,"$QTE_LIB_DIR" \
        -lqte \
        -o "$TMP_QTE_BIN" "$REPO/board/casio-be300/test_dyn_qte.cpp"
    mipsel-linux-gnu-strip "$TMP_QTE_BIN"
    chmod 0755 "$TMP_QTE_BIN"
    echo "  built test_dyn_qte: $(ls -la "$TMP_QTE_BIN" | awk '{print $5, $9}')"

    # Link against ALL libs qpe needs, with --no-as-needed to force
    # NEEDED entries even without referencing symbols.  If a non-qte
    # library's .init crashes, this binary reproduces.
    TMP_FULL_BIN="$OPIE_ROOTFS_DIR/usr/bin/test_dyn_full"
    /work/mipsel-uclibc-g++ -march=mips2 -O0 -Wall \
        -I"$OPIE_ROOTFS_DIR/opt/QtPalmtop/include" \
        -L"$QTE_LIB_DIR" -Wl,-rpath-link,"$QTE_LIB_DIR" \
        -Wl,--no-as-needed \
        -lqpe -lopiecore2 -lopieui2 -lopiesecurity2 -lopiepim2 -lqte \
        -o "$TMP_FULL_BIN" "$REPO/board/casio-be300/test_dyn_full.cpp"
    mipsel-linux-gnu-strip "$TMP_FULL_BIN"
    chmod 0755 "$TMP_FULL_BIN"
    echo "  built test_dyn_full: $(ls -la "$TMP_FULL_BIN" | awk '{print $5, $9}')"
    echo "  built test_mount_proc: $(ls -la "$TMP_MOUNT_BIN" | awk '{print $5, $9}')"

    # Rewrite ELF e_flags arch bits from mips32r2 (0x70000000) to mips2
    # (0x10000000) on every MIPS ELF in the rootfs.  Modern binutils
    # stamps -march=mips2 PIC output with the post-2009 renumbering
    # where 0x70000000 means mips32r2; 2.4.18's elf_check_arch uses the
    # original numbering where that bit pattern means MIPS64 and
    # rejects the binary with ENOEXEC.  The code is actually -march=mips2
    # (the toolchain wrapper forces it); only the metadata field is wrong.
    # Same pattern as the be300_hw_test e_flags patch above.
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

    echo "--- Building JFFS2 image $JFFS2_ROOTFS ---"
    mkfs.jffs2 --root="$OPIE_ROOTFS_DIR" \
        --devtable="$DEVTABLE" \
        --eraseblock=16384 --pagesize=512 --no-cleanmarkers \
        --pad=0xB00000 --little-endian \
        --output="$JFFS2_ROOTFS"
    echo "  rootfs : $(ls -la "$JFFS2_ROOTFS" | awk '{print $5, $9}')"
fi

# 6. Pack into NAND image
echo "--- pack NAND image ---"
PACK_ARGS=( --vmlinux "$BUILT_VMLINUX" --out "$OUT" --build-dir "$SPL_BUILD" )
if [[ -n "$JFFS2_ROOTFS" ]]; then
    PACK_ARGS+=( --rootfs "$JFFS2_ROOTFS" )
fi
python3 "$REPO/tools/pack_legacy_kernel_nand.py" "${PACK_ARGS[@]}"

echo ""
echo "=== Done ==="
ls -l "$OUT"
echo ""
echo "Boot with:"
echo "  ./bin/be300 --nand ${OUT#$REPO/} --speed 0 --detect-stall"
if [[ "$ROOT_MODE" == "opie" ]]; then
    echo ""
    echo "Serial console:"
    echo "  ./bin/be300 --nand ${OUT#$REPO/} --speed 0 --serial1-bridge pty:auto"
    echo "  attach with the printed: screen /dev/ttysXXX 115200,cs8"
    echo ""
    echo "Headless screenshot capture (real-hw 16 MiB SDRAM):"
    echo "  SDL_VIDEODRIVER=dummy BE300_AUTOSTOP_SEC=120 ./bin/be300 --nand ${OUT#$REPO/} --speed 0"
fi
