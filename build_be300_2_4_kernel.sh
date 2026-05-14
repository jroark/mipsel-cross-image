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

echo "=== build_be300_2_4_kernel.sh (rebuild mode) ==="
echo "  source   = $SOURCE_DIR"
echo "  patches  = $PATCH_SERIES"
echo "  out      = $OUT"

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

# 3. Drop the embedded ramdisk into arch/mips/ramdisk/ramdisk.gz
RAMDISK_GZ="$SOURCE_DIR/arch/mips/ramdisk/ramdisk.gz"
if [[ ! -f "$RAMDISK_GZ" ]]; then
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

# 4. Configure
echo "--- make oldconfig ---"
cp "$SOURCE_DIR/config_be300" "$SOURCE_DIR/.config"
( cd "$SOURCE_DIR" && yes "" | make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- oldconfig >/dev/null )
( cd "$SOURCE_DIR" && make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- dep >/dev/null 2>&1 )

# 5. Build vmlinux
echo "--- make vmlinux ---"
( cd "$SOURCE_DIR" && make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- vmlinux )
[[ -f "$BUILT_VMLINUX" ]] || { echo "ERROR: build did not produce $BUILT_VMLINUX" >&2; exit 1; }
mipsel-linux-gnu-size "$BUILT_VMLINUX"

# 6. Pack into NAND image
echo "--- pack NAND image ---"
python3 "$REPO/tools/pack_legacy_kernel_nand.py" \
    --vmlinux "$BUILT_VMLINUX" \
    --out "$OUT" \
    --build-dir "$SPL_BUILD"

echo ""
echo "=== Done ==="
ls -l "$OUT"
echo ""
echo "Boot with:"
echo "  ./bin/be300 --nand ${OUT#$REPO/} --speed 0 --detect-stall"
