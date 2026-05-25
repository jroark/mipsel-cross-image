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
# Default prebuilt kernel donor (override with BE300_2_4_PREBUILT_VMLINUX).
# Used by prebuilt mode AND as the initrd source for the rebuild path's
# ramdisk extract step.
PREBUILT_VMLINUX="${BE300_2_4_PREBUILT_VMLINUX:-$REPO/kernels/vmlinux-2.4}"
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
    pgui)
        # BE300_2_4_UI=pgui sources the rootfs from a prebuilt 2.4 vmlinux
        # that carries a BusyBox + uClibc 0.9.15 + picogui ramdisk at
        # __rd_start..__rd_end (default: $REPO/vmlinux-pgui-test1, override
        # with BE300_2_4_RAMDISK_SRC).  Source-builds a fresh 2.4.18
        # vmlinux with the existing patch series, packs the picogui rootfs
        # onto NAND mtd3 as JFFS2, boots noinitrd root=/dev/mtdblock3.
        ROOT_MODE="pgui"
        OUT="${BE300_2_4_NAND:-$REPO/linux-4.2.9/be300-2_4-pgui.nand}"
        ;;
    mw)
        # BE300_2_4_UI=mw mirrors pgui but with a Microwindows / Nano-X
        # donor (default: $REPO/vmlinux-mw, override with
        # BE300_2_4_RAMDISK_SRC).  The donor ships uClibc 0.9.19, BusyBox,
        # nano-X server, nanowm window manager, and the launcher app menu
        # (~30 Nano-X demo apps in /bin).  Same kernel build, same JFFS2
        # mtd3 packing, same noinitrd cmdline; only the userspace overlay
        # differs from pgui.
        ROOT_MODE="mw"
        OUT="${BE300_2_4_NAND:-$REPO/linux-4.2.9/be300-2_4-mw.nand}"
        ;;
    *)
        echo "ERROR: BE300_2_4_UI must be 'none', 'opie', 'pgui', or 'mw' (got '$BE300_2_4_UI')" >&2
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

if [[ "$ROOT_MODE" != "initrd" && "$ROOT_MODE" != "nand" && "$ROOT_MODE" != "cf" && "$ROOT_MODE" != "opie" && "$ROOT_MODE" != "pgui" && "$ROOT_MODE" != "mw" ]]; then
    echo "ERROR: BE300_2_4_ROOT must be 'initrd', 'nand', 'cf', 'opie', 'pgui', or 'mw' (got '$ROOT_MODE')" >&2
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
# 20-byte gzip-of-empty placeholder used by opie/pgui where the kernel
# does not embed a real initrd (noinitrd cmdline + JFFS2 root) but the
# 2.4 Makefile still link-includes arch/mips/ramdisk/ramdisk.o.  If a
# previous initrd/nand build already populated ramdisk.gz with the
# real linux4be initrd, leave it alone — noinitrd makes the contents
# inert at boot, and not overwriting preserves the file for a later
# switch back to initrd/nand mode.
if [[ "$ROOT_MODE" == "opie" || "$ROOT_MODE" == "pgui" || "$ROOT_MODE" == "mw" ]]; then
    if [[ ! -f "$RAMDISK_GZ" ]]; then
        mkdir -p "$(dirname "$RAMDISK_GZ")"
        printf '\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
            > "$RAMDISK_GZ"
    fi
fi
# pgui/mw: extract the donor ramdisk to a side file (NOT arch/mips/ramdisk/
# ramdisk.gz, because the kernel is built without an embedded initrd —
# the donor rootfs goes to mtd3 JFFS2 in section 5a).  Each mode has its
# own cache so switching between picogui and microwindows donors does not
# fight over the same .gz.  Same default donor convention as picogui:
# mw defaults to $REPO/vmlinux-mw.
if [[ "$ROOT_MODE" == "mw" ]]; then
    PGUI_RAMDISK_SRC="${BE300_2_4_RAMDISK_SRC:-$REPO/vmlinux-mw}"
    PGUI_ROOTFS_GZ="$SOURCE_DIR/.mw-rootfs.gz"
else
    PGUI_RAMDISK_SRC="${BE300_2_4_RAMDISK_SRC:-$REPO/vmlinux-pgui-test1}"
    PGUI_ROOTFS_GZ="$SOURCE_DIR/.pgui-rootfs.gz"
fi
# Sidecar stamp records the source vmlinux that produced the cached
# rootfs blob.  If the user re-runs with a different BE300_2_4_RAMDISK_SRC,
# the cached blob is stale and must be regenerated; without this check,
# switching donors silently packed the previous donor's ramdisk onto the
# new NAND.
PGUI_ROOTFS_STAMP="$PGUI_ROOTFS_GZ.src"
if [[ "$ROOT_MODE" == "pgui" || "$ROOT_MODE" == "mw" ]]; then
    PGUI_CACHED_SRC=""
    [[ -f "$PGUI_ROOTFS_STAMP" ]] && PGUI_CACHED_SRC=$(cat "$PGUI_ROOTFS_STAMP")
    if [[ ! -f "$PGUI_ROOTFS_GZ" || "$PGUI_CACHED_SRC" != "$PGUI_RAMDISK_SRC" ]]; then
        if [[ -f "$PGUI_ROOTFS_GZ" && "$PGUI_CACHED_SRC" != "$PGUI_RAMDISK_SRC" ]]; then
            echo "--- Cached $(basename "$PGUI_ROOTFS_GZ") was from '$PGUI_CACHED_SRC', re-extracting from '$PGUI_RAMDISK_SRC' ---"
            rm -f "$PGUI_ROOTFS_GZ" "$PGUI_ROOTFS_STAMP"
            # Also drop the downstream JFFS2 so the new ramdisk lands on mtd3.
            rm -f "$REPO/linux-4.2.9/rootfs-2_4-pgui.jffs2" "$REPO/linux-4.2.9/rootfs-2_4-mw.jffs2"
        fi
        echo "--- Extracting $ROOT_MODE rootfs from $PGUI_RAMDISK_SRC into $PGUI_ROOTFS_GZ ---"
        [[ -f "$PGUI_RAMDISK_SRC" ]] || { echo "ERROR: $PGUI_RAMDISK_SRC missing" >&2; exit 1; }
        python3 - <<PYEOF
import struct
data = open("$PGUI_RAMDISK_SRC","rb").read()
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
if rd_start is None or rd_end is None:
    raise SystemExit("ERROR: $PGUI_RAMDISK_SRC missing __rd_start/__rd_end symbols")
e_phoff = struct.unpack_from('<I', data, 28)[0]
e_phnum = struct.unpack_from('<H', data, 44)[0]
for i in range(e_phnum):
    o = e_phoff + i*32
    p_type, p_offset, p_vaddr, p_paddr, p_filesz, *_ = struct.unpack_from('<IIIIIIII', data, o)
    if p_type == 1 and p_vaddr <= rd_start < p_vaddr + p_filesz:
        rel = rd_start - p_vaddr
        open("$PGUI_ROOTFS_GZ","wb").write(data[p_offset+rel : p_offset+rel + (rd_end-rd_start)])
        print(f'wrote $PGUI_ROOTFS_GZ ({rd_end-rd_start} bytes)')
        break
PYEOF
        # Record which source vmlinux this cache entry came from so a
        # later run with a different BE300_2_4_RAMDISK_SRC re-extracts
        # instead of silently reusing the wrong donor's ramdisk.
        printf '%s' "$PGUI_RAMDISK_SRC" > "$PGUI_ROOTFS_STAMP"
    fi
    # Defensive size check: picogui ramdisk should be ~520 KiB (4 MiB ext2
    # gzipped). Anything outside [1 KiB, 5 MiB] indicates wrong source or
    # corrupted extraction.
    PGUI_SZ=$(stat -c%s "$PGUI_ROOTFS_GZ" 2>/dev/null || stat -f%z "$PGUI_ROOTFS_GZ")
    if (( PGUI_SZ < 1024 || PGUI_SZ > 5*1024*1024 )); then
        echo "ERROR: $PGUI_ROOTFS_GZ size $PGUI_SZ outside [1024, 5242880] — wrong source vmlinux?" >&2
        exit 1
    fi
fi
if [[ "$ROOT_MODE" != "opie" && "$ROOT_MODE" != "pgui" && "$ROOT_MODE" != "mw" && ! -f "$RAMDISK_GZ" ]]; then
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

if [[ "$ROOT_MODE" != "opie" && "$ROOT_MODE" != "pgui" && "$ROOT_MODE" != "mw" ]]; then

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
elif [[ "$ROOT_MODE" == "pgui" || "$ROOT_MODE" == "mw" ]]; then
    # PicoGUI / Microwindows direct JFFS2 root, same shape as Opie above.
    # The donor rootfs lives on /dev/mtdblock3; the kernel skips initrd via
    # `noinitrd` and the 2.4 Makefile-mandated arch/mips/ramdisk/ramdisk.gz
    # is the 20-byte gzip-of-empty placeholder written in section 3.
    cp "$PROM_C" "$PROM_C.cmdline-bak"
    trap '[[ -f "'"$PROM_C"'.cmdline-bak" ]] && mv "'"$PROM_C"'.cmdline-bak" "'"$PROM_C"'" || true' EXIT
    # ne=0x300,72: force the NE2000 ISA driver to probe port 0x300 with
    # IRQ 72 (= VRC4173_IRQ_BASE + 0, the BE-300 PCMCIA card IRQ; see
    # board/casio-be300/irq.c).  Without this the ne.c probe scans only
    # a small built-in port list and may not hit 0x300 explicitly.
    PGUI_CMDLINE="consoleblank=0 noinitrd root=/dev/mtdblock3 rootfstype=jffs2 init=/sbin/init console=${BE300_2_4_CONSOLE} ne=0x300,72"
    sed -i "s|console=tty0 consoleblank=0 root=/dev/ram rootfstype=ext2 init=/sbin/init|$PGUI_CMDLINE|" "$PROM_C"
    echo "--- patched prom.c for $ROOT_MODE direct JFFS2 root cmdline (${BE300_2_4_CONSOLE}) ---"
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

# Opie/PicoGUI overlay: adds CONFIG_TMPFS/RAMFS/DEVPTS_FS so /etc/init.d/rcS
# can mount tmpfs on /tmp + /root and devpts on /dev/pts before
# /bin/start-opie spawns qpe.  CONFIG_BLK_DEV_INITRD stays on (the kernel
# tree assumes it everywhere — rd_init, real_root_dev,
# setup.c::initrd_start are all unconditionally referenced).  `noinitrd`
# on the cmdline tells the kernel to skip mounting the bogus 20-byte
# placeholder ramdisk at boot, so the 1.25 MiB allocation that was
# happening with the legacy initrd is gone — only the preallocation
# structs remain.  The same overlay is sound for the PicoGUI profile:
# TMPFS/RAMFS/DEVPTS are over-provisioned (picogui's rcS only mounts /proc)
# but harmless, and useful for any post-build inittab tweaks.
if [[ "$ROOT_MODE" == "opie" || "$ROOT_MODE" == "pgui" || "$ROOT_MODE" == "mw" ]]; then
    if [[ -f "$REPO/configs/be300_2_4_opie.config" ]]; then
        echo "--- merging configs/be300_2_4_opie.config for $ROOT_MODE mode ---"
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

# pgui/mw: also merge networking overlay (NETDEVICES + NE2000 ISA driver)
# so the emulator's --ne2000 PCMCIA NE2000 card registers as eth0.
if [[ "$ROOT_MODE" == "pgui" || "$ROOT_MODE" == "mw" ]]; then
    if [[ -f "$REPO/configs/be300_2_4_net.config" ]]; then
        echo "--- merging configs/be300_2_4_net.config for pgui networking ---"
        sed -i \
            -e '/# CONFIG_ISA is not set/d' \
            -e '/# CONFIG_NETDEVICES is not set/d' \
            -e '/# CONFIG_NET_ETHERNET is not set/d' \
            -e '/# CONFIG_NET_ISA is not set/d' \
            -e '/# CONFIG_NE2000 is not set/d' \
            "$SOURCE_DIR/.config"
        grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$REPO/configs/be300_2_4_net.config" \
            >> "$SOURCE_DIR/.config"
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
if [[ ( "$ROOT_MODE" == "opie" || "$ROOT_MODE" == "pgui" || "$ROOT_MODE" == "mw" ) && "$BE300_2_4_CONSOLE" != "ttyS0" ]]; then
    sed -i 's|^CONFIG_SERIAL_BE300_CONSOLE=y$|# CONFIG_SERIAL_BE300_CONSOLE is not set|' \
        "$SOURCE_DIR/.config"
    echo "--- disabled CONFIG_SERIAL_BE300_CONSOLE (clean getty UARTs) ---"
elif [[ "$ROOT_MODE" == "opie" || "$ROOT_MODE" == "pgui" || "$ROOT_MODE" == "mw" ]]; then
    echo "--- keeping CONFIG_SERIAL_BE300_CONSOLE for ttyS0 console ---"
fi
# `yes ""` keeps writing after `make oldconfig` closes its stdin, which raises
# SIGPIPE on yes — with `set -o pipefail` that would fail the whole pipeline
# even though make exited 0. Disable pipefail just for this line so we accept
# yes's 141 if oldconfig succeeded.
( cd "$SOURCE_DIR" && set +o pipefail && yes "" | make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- oldconfig >/dev/null )
( cd "$SOURCE_DIR" && make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- dep >/dev/null 2>&1 )

# 5. Build vmlinux
# Optional: override the kernel -O level (BE300_2_4_KERNEL_O={0|1|s}).
# Useful for chasing gcc-10 vs gcc-3 codegen regressions where the
# default -O2 may miscompile legacy 2.4 source.
if [[ -n "${BE300_2_4_KERNEL_O:-}" ]]; then
    echo "--- overriding kernel -O2 -> -O${BE300_2_4_KERNEL_O} ---"
    sed -i "s|-O2 |-O${BE300_2_4_KERNEL_O} |g" "$SOURCE_DIR/Makefile"
fi
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

# 5a-pgui. Build JFFS2 rootfs from the picogui ramdisk extracted in
# section 3.  Distinct from `nand` mode in two ways: source is the
# .pgui-rootfs.gz side file (NOT $RAMDISK_GZ — the kernel ships the
# 20-byte placeholder), and devtable is the static
# board/casio-be300/be300_2_4_devtable.txt (the picogui ramdisk's /dev
# is mostly symlinks, so a dynamic walk would only emit /dev/tty0 — the
# static table is a superset of what pgserver needs: /dev/fb0, /dev/console,
# /dev/input/event[0-3], /dev/be300tpanel, /dev/mtdblock0..3, etc.).  The
# rdumped /dev/fb -> fb0 symlink resolves against the static /dev/fb0
# char node at runtime, which is exactly what pgserver.conf opens.
if [[ "$ROOT_MODE" == "pgui" ]]; then
    echo "--- Building JFFS2 rootfs from picogui ramdisk contents ---"
    JFFS2_ROOTFS="$REPO/linux-4.2.9/rootfs-2_4-pgui.jffs2"
    DEVTABLE_PGUI="$REPO/board/casio-be300/be300_2_4_devtable.txt"
    [[ -f "$DEVTABLE_PGUI" ]] || { echo "ERROR: $DEVTABLE_PGUI missing" >&2; exit 1; }
    [[ -f "$PGUI_ROOTFS_GZ" ]] || { echo "ERROR: $PGUI_ROOTFS_GZ missing (section 3 should have produced it)" >&2; exit 1; }
    JFFS2_WORK=$(mktemp -d)
    # Chain the prom.c restore (set in section 3b) with rootfs work cleanup.
    trap '[[ -f "'"$PROM_C"'.cmdline-bak" ]] && mv "'"$PROM_C"'.cmdline-bak" "'"$PROM_C"'" || true; rm -rf "'"$JFFS2_WORK"'"' EXIT

    # Decompress the picogui ramdisk and rdump it to a host directory.
    cp "$PGUI_ROOTFS_GZ" "$JFFS2_WORK/rd.gz"
    gunzip -f "$JFFS2_WORK/rd.gz"
    mkdir "$JFFS2_WORK/root"
    debugfs -R "rdump / $JFFS2_WORK/root" "$JFFS2_WORK/rd" >/dev/null

    # Drop the host-fs /dev entries rdump created — they're either zero-byte
    # placeholders for char devs (root can't mknod here under Docker) or
    # regular files masquerading as symlinks.  Non-conflicting symlinks
    # (/dev/fb -> fb0, /dev/ram -> ram1, /dev/std* -> /proc/self/fd/*,
    # /dev/kcore -> /proc/kcore) are kept — they resolve against the
    # devtable-created char nodes at runtime, and pgserver.conf opens
    # /dev/fb specifically.  /dev/tty0 in the picogui ramdisk is a symlink
    # to /dev/tty, but the static devtable creates /dev/tty0 as char 4:0
    # — mkfs.jffs2 errors with "file type does not match specified type"
    # unless we drop the symlink first.  Letting the devtable own /dev/tty0
    # as char 4:0 is semantically equivalent (the symlink target /dev/tty
    # is also char 4:0).
    find "$JFFS2_WORK/root/dev" -maxdepth 1 -type f -delete 2>/dev/null || true
    rm -f "$JFFS2_WORK/root/dev/tty0"

    # Populate omnibar's Applications menu.  omnibar reads *.app files
    # from /usr/share/picogui/appmenu/ and execlp()s the selected one
    # (see picogui-jserv-be300-uclibc/pg1/apps/test/omnibar/omnibar.c).
    # Generate a thin /bin/sh launcher for every picogui app in /usr/bin
    # except the infrastructure binaries (pgserver, pgboard, omnibar)
    # and dev tools (pgmon, resbuild) — and the -ja Japanese variants
    # since the demo rootfs doesn't ship the matching CJK fonts.
    APPMENU="$JFFS2_WORK/root/usr/share/picogui/appmenu"
    mkdir -p "$APPMENU"
    # The 2002 omnibar binary opendir's "demos" (relative to CWD) for
    # the menu listing but builds the exec path as
    # /usr/share/picogui/appmenu/<name>.app.  CWD is "/" (pgserver's
    # CWD inherited via fork), so symlink /demos -> /usr/share/picogui/appmenu
    # to satisfy both halves of the path mismatch with one set of files.
    ln -sf usr/share/picogui/appmenu "$JFFS2_WORK/root/demos"
    SKIP_APPS="pgserver pgboard pgboard_cmds omnibar pgmon resbuild hello-ja textedit-ja"

    # Swap the default session-start app from canvastst (eye-candy demo)
    # to pterm (a useful shell).  /usr/bin/pgstartup is the picogui
    # session script that pgserver execs once at startup; its content
    # is normally /usr/bin/pgboard + /usr/bin/omnibar + /usr/bin/canvastst.
    if [[ -f "$JFFS2_WORK/root/usr/bin/pgstartup" ]]; then
        # Default startup app: atomicnav (the picogui browser).  Networking
        # is configured statically in rcS (10.0.0.1 via gxemul NAT) so
        # the browser can fetch real pages.  pterm and the rest of the
        # demo apps are still available from the Applications menu via
        # the kill-other-normal-apps wrapper (subject to the known
        # 2002-pgserver multi-normal-app limitation).
        sed -i 's|/usr/bin/canvastst.*|/usr/bin/atomicnav \&|' \
            "$JFFS2_WORK/root/usr/bin/pgstartup"
        echo "--- patched pgstartup: canvastst -> atomicnav ---"
    fi

    # The 2002 rootfs ships without /etc/passwd, /etc/group, /etc/profile.
    # Without these, busybox sh's prompt-rendering and pterm's shell
    # subprocess get into degenerate states (id fails, $USER empty,
    # PS1 unset).  Add minimal stubs so a usable shell prompt appears.
    cat > "$JFFS2_WORK/root/etc/passwd" <<'PWD_'
root:x:0:0:root:/:/bin/sh
PWD_
    cat > "$JFFS2_WORK/root/etc/group" <<'GRP_'
root:x:0:
GRP_
    cat > "$JFFS2_WORK/root/etc/profile" <<'PROFILE_'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/
export USER=root
export TERM=xterm
export PS1='# '
PROFILE_
    echo "--- staged /etc/passwd + /etc/group + /etc/profile ---"

    # Patch pgserver.conf to match the BE-300's actual 240x320 portrait
    # framebuffer.  The 2002 demo shipped with width=320 height=256
    # (landscape) which causes some apps to draw widgets beyond the
    # visible area.
    if [[ -f "$JFFS2_WORK/root/etc/pgserver.conf" ]]; then
        sed -i \
            -e 's|^width *=.*|width = 240|' \
            -e 's|^height *=.*|height = 320|' \
            -e 's|^mode *=.*|mode = 240x320x16|' \
            "$JFFS2_WORK/root/etc/pgserver.conf"
        echo "--- patched pgserver.conf to 240x320 portrait ---"
    fi
    for bin in "$JFFS2_WORK/root/usr/bin/"*; do
        [[ -f "$bin" && -x "$bin" && ! -L "$bin" ]] || continue
        # ELF-only
        head -c 4 "$bin" 2>/dev/null | grep -q $'\x7fELF' || continue
        name=$(basename "$bin")
        skip=0
        for s in $SKIP_APPS; do [[ "$name" == "$s" ]] && skip=1 && break; done
        (( skip )) && continue
        cat > "$APPMENU/$name.app" <<APP
#!/bin/sh
# pgserver's managed_rootless appmgr allows only one PG_APP_NORMAL at a
# time.  Kill any currently-running normal app (graceful SIGTERM, wait,
# then SIGKILL if still around), give pgserver a moment to reap the
# client disconnect and clean up the widgets, then launch the new app.
# (Infrastructure: pgboard / omnibar / pgserver / be300_inputbridge are
# omitted — they need to stay alive.)
APPS="atomicnav pterm wclock textedit pgtuxphone scribble \
      dialogdemo canvastst canvastiles bouncyball blackout \
      galaxy gridgame connectfour battleship picomail vrcalc \
      imgview themebar fieldtest hello pqw tpcal pgl-clock \
      pgl-keyboard pgl-launcher pgl-rotate pgl-toolbar"
for p in \$APPS; do killall -TERM "\$p" 2>/dev/null; done
sleep 2
for p in \$APPS; do killall -KILL "\$p" 2>/dev/null; done
sleep 1
exec /usr/bin/$name "\$@" >/tmp/$name.log 2>&1
APP
        chmod 0755 "$APPMENU/$name.app"
    done
    echo "--- omnibar appmenu: $(ls -1 "$APPMENU" | wc -l) entries ---"

    # Optional userspace serial-debug overlay: redirect pgserver stdio to
    # ttyS0 (the VRC4173 SIU dock UART) so the emulator's
    # --serial1-bridge pty:auto path captures pgserver / pgstartup /
    # pgl-launcher messages.  CONFIG_SERIAL_BE300_CONSOLE is already
    # disabled in this profile, so kernel printk does not pollute the
    # UART — pgserver output arrives clean.
    # Build be300_inputbridge: a static client that connects to
    # pgserver, registers as a client-side input filter via
    # PGREQ_MKINFILTER, and forwards kernel evdev events (BE-300 touch +
    # Stowaway keyboard) into pgserver via PGREQ_INFILTERSEND.  The
    # 2002 pgserver binary has no server-side input drivers compiled in
    # (`pgserver -l` shows "Input drivers:" empty), so this bridge is
    # the only way to deliver input without rebuilding it.
    INPUTBRIDGE_BIN="$JFFS2_WORK/root/usr/bin/be300_inputbridge"
    mkdir -p "$(dirname "$INPUTBRIDGE_BIN")"
    # Freestanding build (-nostdlib + raw o32 syscalls): static-glibc
    # binaries don't boot on 2.4.18 (clock_gettime / set_tid_address
    # absent in startup); raw-syscall binaries do.  See
    # tcp_loopback_test.c which uses the same pattern.
    mipsel-linux-gnu-gcc -march=mips2 -static -nostdlib -nostdinc \
        -fno-pic -mno-abicalls -fomit-frame-pointer -fno-builtin \
        -Os -Wall -Wl,--entry=_start \
        -o "$INPUTBRIDGE_BIN" "$REPO/board/casio-be300/be300_inputbridge.c"
    mipsel-linux-gnu-strip "$INPUTBRIDGE_BIN"
    chmod 0755 "$INPUTBRIDGE_BIN"
    # ELF e_flags rewrite (mips32r2 -> mips2) for 2.4.18 elf_check_arch.
    python3 -c "
import struct, sys
p = sys.argv[1]
with open(p, 'rb') as f: d = bytearray(f.read())
ef = struct.unpack_from('<I', d, 36)[0]
new = (ef & ~0xF0000000) | 0x10000000
if new != ef:
    struct.pack_into('<I', d, 36, new)
    open(p, 'wb').write(d)
" "$INPUTBRIDGE_BIN"
    echo "--- built be300_inputbridge $(stat -c%s "$INPUTBRIDGE_BIN" 2>/dev/null || stat -f%z "$INPUTBRIDGE_BIN") bytes ---"

    # Always overlay rcS in pgui mode: original picogui rcS doesn't
    # launch the bridge.  Replacement still launches pgserver but also
    # starts be300_inputbridge after a moment.  Network + loopback
    # route also need to be brought up because BusyBox ifconfig on
    # 2.4.18 doesn't auto-install 127.0.0.0/8 → without the route,
    # libpgui's connect() to 127.0.0.1 ETIMEDOUTs.
    if [[ "${BE300_2_4_PGUI_DEBUG_SERIAL:-0}" == "1" ]]; then
        echo "--- Patching rcS for serial debug (pgserver -> /dev/ttyS0) ---"
        # Add /etc/hosts (clients may gethostbyname()) and an explicit
        # 127.0.0.0/8 route — BusyBox ifconfig on 2.4.18 does NOT auto-
        # install it.
        cat > "$JFFS2_WORK/root/etc/hosts" <<'HOSTS'
127.0.0.1   localhost
HOSTS
        # Build a minimal static TCP-loopback self-test binary
        # (no libc, raw o32 syscalls).  Runs from rcS before pgserver.
        # Result tells us if the kernel TCP stack works on loopback at
        # all — isolating "kernel TCP broken" from "pgserver-specific".
        TCP_TEST_BIN="$JFFS2_WORK/root/usr/bin/tcp_loopback_test"
        mkdir -p "$(dirname "$TCP_TEST_BIN")"
        mipsel-linux-gnu-gcc -march=mips2 -static -nostdlib -nostdinc \
            -fno-pic -mno-abicalls -fomit-frame-pointer -Os -Wall \
            -Wl,--entry=_start \
            -o "$TCP_TEST_BIN" "$REPO/board/casio-be300/tcp_loopback_test.c"
        mipsel-linux-gnu-strip "$TCP_TEST_BIN"
        # Fix ELF e_flags so 2.4.18 elf_check_arch accepts it (modern
        # binutils stamps mips2 PIC output as mips32r2 = 0x70000000).
        python3 -c "
import struct, sys
p = sys.argv[1]
with open(p, 'rb') as f: d = bytearray(f.read())
ef = struct.unpack_from('<I', d, 36)[0]
new = (ef & ~0xF0000000) | 0x10000000
if new != ef:
    struct.pack_into('<I', d, 36, new)
    open(p, 'wb').write(d)
" "$TCP_TEST_BIN"
        chmod 0755 "$TCP_TEST_BIN"
        cat > "$JFFS2_WORK/root/etc/init.d/rcS" <<'RCSDBG'
#!/bin/sh
TTY=/dev/ttyS0
/bin/mount -t proc none /proc
/sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up
/sbin/route add -net 127.0.0.0 netmask 255.0.0.0 lo 2>/dev/null
echo "===== shorten TCP SYN retries to 2 (fast fail) =====" >$TTY
echo 2 > /proc/sys/net/ipv4/tcp_syn_retries 2>$TTY
echo "===== bare TCP self-test (no picogui) =====" >$TTY
/usr/bin/tcp_loopback_test >$TTY 2>&1
echo "(tcp-test exit=$?)" >$TTY
echo "===== /proc/net/snmp =====" >$TTY
cat /proc/net/snmp >$TTY 2>&1
echo "===== /proc/net/dev =====" >$TTY
cat /proc/net/dev >$TTY 2>&1
echo "===== pgserver -l (compiled-in drivers) =====" >$TTY
/usr/bin/pgserver -l >$TTY 2>&1
echo "(pgserver -l exit=$?)" >$TTY

echo "===== pty / devpts state =====" >$TTY
/bin/mount -t devpts devpts /dev/pts 2>$TTY
echo "mount result:" >$TTY; mount >$TTY 2>&1
ls -la /dev/ptmx /dev/pts/ >$TTY 2>&1
echo "===== /bin/sh sanity =====" >$TTY
/bin/sh -c 'echo SHELL_RUNS; id; pwd; echo PATH=$PATH' >$TTY 2>&1
echo "===== bridge sanity: run /usr/bin/be300_inputbridge with pgserver NOT yet started =====" >$TTY
# Bridge should try to connect, retry, and eventually give up.  This
# tells us if (a) it execs at all on 2.4.18, (b) glibc-static startup
# works, (c) it produces any output.
( /usr/bin/be300_inputbridge >$TTY 2>&1 ) &
SOLOPID=$!
sleep 3
echo "===== T+3s bridge still alive? kill -0 $SOLOPID -> =====" >$TTY
if kill -0 $SOLOPID 2>$TTY; then echo "yes" >$TTY; else echo "no, exited" >$TTY; fi
kill $SOLOPID 2>/dev/null
wait $SOLOPID 2>/dev/null
echo "===== launch pgserver + be300_inputbridge for real =====" >$TTY
/usr/bin/pgserver </dev/null >$TTY 2>&1 &
PGSRV=$!
sleep 2
/usr/bin/be300_inputbridge >$TTY 2>&1 &
BRIDGE=$!
sleep 5
echo "===== T+7s state: pgserver alive? bridge alive? =====" >$TTY
kill -0 $PGSRV 2>/dev/null && echo "pgserver alive" >$TTY || echo "pgserver gone" >$TTY
kill -0 $BRIDGE 2>/dev/null && echo "bridge alive" >$TTY || echo "bridge gone" >$TTY
echo "===== /proc/net/tcp =====" >$TTY
cat /proc/net/tcp >$TTY 2>&1
wait $PGSRV
echo "===== pgserver exited =====" >$TTY
RCSDBG
        chmod 0755 "$JFFS2_WORK/root/etc/init.d/rcS"
    else
        # Production pgui rcS: minimal — bring up loopback, start
        # pgserver in background, start input bridge.
        cat > "$JFFS2_WORK/root/etc/hosts" <<'HOSTS'
127.0.0.1   localhost
HOSTS
        # JFFS2 root is mounted read-only, so udhcpc can't write
        # /etc/resolv.conf directly.  Build-time symlink /etc/resolv.conf
        # -> /tmp/resolv.conf (tmpfs at runtime); the udhcpc default
        # script writes to /tmp/resolv.conf instead.
        ln -sf /tmp/resolv.conf "$JFFS2_WORK/root/etc/resolv.conf"

        # Static /etc/hosts so atomicnav can resolve a handful of names
        # without a DNS server (the BE-300 emulator does NAT for TCP
        # but doesn't ship a DNS forwarder).  uClibc 0.9.15 reads
        # /etc/hosts before /etc/resolv.conf.
        cat > "$JFFS2_WORK/root/etc/hosts" <<'HOSTS'
127.0.0.1   localhost
93.184.215.14   example.com
93.184.215.14   www.example.com
1.1.1.1     cloudflare cf one.one.one.one
8.8.8.8     dns google-public-dns
208.67.222.222   opendns
HOSTS
        mkdir -p "$JFFS2_WORK/root/usr/share/udhcpc"
        cat > "$JFFS2_WORK/root/usr/share/udhcpc/default.script" <<'DHCPSCR'
#!/bin/sh
case "$1" in
deconfig)
    /sbin/ifconfig $interface 0.0.0.0
    ;;
bound|renew)
    /sbin/ifconfig $interface $ip netmask $subnet
    [ -n "$router" ] && /sbin/route add default gw "${router%% *}"
    : > /tmp/resolv.conf
    for d in $dns; do echo "nameserver $d" >> /tmp/resolv.conf; done
    ;;
esac
DHCPSCR
        chmod 0755 "$JFFS2_WORK/root/usr/share/udhcpc/default.script"
        cat > "$JFFS2_WORK/root/etc/init.d/rcS" <<'RCSPROD'
#!/bin/sh
/bin/mount -t proc none /proc
# devpts for pterm and any pseudoterminal-using picogui app.  The kernel
# has CONFIG_DEVPTS_FS=y (merged via configs/be300_2_4_opie.config).
/bin/mount -t devpts devpts /dev/pts 2>/dev/null
# tmpfs for /tmp so apps that scratch (textedit, picomail, pterm history)
# don't write to the read-only JFFS2 root.
/bin/mount -t tmpfs -o size=1m tmpfs /tmp 2>/dev/null
# udhcpc writes /tmp/resolv.conf (which /etc/resolv.conf symlinks to).
/sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up
/sbin/route add -net 127.0.0.0 netmask 255.0.0.0 lo 2>/dev/null
# eth0 (NE2000 at 0x300 IRQ 72 via patches 0013 + ne=0x300,72 cmdline).
# This busybox doesn't have udhcpc, so configure statically.  The BE-300
# emulator's user-mode NAT (inherited from gxemul) uses 10.0.0.0/8 with
# gateway/DNS at 10.0.0.254 — NOT QEMU's 10.0.2.x SLIRP defaults.
# Anything else gets dropped with "IP packet not for gateway".  Boot
# with --ne2000 --net-mac 02:de:ad:be:ef:01.
/sbin/ifconfig eth0 10.0.0.1 netmask 255.0.0.0 up 2>/dev/null
/sbin/route add default gw 10.0.0.254 2>/dev/null
echo 'nameserver 10.0.0.254' > /tmp/resolv.conf
echo 'nameserver 8.8.8.8'    >> /tmp/resolv.conf
/usr/bin/pgserver &
PGSRV=$!
/usr/bin/be300_inputbridge </dev/null >/dev/null 2>&1 &
wait $PGSRV
RCSPROD
        chmod 0755 "$JFFS2_WORK/root/etc/init.d/rcS"
    fi

    # Rewrite ELF e_flags arch bits from mips32r2 (0x70000000) to mips2
    # (0x10000000) on every MIPS ELF.  Idempotent: 2002-vintage
    # uClibc-0.9.15 binaries are already in the pre-2009 (0x00000000 or
    # 0x10000000) format so this is a no-op for them; modern toolchain
    # output gets corrected.  Same as the opie path.
    echo "--- Rewriting ELF e_flags arch bits for 2.4.18 elf_check_arch ---"
    python3 - "$JFFS2_WORK/root" <<'PYEOF'
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
            if head[4] != 1 or head[5] != 1:
                continue
            machine = struct.unpack_from('<H', head, 18)[0]
            if machine != 8:
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
    mkfs.jffs2 --root="$JFFS2_WORK/root" \
        --devtable="$DEVTABLE_PGUI" \
        --eraseblock=16384 --pagesize=512 --no-cleanmarkers \
        --pad=0xB00000 --little-endian \
        --output="$JFFS2_ROOTFS"
    echo "  rootfs : $(ls -la "$JFFS2_ROOTFS" | awk '{print $5, $9}')"
fi

# Microwindows / Nano-X profile: BusyBox + uClibc 0.9.19 + nano-X server +
# nanowm + launcher + ~30 Nano-X demo apps in /bin (ntetris, nxclock,
# nxterm, nxkbd, nxmag, ...).  The donor ramdisk is a 2003 linux4be
# microwindows-demo build extracted from vmlinux-mw.
if [[ "$ROOT_MODE" == "mw" ]]; then
    echo "--- Building JFFS2 rootfs from microwindows ramdisk contents ---"
    JFFS2_ROOTFS="$REPO/linux-4.2.9/rootfs-2_4-mw.jffs2"
    DEVTABLE_PGUI="$REPO/board/casio-be300/be300_2_4_devtable.txt"
    [[ -f "$DEVTABLE_PGUI" ]] || { echo "ERROR: $DEVTABLE_PGUI missing" >&2; exit 1; }
    [[ -f "$PGUI_ROOTFS_GZ" ]] || { echo "ERROR: $PGUI_ROOTFS_GZ missing (section 3 should have produced it)" >&2; exit 1; }
    JFFS2_WORK=$(mktemp -d)
    trap '[[ -f "'"$PROM_C"'.cmdline-bak" ]] && mv "'"$PROM_C"'.cmdline-bak" "'"$PROM_C"'" || true; rm -rf "'"$JFFS2_WORK"'"' EXIT

    cp "$PGUI_ROOTFS_GZ" "$JFFS2_WORK/rd.gz"
    gunzip -f "$JFFS2_WORK/rd.gz"
    mkdir "$JFFS2_WORK/root"
    debugfs -R "rdump / $JFFS2_WORK/root" "$JFFS2_WORK/rd" >/dev/null

    # Same /dev cleanup as pgui (rdump fabricates regular files for char
    # devs; the static devtable owns them at runtime).
    find "$JFFS2_WORK/root/dev" -maxdepth 1 -type f -delete 2>/dev/null || true
    # Drop any rdumped symlinks that collide with devtable char nodes.
    rm -f "$JFFS2_WORK/root/dev/tty0" "$JFFS2_WORK/root/dev/fb"

    # The mw donor ships an /etc/profile but no /etc/passwd or /etc/group.
    # Add the same stubs the pgui path uses so `id`, `whoami`, and shell
    # prompt rendering work.  Append to existing profile (preserves the
    # donor's SDL_NOMOUSE=1 / USER=root) instead of clobbering.
    cat > "$JFFS2_WORK/root/etc/passwd" <<'PWD_'
root:x:0:0:root:/:/bin/sh
PWD_
    cat > "$JFFS2_WORK/root/etc/group" <<'GRP_'
root:x:0:
GRP_
    cat >> "$JFFS2_WORK/root/etc/profile" <<'PROFILE_'

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/
export TERM=xterm
export PS1='# '
PROFILE_
    echo "--- staged /etc/passwd + /etc/group + appended /etc/profile ---"

    # Wrapper that nxterm execs as its child.  Forces interactive mode
    # explicitly: busybox sh started by execv("/bin/sh", "/bin/sh", NULL)
    # is non-interactive by default — no PS1, no command echo — even
    # when stdin/stdout are a tty.  Setting up the env in this wrapper
    # also avoids depending on nxterm to call /etc/profile (it doesn't).
    cat > "$JFFS2_WORK/root/usr/bin/mw-shell" <<'SHWRAP'
#!/bin/sh
# /usr/bin precedes /bin in PATH so the ls/grep shims (below) shadow
# the busybox applets and pipe through cat — that makes isatty(stdout)
# false inside busybox, which is what its color-output code keys off.
# Setting TERM=dumb/vt100 doesn't suppress 0.60.5's ls colors; the
# isatty trick does.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/
export USER=root
export TERM=vt100
export PS1='# '
# Print diagnostic banner so we can confirm the shim landed and what
# /bin/ls actually is on this boot.  Goes to stderr (nxterm tty).
echo "=== mw-shell debug ===" 1>&2
echo "/bin/ls -la /bin/ls:" 1>&2
/bin/busybox ls -la /bin/ls 1>&2
echo "head /bin/ls:" 1>&2
/bin/busybox head -3 /bin/ls 1>&2
echo "PATH=$PATH" 1>&2
echo "===" 1>&2
exec /bin/sh -i
SHWRAP
    chmod 0755 "$JFFS2_WORK/root/usr/bin/mw-shell"

    # Patch nxterm's hardcoded window geometry.  The 2003 nxterm binary
    # was built without BE300_TOUCHSCREEN defined, so it uses the source
    # defaults stdcol=80 stdrow=50 (microwindows/src/demos/nanox/nxterm.c
    # lines 75-77), producing a 480x650 px window at 6x13 SystemFixed
    # which is twice the 240x320 LCD in both axes.  The -g flag in the
    # donor binary is advertised but not honored (verified at runtime).
    # Patch the two `li t8, <imm>` instructions in main() that load the
    # initial col/row values:
    #   vaddr 0x406ecc:  ADDIU t8,$0,80  (0x24180050)  -> 38 (0x24180026)
    #   vaddr 0x406fac:  ADDIU t8,$0,50  (0x24180032)  -> 20 (0x24180014)
    # giving a 228x260 px window that fits the LCD with the title bar.
    python3 - "$JFFS2_WORK/root/bin/nxterm" <<'PYEOF'
import struct, sys
p = sys.argv[1]
with open(p, 'rb') as f: d = bytearray(f.read())
e_phoff = struct.unpack_from('<I', d, 28)[0]
e_phnum = struct.unpack_from('<H', d, 44)[0]
def va2off(va):
    for i in range(e_phnum):
        base = e_phoff + i*32
        p_type, p_offset, p_vaddr, _pa, p_filesz, _ms, _f, _a = \
            struct.unpack_from('<IIIIIIII', d, base)
        if p_type == 1 and p_vaddr <= va < p_vaddr + p_filesz:
            return p_offset + (va - p_vaddr)
    raise SystemExit("vaddr 0x%x not in any LOAD segment" % va)
off1 = va2off(0x406ecc)  # stdcol: li t8, 80
off2 = va2off(0x406fac)  # stdrow: li t8, 50
if bytes(d[off1:off1+4]) != b'\x50\x00\x18\x24':
    raise SystemExit("nxterm stdcol pattern at file off 0x%x mismatch: got %s" %
                     (off1, bytes(d[off1:off1+4]).hex()))
if bytes(d[off2:off2+4]) != b'\x32\x00\x18\x24':
    raise SystemExit("nxterm stdrow pattern at file off 0x%x mismatch: got %s" %
                     (off2, bytes(d[off2:off2+4]).hex()))
d[off1] = 0x26  # 80 -> 38
d[off2] = 0x14  # 50 -> 20
open(p, 'wb').write(d)
print("nxterm patched: stdcol 80->38, stdrow 50->20 (window fits 240x320)")
PYEOF

    # Overlay /bin/launcher.cnf with a fuller app set than the donor
    # ships.  Donor stock has Tetris / NanoBreaker / Landmine / Slider /
    # Terminal / Clock / Magnifier / Scribble / SoftKeyboard / Roach /
    # Tux / NXEyes (12 apps).  Add TuxChess, Map (was commented), Image
    # view, Clients, EventTest, TouchCal, Term2 so the user has a
    # tappable entry for every Nano-X app the donor includes.  Apps
    # without a dedicated icon use `-` (per launcher.cnf docs).
    # Shell-wrapper launcher uses to exec apps.  Launching directly
    # via launcher's fork+execvp produces a pc=0 / vaddr=0 TLBL crash
    # for nxterm (same family of bug the picogui session hit — child
    # inherits broken signal disposition or fd state from launcher,
    # and the freshly-exec'd binary jumps to NULL through the bad
    # callback during init).  Inserting an intermediate /bin/sh
    # process gives the child a clean signal mask and reaped fd table
    # before nxterm starts.
    cat > "$JFFS2_WORK/root/usr/bin/mw-launch" <<'LAUN_'
#!/bin/sh
# Wrap with busybox setsid + detach so the target gets a fresh
# session/process-group BEFORE its own setsid call would have
# failed (the cause of the pc=0 TLBL crash on nxterm when launched
# from launcher).  /bin/setsid isn't symlinked in the donor; call
# busybox directly.  Log to /tmp so silent failures are recoverable.
echo "[$(date)] mw-launch $*" >> /tmp/mw-launch.log
( exec /bin/busybox setsid "$@" </dev/null >>/tmp/mw-launch.log 2>&1 ) &
LAUN_
    chmod 0755 "$JFFS2_WORK/root/usr/bin/mw-launch"

    # Populated launcher.cnf.  Skipping:
    #   - $window_background_image: clears LCD with the bg graphic and
    #     hides the panel.
    #   - the Terminal entry: launching nxterm via launcher fork+exec
    #     (even through /bin/sh or a double-forked /usr/bin/mw-launch)
    #     hits a pc=0 / vaddr=0 TLBL crash before nxterm can render its
    #     window.  nxterm launched directly from rcS works fine, so
    #     rcS launches a persistent nxterm instead and the launcher
    #     panel covers everything else.
    # Apps without dedicated icons use `-`.  mw-launch (small daemon-
    # style shell wrapper that double-forks + redirects stdio to
    # /dev/null) is on the wrapper path in case it helps any other
    # apps avoid the same crash.
    # launcher's panel is hardcoded for a screen larger than the BE-300's
    # 240x320 LCD — empirically only 4-6 tiles fit before the panel
    # either renders off-screen or aborts entirely (verified: 3 entries
    # = panel visible, 12 entries = no panel + pc=0 crash).  Cap at 5
    # apps so the panel lays out cleanly.  Terminal omitted since
    # launcher fork+exec of nxterm crashes (rcS launches it directly).
    # 5 verified-working entries.  Terminal is omitted because
    # launcher-fork-of-nxterm crashes at pc=0 TLBL regardless of
    # wrapper / setsid / detach — the 2003 donor wired Terminal into
    # the cnf aspirationally but nxterm was probably only ever launched
    # from /bin/startx on the original distribution.  rcS auto-launches
    # a persistent nxterm so users still have a shell.
    cat > "$JFFS2_WORK/root/bin/launcher.cnf" <<'LAUNCHCNF'
$screensaver_timeout 120

Clock bin/nxclock.pgm bin/nxclock
Tetris bin/ntetris.ppm bin/ntetris
Roach bin/nxroach.pgm bin/nxroach
SoftKbd bin/nxkbd.pgm bin/nxkbd
Tux bin/tux.ppm bin/tux
LAUNCHCNF
    echo "--- overlaid /bin/launcher.cnf with $(grep -cE '^[A-Z]' "$JFFS2_WORK/root/bin/launcher.cnf") app entries ---"

    # Touch bridge — 2003 nano-X has no /dev/input device strings, so
    # it can't read the BE-300 touchscreen on its own.  be300_nxbridge
    # reads /dev/input/event1 (touch — patch 0010 evdev) and forwards
    # via GrInjectPointerEvent over /tmp/.nano-X.  Built freestanding
    # with raw o32 syscalls (same recipe as be300_inputbridge for pgui)
    # so it runs on the 2.4.18 + uClibc 0.9.19 donor rootfs without
    # needing a matching libc toolchain.
    NXBRIDGE_BIN="$JFFS2_WORK/root/usr/bin/be300_nxbridge"
    mkdir -p "$(dirname "$NXBRIDGE_BIN")"
    mipsel-linux-gnu-gcc -march=mips2 -static -nostdlib -nostdinc \
        -fno-pic -mno-abicalls -fomit-frame-pointer -fno-builtin \
        -Os -Wall -Wl,--entry=_start \
        -o "$NXBRIDGE_BIN" "$REPO/board/casio-be300/be300_nxbridge.c"
    mipsel-linux-gnu-strip "$NXBRIDGE_BIN"
    chmod 0755 "$NXBRIDGE_BIN"
    python3 -c "
import struct, sys
p = sys.argv[1]
with open(p, 'rb') as f: d = bytearray(f.read())
ef = struct.unpack_from('<I', d, 36)[0]
new = (ef & ~0xF0000000) | 0x10000000
if new != ef:
    struct.pack_into('<I', d, 36, new)
    open(p, 'wb').write(d)
" "$NXBRIDGE_BIN"
    echo "--- built be300_nxbridge $(stat -c%s "$NXBRIDGE_BIN" 2>/dev/null || stat -f%z "$NXBRIDGE_BIN") bytes ---"

    # ls/grep shims that defeat busybox 0.60.5's color-output detection
    # by piping through cat (forces isatty(stdout)=0 inside busybox, so
    # it omits the SGR escapes nxterm renders literally).  Lighter than
    # a sed-strip pass and works without --color=never (busybox 0.60.5
    # doesn't grok --color args).
    #
    # Replace /bin/ls (a symlink to busybox) directly so the shim is
    # invoked regardless of PATH lookup — an earlier attempt to drop the
    # shim into /usr/bin/ls with /usr/bin first in PATH did not take
    # effect (likely a busybox sh path-hash quirk).  /bin/grep
    # mirrors the pattern.
    rm -f "$JFFS2_WORK/root/bin/ls" "$JFFS2_WORK/root/bin/grep"
    # Use a temp file rather than a pipe — BusyBox 0.60.5 sh's pipeline
    # appears to hang on this kernel/uClibc combination (observed: the
    # ls output truncates partway and the shell never returns to its
    # prompt).  Redirecting to a file still defeats isatty(STDOUT) inside
    # busybox ls, which is what its color code keys off, so colors stay
    # suppressed without the pipe.
    cat > "$JFFS2_WORK/root/bin/ls" <<'LS_'
#!/bin/sh
T=/tmp/.ls.$$
/bin/busybox ls "$@" >$T 2>&1
RC=$?
/bin/busybox cat $T
/bin/busybox rm -f $T
exit $RC
LS_
    chmod 0755 "$JFFS2_WORK/root/bin/ls"
    cat > "$JFFS2_WORK/root/bin/grep" <<'GR_'
#!/bin/sh
T=/tmp/.grep.$$
/bin/busybox grep "$@" >$T 2>&1
RC=$?
/bin/busybox cat $T
/bin/busybox rm -f $T
exit $RC
GR_
    chmod 0755 "$JFFS2_WORK/root/bin/grep"

    # Diagnostic wrapper for the nxterm-rendering question.  Prints a
    # banner BEFORE handing off to /bin/sh -i so we can tell "nxterm is
    # silent because the shell is silent" apart from "nxterm doesn't
    # render output at all".  Each line is also tee'd to a log on tmpfs
    # so the user can recover what was attempted in case the screen
    # stays black.
    cat > "$JFFS2_WORK/root/usr/bin/mw-diag" <<'DIAG'
#!/bin/sh
exec 1>/tmp/mw-diag.out 2>&1
echo "==== mw-diag start ===="
echo "pid=$$  argv0=$0  stdin tty? $(tty 2>/dev/null || echo no)"
echo "uname: $(uname -a)"
echo "ls /:"
ls /
echo "date: $(date)"
echo "TERM=$TERM"
# Now restore stdio to whatever nxterm gave us (re-open the controlling tty).
exec </dev/tty >/dev/tty 2>/dev/tty
cat /tmp/mw-diag.out
echo "==== handing off to /bin/sh -i ===="
export PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/ USER=root TERM=xterm PS1='# '
exec /bin/sh -i
DIAG
    chmod 0755 "$JFFS2_WORK/root/usr/bin/mw-diag"

    # Resolver setup: /etc/resolv.conf -> /tmp/resolv.conf (tmpfs at
    # runtime), and a static /etc/hosts since the emulator NATs TCP but
    # ships no DNS forwarder.  Same content as the pgui path.
    ln -sf /tmp/resolv.conf "$JFFS2_WORK/root/etc/resolv.conf"
    cat > "$JFFS2_WORK/root/etc/hosts" <<'HOSTS'
127.0.0.1   localhost
93.184.215.14   example.com
93.184.215.14   www.example.com
1.1.1.1     cloudflare cf one.one.one.one
8.8.8.8     dns google-public-dns
208.67.222.222   opendns
HOSTS

    # Production mw rcS.  CWD must be "/" when launcher runs because
    # /bin/launcher.cnf references icons + binaries with "bin/..."
    # prefixes (CWD-relative).  Nano-X opens /dev/fb0 directly (already
    # in static devtable as char 29:0) and /dev/tty0 for keyboard input
    # via VT raw-kbd ioctls — both are present.  Touch may not work out
    # of the box: the 2003 nano-X binary contains no /dev/input or
    # /dev/be300tpanel device strings, so its compiled-in mouse driver
    # is probably a stub or expects a legacy device path our 4.2.9-style
    # patch series doesn't create.  Userspace bridge can come later.
    cat > "$JFFS2_WORK/root/etc/init.d/rcS" <<'RCSMW'
#!/bin/sh
/bin/mount -t proc none /proc
/bin/mount -t devpts devpts /dev/pts 2>/dev/null
/bin/mount -t tmpfs -o size=1m tmpfs /tmp 2>/dev/null
/bin/hostname linux4be
/bin/echo "Welcome to Linux4BE (microwindows)"

# Loopback (BusyBox ifconfig 2.4.x does not auto-install 127.0.0.0/8).
/sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up
/sbin/route add -net 127.0.0.0 netmask 255.0.0.0 lo 2>/dev/null

# eth0 (NE2000 at 0x300 IRQ 72 via patches 0013 + ne=0x300,72 cmdline).
# gxemul user-mode NAT: 10.0.0.0/8 with gateway/DNS at 10.0.0.254
# (NOT QEMU 10.0.2.x).  Boot with --ne2000 --net-mac 02:de:ad:be:ef:02.
/sbin/ifconfig eth0 10.0.0.1 netmask 255.0.0.0 up 2>/dev/null
/sbin/route add default gw 10.0.0.254 2>/dev/null
echo 'nameserver 10.0.0.254' > /tmp/resolv.conf
echo 'nameserver 8.8.8.8'    >> /tmp/resolv.conf

# Nano-X expects CWD=/ so launcher.cnf "bin/..." paths resolve.
cd /
# nano-X server: opens /dev/fb0 + /dev/tty0.  -x 240 -y 320 explicitly
# matches the BE-300 LCD geometry; without these flags nano-X 2003 picks
# a default of 320x240 (landscape, palmtop convention) and clients render
# wider than the framebuffer, cutting text off the right edge.  Log to
# /tmp so we can read back why clients fail to connect if the screen
# stays blank.
/bin/nano-X -x 240 -y 320 >/tmp/nano-X.log 2>&1 &
NANOX=$!
# Nano-X creates /tmp/.nano-X (its UNIX-domain socket) once it has
# initialized the screen.  Wait for the socket before launching clients —
# 1-second sleeps weren't long enough; clients failed to connect and
# exited silently, leaving the screen at the nano-X splash.
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S /tmp/.nano-X ] && break
    sleep 1
done
# Window manager.
/bin/nanowm >/tmp/nanowm.log 2>&1 &
sleep 1
# Terminal — full-screen on the 240x320 LCD.  /usr/bin/mw-shell exports
# PS1/TERM/PATH and execs /bin/sh -i.  Requires the BSD pty nodes
# /dev/ptyp0..15 and /dev/ttyp0..15 (added to be300_2_4_devtable.txt) —
# the 2003 nxterm binary hardcodes `/dev/ptyp%d` (no fallback) and was
# silently failing to allocate a pty before those nodes existed.
#
# Empirically the 2003 nxterm IGNORES the `[program {args}]` argv tail
# (verified May 24 2026: mw-shell ran no diagnostics; BusyBox banner
# from /bin/sh -i appeared regardless).  nxterm reads the SHELL env
# var to pick what to launch (strings show `SHELL=` + getenv()), so
# point that at our wrapper.  nxterm also force-sets TERM=vt52 for
# the child; mw-shell re-exports TERM=vt100 to undo that.
export SHELL=/usr/bin/mw-shell
# Touch bridge: /dev/input/event1 -> GrInjectPointerEvent.  Must run
# AFTER nano-X has created /tmp/.nano-X (the bridge retries the connect
# up to 30 x 200 ms internally, but we still gate on the socket file
# above for sanity).
/usr/bin/be300_nxbridge </dev/null >/tmp/nxbridge.log 2>&1 &
# Persistent nxterm from rcS so the user has a guaranteed shell to
# inspect /tmp/mw-launch.log while we debug the launcher-fork-of-
# nxterm crash.
cd /
/bin/nxterm >/tmp/nxterm.log 2>&1 &
sleep 2
# launcher renders the tappable app panel.
/bin/launcher /bin/launcher.cnf >/tmp/launcher.log 2>&1 &
wait $NANOX
RCSMW
    chmod 0755 "$JFFS2_WORK/root/etc/init.d/rcS"

    # ELF e_flags rewrite (mips32r2 -> mips2) — idempotent for 2003
    # binaries which are already pre-2009 format.  Same as pgui path.
    echo "--- Rewriting ELF e_flags arch bits for 2.4.18 elf_check_arch ---"
    python3 - "$JFFS2_WORK/root" <<'PYEOF'
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
            if head[4] != 1 or head[5] != 1:
                continue
            machine = struct.unpack_from('<H', head, 18)[0]
            if machine != 8:
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
    mkfs.jffs2 --root="$JFFS2_WORK/root" \
        --devtable="$DEVTABLE_PGUI" \
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
# Touch is exposed as evdev /dev/input/event1 by patch series 0010
# (touch_be300.c input_dev registration; Makefile keeps stowaway on
# event0). The "/dev/input/" prefix activates the patched Qt
# QVrTPanelHandlerPrivate evdev branch, identical to the 4.2.9 path.
# /dev/be300tpanel still exists as a misc diagnostic node.
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
if [[ "$ROOT_MODE" == "opie" || "$ROOT_MODE" == "pgui" || "$ROOT_MODE" == "mw" ]]; then
    echo ""
    echo "Serial console:"
    echo "  ./bin/be300 --nand ${OUT#$REPO/} --speed 0 --serial1-bridge pty:auto"
    echo "  attach with the printed: screen /dev/ttysXXX 115200,cs8"
    echo ""
    echo "Headless screenshot capture (real-hw 16 MiB SDRAM):"
    echo "  SDL_VIDEODRIVER=dummy BE300_AUTOSTOP_SEC=120 ./bin/be300 --nand ${OUT#$REPO/} --speed 0"
fi
