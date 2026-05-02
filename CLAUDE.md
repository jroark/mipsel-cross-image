# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a cross-compilation environment for building Linux kernels for the Casio Cassiopeia BE-300 PDA. The BE-300 uses a NEC VR4131 CPU (MIPS III, little-endian) with a VRC4173 companion chip for peripherals. Linux 4.2.9 boots to an interactive BusyBox shell on the BE-300 emulator (real hardware has also reached userspace with an earlier assembly-only init).

## Build Commands

All builds run inside the Docker container. The host mounts the repo at `/work`.

```bash
# Build the Docker cross-compilation image
docker-compose build

# Build the BE-300 kernel (full pipeline: BusyBox + JFFS2 rootfs + kernel)
docker-compose run --rm mips-dev bash -c "./build_be300_kernel.sh"

# Build the optional OPIE NAND images
docker-compose run --rm mips-dev bash -c "./build_be300_opie_nand.sh"
docker-compose run --rm mips-dev bash -c "./build_be300_opie64_nand.sh"

# Build the CompactFlash recovery image after the NAND/rootfs build
docker-compose run --rm mips-dev bash -c "./build_be300_cf_image.sh"

# Build just the Malta/QEMU kernel (simpler, for reference)
docker-compose run --rm mips-dev bash -c "./build_tcl_kernel.sh"

# Test with the BE-300 emulator (run on macOS host, not in Docker).
# The emulator boots only from a NAND image (--nand), CF recovery image
# (--restore --cf), or a positional ROM. The build pipeline produces
# linux-4.2.9/be300.nand and the boot ROM walks its B000FF SPL container
# to load Linux. See "BE-300 boot path" in Key Constraints for details.
./bin/be300 --nand linux-4.2.9/be300.nand --speed 0
./bin/be300 --nand linux-4.2.9/be300-opie.nand --speed 0
./bin/be300 --sdram 64 --nand linux-4.2.9/be300-opie64.nand --speed 0

# Useful debug flags
./bin/be300 --nand linux-4.2.9/be300.nand --speed 0 --log-mmio 2>mmio.log
./bin/be300 --nand linux-4.2.9/be300.nand --detect-stall --mmio-coverage 2>cov.err

# Re-pack a NAND image after vmlinux, SPL, and rootfs.jffs2 already exist
python3 tools/mk_be300_nand.py \
  --vmlinux linux-4.2.9/vmlinux \
  --spl linux-4.2.9/spl_build/spl.elf \
  --rootfs linux-4.2.9/rootfs.jffs2 \
  --out linux-4.2.9/be300.nand
```

Emulator keys: Q=quit, S=screenshot, M=help. Useful flags: `--log-mmio`, `--trace`, `--sfb-5bit-green`, `--speed 0` (unthrottled).

## Kernel Patch Series

The Linux 4.2.9 BE-300 port is carried as a numbered patch series at
`patches/linux-4.2.9/be300/series`. Build scripts apply it with
`scripts/apply_patch_series.sh` after extracting `linux-4.2.9-patched.tar.xz`;
they should not grow new inline `sed`/copy edits for kernel behavior.

The series includes toolchain/UAPI compatibility, BE-300 board support,
VR41xx/VR4131 runtime fixes, and `arch/mips/configs/be300_defconfig`. If a
kernel source change is needed, refresh the relevant patch and `series` entry
rather than editing `linux-4.2.9/` directly.

## Architecture

### Hardware (BE-300)

- **CPU**: NEC VR4131 (uPD30131), MIPS III ISA, 166 MHz, 16KB I-cache + 16KB D-cache
- **Companion chip**: VRC4173 (uPD31173) at 0xAA000000+ handles serial, touchscreen, CF, audio
- **VR4131 peripherals** at 0xAF000000+ (SIU, ICU, CMU, GIU, BCU, PMU, RTC) — these are in mainline Linux
- **RAM**: 16 MB at physical 0x00000000
- **UART**: NEC D89041F1001 on companion chip at 0xAA008680, 4-byte register spacing — NOT an 8250
- **Display**: 240x320, 16bpp at 0xAA200000, stride 512 bytes. hardware.txt says RGB565; original sfb.c used 5-bit green (RGB555)
- **I/O port base**: 0xAA00C000

Reference manuals: `docs/Vr4131-um_200203.pdf`, `docs/Vrc4173.pdf`. Hardware notes: `docs/hardware.txt`, `docs/hw_notes.txt`.

### What Linux 4.2.9 Already Provides

The mainline kernel has mature VR41xx support in `arch/mips/vr41xx/`:
- `common/` — BCU (clocks), CMU, ICU (interrupts), GIU (GPIO), PMU, RTC, SIU (built-in serial), init (prom_init, plat_mem_setup)
- CPU detection in `arch/mips/kernel/cpu-probe.c` (VR4131 = PRID 0x0c80-0x0c83)
- Cache handling in `arch/mips/mm/c-r4k.c`
- Reference boards: casio-e55, ibm-workpad, tanbac (VR4131), zao-capcella (VR4131)

Board support is minimal — just an `arch_initcall` with `set_io_port_base()` (see casio-e55/setup.c as template).

### BE-300 Board Support (board/casio-be300/)

Kernel board support is applied through `patches/linux-4.2.9/be300/`:
- **setup.c** — `arch_initcall` sets I/O port base, idle override, `prom_putchar()` for early printk via companion UART
- **sfb.c** — Framebuffer driver, directly accesses VRAM at KSEG1 address 0xAA200000 (no ioremap)
- **keys.c** — Polled input driver for the hardware buttons
- **nand.c / irq.c / stowaway_serio.c / touch_be300.c** — NAND, GIRQ0 demux, keyboard, and touchscreen support
- **Makefile** — builds the BE-300 board objects

`board/casio-be300/` also holds SPL, CF loader, test, and userspace helper
sources, plus `libgcc_helpers.c` for the mips2 libgcc replacement object.

Test / diagnostic programs (not linked into the kernel):
- **test_c_init.c** — minimal musl C /init used to isolate the COW / data-page bug
- **test_page2.S** — minimal asm init that reads data from the second page to validate EntryLo1

### Build Pipeline (build_be300_kernel.sh)

**Phase 0a** — Rebuild musl with `-march=mips2` if `libc.a` still contains SPECIAL2 `mul` (VR4131 is MIPS III — see Toolchain Notes below).

**Phase 0** — Install sanitized Linux UAPI headers (`make headers_install`) for musl into `/work/musl-khdrs`. musl doesn't ship Linux `linux/*.h` UAPI; `uclibc-kernel-headers` can't be used because it lacks the `__UAPI_DEF_*` guards and collides with musl's `netinet/in.h`.

**Phase 1** — Build BusyBox linked against the BE-300 musl toolchain, populate the selected JFFS2 rootfs source tree (`/work/rootfs_be300/`, `/work/rootfs_be300_opie/`, or `/work/rootfs_be300_opie64/`):
1. `make distclean && defconfig`
2. Keep selected networking applets enabled (`ifconfig`, `route`, `ip`, `udhcpc`, `nslookup`, `ping`) for the NE2000 boot smoke test. Disable only the applets that still need niche kernel headers or unsupported runtime pieces: runit (`BUG_need_to_implement_gettimeofday_ns`), WTMP/UTMP, NFS/RPC, TC, syslogd cfg
3. Patch a private copy of `libgcc.a` (`-B/tmp/libgcc_patched`): strip `_divdi3.o _moddi3.o _udivdi3.o _umoddi3.o _fixdfdi.o _fixunsdfdi.o _floatdidf.o _floatundidf.o _lshrdi3.o _ashldi3.o _ashrdi3.o _negdi2.o` and replace with mips2-compiled `libgcc_helpers.o`
4. `make busybox EXTRA_CFLAGS="-march=mips2 -specs musl-gcc.specs -isystem musl-khdrs/include" EXTRA_LDFLAGS="-specs musl-gcc.specs -B/tmp/libgcc_patched"`
5. Install busybox to `$ROOTFS/bin/busybox`, create applet symlinks, replace `/bin/wget` with `board/casio-be300/be300_wget.c` because the BusyBox 1.24.2 wget applet faults on this target, point `/sbin/init` at busybox, install `/usr/share/udhcpc/default.script`, and write `/etc/inittab`. The default profile starts Microwindows/Nano-X; the OPIE profiles mount `/root` as tmpfs and start `/bin/start-opie` on tty0 while keeping the serial shell on ttyVR0. This tree becomes the JFFS2 image at Phase 7b and is the actual booted root filesystem.
6. For `BE300_UI=opie` and `BE300_UI=opie64`, `board/opie/build_opie_rootfs.sh` builds Qt/Embedded 2.3.10 and OPIE 1.2.5 with MIPS2-only toolchain flags and installs only the selected app/library/picture allowlist. The `opie64` profile also merges `configs/be300_64m.config` and enables extra PIM/tools, Today plugins, input methods, taskbar applets, stock Opie launcher wallpaper defaults via a PNG copy, and a fuller classic Settings tab.

**Phase 2–6** — Kernel build:
1. Download linux-4.2.9-patched.tar.xz from Tiny Core Linux
2. Apply `patches/linux-4.2.9/be300/series`
3. Configure with the patched-in `arch/mips/configs/be300_defconfig`. The kernel cmdline carries `root=/dev/mtdblock3 rootfstype=jffs2 rootwait`, so the kernel mounts JFFS2 from NAND mtd3 directly as `/` — no embedded initramfs.
4. Build vmlinux. `CONFIG_DEVTMPFS_MOUNT=y` causes the kernel to mount devtmpfs over `/dev` before exec'ing `/sbin/init` from the JFFS2 rootfs.

**Phase 7** — Build SPL + JFFS2 + NAND image:
- **7a**: extract `KERNEL_LOAD_VA`/`KERNEL_ENTRY_VA`/`KERNEL_SIZE` from the vmlinux ELF, compile `board/casio-be300/spl_start.S` + `spl.c` + `spl.lds` with those baked in via `-D`, link as `spl.elf`.
- **7b**: `mkfs.jffs2 --root=$ROOTFS --output=linux-4.2.9/<profile-rootfs>.jffs2 --eraseblock=16384 --pagesize=512 --no-cleanmarkers --pad=0xB00000 --little-endian` to package the Phase 1 tree as the mtd3 image.
- **7c**: `tools/mk_be300_nand.py --vmlinux ... --spl ... --rootfs <profile-rootfs>.jffs2 --out linux-4.2.9/<profile>.nand` packs everything into the 16 MiB NAND image (partition table at page 0, SPL B000FF container at `0x4000`, flat kernel binary at `0x14000`, JFFS2 rootfs at `0x500000`).

### CF Image Build (build_be300_cf_image.sh)

`build_be300_cf_image.sh` expects the NAND build to have produced a patched
kernel tree and `rootfs_be300/`. It applies the patch series if the kernel tree
is still clean, merges `configs/be300_cf.config` over `be300_defconfig`, rebuilds
`vmlinux` with the CF root command line, creates an ext2 root partition from the
BusyBox/Nano-X rootfs, builds the CF loader, and packs `linux-4.2.9/linux_cf.img`
with `tools/mk_be300_cf_linux.py`.

### Key Constraints

- **Hardware decisions need cross-checking**: Cross-reference all sources (2.4.18 tree, 2.6.x overlays, patches, hardware docs, boot logs, emulator behavior) when making hardware decisions.
- **BE-300 boot path** (`bin/be300 --nand`): two-stage. The build pipeline emits a 16 MB NAND image with a WinCE-shape partition table at page 0, a stage-1 SPL B000FF container at NAND offset `0x4000` (partition 1), and a flat kernel binary at NAND offset `0x14000` (partition 2). The real BE-300 boot ROM (16 KB blob in `boot_rom_embedded.h` of `/Users/jroark/src/be300-framebuffer`) loads the SPL via its B000FF record walker; the SPL then drives the VRC4173 SPL transfer engine (`0xAA00A4xx` / `0xAA00B000`) to copy the kernel page-by-page into SDRAM and `jr`s to `kernel_entry`. The kernel boots Linux 4.2.9 to the BusyBox shell. Pieces:
  - `board/casio-be300/spl_start.S` + `spl.c` + `spl.lds` — stage-1 SPL, linked at `0x80F00000`. Disables interrupts, sets `sp = 0x80FF0000`, calls `spl_main()`, zeros `a0..a3` (so the kernel's `prom_init` doesn't dereference garbage as cmdline pointers), `jr`s to the kernel entry returned in `v0`.
  - `tools/mk_be300_nand.py` — packs `(spl.elf, vmlinux)` into a 16 MB NAND image. Partition table entries: `[0]=(0, 0x20)`, `[1]=(SPL_OFFSET/512, spl_sectors)`, `[2]=(KERNEL_OFFSET/512, kernel_sectors)`.
  - `build_be300_kernel.sh` Phase 7 — extracts kernel constants (`KERNEL_LOAD_VA`/`KERNEL_ENTRY_VA`/`KERNEL_SIZE`) from `vmlinux` ELF, compiles SPL with those baked in via `-D`, then runs `mk_be300_nand.py`.
  - Kernel link address is `0xffffffff80020000` (PA `0x20000`) — high enough to clear the boot ROM's RAM scratch (`0x80010000`-`0x800102FF`) so SPL writes don't overwrite ROM state mid-walker.

  Confirmed boot-ROM contract (RE'd against `be300_boot_rom.ghidra` via Ghidra HTTP API, function names `FUN_9fc00d7c`/`FUN_9fc00dec`/`FUN_9fc015dc`/`FUN_9fc016b4`/`FUN_9fc00464`):
  1. NAND page 0 holds an 8-entry partition table (16 bytes/entry: `[8 reserved] + start_sector u32 LE + sector_count u32 LE`).
  2. Walker uses entry index 1; the state-2 probe returns "applicable" iff both fields `!= 0xFFFFFFFF` (the MIPS16 `cmpi`+`bteqz` is `T = (rx XOR imm)`).
  3. Records: 7-byte `"B000FF\n"` magic (compared against the copy at RAM `0x80010010`), then `(image_start u32, image_length u32)`, then 12-byte `(addr, len, cksum)` records. Records with `addr != 0` and `len != 0` are copied to `addr | 0x20000000`; `len == 0` records are skipped; `addr == 0` ends the walker and `len` is taken as the entry. `cksum` is NOT validated.
  4. The XFER engine address phase pushes 3 bytes (`col_lo`, `page_lo`, `page_hi`) — sending a fourth byte overflows the 3-byte queue and shifts `col` out. KICK must precede MODE; MODE = `0x05` latches the address into `stream_page`/`stream_col` and sets `ready = true`.
  5. Mailbox handoff: SPL writes `entry` to `*0xA00024FC` and `0x03020101` to `*0xA0002400`; ROM's outer loop polls and `jr`s to the entry value. The ROM does NOT OR `0x20000000` into the entry — that's the SPL's responsibility for the NK handoff in WinCE; for our SPL the kernel runs from the cached KSEG0 alias, which is fine because the SPL writes records via uncached KSEG1.
- **Emulator is strictly 32-bit**: The be300 emulator runs 32-bit MIPS code only. Disassembly of both known-good kernels (2.4.18, 2.6.8.1) confirms zero 64-bit instructions (no sd, ld, daddu, daddiu, dsll, dsrl). The 4.2.9 kernel's dynamically generated `clear_page`/`copy_page` functions use `sd`/`ld` by default because VR4131 reports `cpu_has_64bit_gp_regs=true`. This MUST be disabled — force `clear_word_size=4` and `copy_word_size=4` in `arch/mips/mm/page.c`.
- **vmlinux must fit before the JFFS2 partition**: the flat kernel binary lives at NAND offset `0x14000` and the JFFS2 rootfs starts at `0x500000`, leaving ~4.92 MiB for vmlinux. `tools/mk_be300_nand.py` (lines 183–187) fails the build if this is exceeded; if it ever does, either shrink the kernel or move the rootfs offset (and update the partition table in `board/casio-be300/nand.c` and `tools/mk_be300_nand.py` together).
- **Memory registration**: Common VR41xx `prom_init()` doesn't call `add_memory_region()`. The patch series registers `CONFIG_CASIO_BE300_SDRAM_MB`, default 16MB for stock BE-300 images. The expanded OPIE emulator profile merges `configs/be300_64m.config` and must be booted with `--sdram 64`. Do NOT rely solely on `mem=...` on the cmdline — this has caused the kernel to allocate pages beyond physical RAM (writes to non-existent memory are silently dropped by the emulator, corrupting page tables and file data).
- **serial_be300 is incomplete**: The custom serial TTY driver in the source overlays is unfinished. Use `keep_bootcon` on the kernel cmdline to retain early printk serial output past normal console registration.
- **VR4131 cache bug**: Hit_Writeback_Inv_D must be split into separate writeback + invalidate. The patch series updates `flush_dcache_line()` and `protected_writeback_dcache_line()` in `r4kcache.h`. Required for real hardware; also works on the emulator.
- **Userspace ISA — use `-march=mips2`, NOT `mips32`**: VR4131 is MIPS III and does NOT implement the MIPS32 SPECIAL2 opcode space. The SPECIAL2 `mul rd, rs, rt` instruction (which GCC happily emits under `-march=mips32`) raises a Reserved Instruction exception and kills the process with SIGILL. Build musl, BusyBox, and anything else linked into userspace with `-march=mips2`. Binaries compiled with `-nostdlib` additionally need `-mno-abicalls -fno-pic` so `$gp` isn't referenced before crt0 would initialize it.
- **libgcc.a is mips32r2 — patch it**: The Debian `gcc-cross-mipsel-linux-gnu` package's `libgcc.a` was compiled with `-march=mips32r2` and its 64-bit helper routines (`__divdi3`, `__moddi3`, `__udivdi3`, `__umoddi3`, `__fixdfdi`, `__fixunsdfdi`, `__floatdidf`, `__floatundidf`, `__lshrdi3`, `__ashldi3`, `__ashrdi3`, `__negdi2`) contain SPECIAL2 `mul`. The build script creates a patched copy of libgcc.a in `/tmp/libgcc_patched/`, strips those objects, and adds C replacements from `board/casio-be300/libgcc_helpers.c` compiled with `-march=mips2`. Pass `-B/tmp/libgcc_patched` via EXTRA_LDFLAGS so gcc prefers the patched archive. There is no multilib for mips2 (`gcc -print-multi-lib` only lists n32/n64), so rebuilding gcc from source is the only alternative — not worth it.
- **COW bug in build_clear_page patch**: The dynamically-generated `copy_page` was once accidentally patched to become `clear_page_simple` by a range that matched `memset(labels, 0, sizeof(labels));` in both `build_clear_page` and `build_copy_page`. This zeroed the destination of every COW copy, so userspace data-segment pages read as zeros after `padzero` triggered COW. The patch series changes only `build_clear_page`.
- **Do NOT force per-page D-cache flush in `__update_cache`**: An unconditional `if (1)` replacement of the `exec || pages_do_alias(...)` guard in `arch/mips/mm/cache.c` is a no-op on the emulator (which doesn't simulate the D-cache) but hangs real hardware at `Calibrating delay loop...` — something in the per-page flush path on VR4131 silicon prevents the timer interrupt from delivering, so `jiffies` never advances. An earlier cycle of work hit the same thing ("per-page flush breaks real HW framebuffer"). Leave `__update_cache` at its stock behavior. The real fix for data-page-zeros was keeping the `clear_page_simple` hook out of `build_copy_page`, not this.
- **Docker mknod**: Cannot create device nodes in unprivileged Docker. Not an issue at runtime — the kernel mounts devtmpfs (`CONFIG_DEVTMPFS_MOUNT=y`) over `/dev` on the JFFS2 root before exec'ing `/sbin/init`, so all required device nodes appear dynamically.
- **NAND and `--ne2000` can coexist only via the XFER path**: the legacy NAND DIO ports (`PA 0x0A00D200/D202`) live inside the VRC4173 PCMCIA card window (`0x0A00D000-0x0A00D7FF`). `board/casio-be300/nand.c` therefore drives NAND through the VRC4173 XFER engine (`PA 0x0A00A4xx` / `0x0A00B000`), and `board/casio-be300/setup.c` enables the PCMCIA bridge so CF/NE2000 can own the C000/D000 windows without stealing NAND I/O. Do not reintroduce DIO-backed Linux NAND access unless the emulator decode model is changed with it.
- **simplefb doesn't work**: The mainline `simplefb` driver uses `ioremap_wc()` which doesn't work for the BE300's KSEG1-mapped VRAM. Use the ported `sfb.c` instead, which directly accesses 0xAA200000 as a KSEG1 virtual address.
- **Framebuffer console requires CFB helpers**: `CONFIG_FB_CFB_FILLRECT/COPYAREA/IMAGEBLIT` must be force-selected in Kconfig since no standard driver selects them. The patch series adds `select FB_CFB_*` to the CASIO_BE300 Kconfig entry.

### Toolchain Notes

The Debian `gcc-cross-mipsel-linux-gnu` and its sibling `libc6-mipsel-cross` target mips32r2 by default. To target the VR4131 (MIPS III), everything linked into userspace must be built with `-march=mips2` (MIPS II is the highest ISA that neither uses SPECIAL2 nor 64-bit instructions — MIPS III is technically a better fit but `-march=mips3` enables `dmult`/`dsll` etc. that the emulator can't execute). `-march=mips2` produces strict 32-bit MIPS II code that runs on VR4131 and the emulator.

- **musl**: rebuild from source with `CC="mipsel-linux-gnu-gcc -march=mips2"`. Phase 0a of `build_be300_kernel.sh` does this if `musl-mipsel/lib/libc.a` still has `mul` instructions.
- **libgcc**: patched in-place at build time (see `libgcc.a is mips32r2` under Key Constraints).
- **BusyBox**: built with `EXTRA_CFLAGS="-march=mips2 ..."`.
- **Kernel headers for musl**: `make headers_install` into `/work/musl-khdrs`. Do NOT use `uclibc-kernel-headers/` — it predates the `__UAPI_DEF_*` guards and collides with musl's `netinet/in.h`. linux-4.2.9 headers are also old but usable for the selected BusyBox networking applets needed by the NE2000 DHCP smoke test; `/bin/wget` is the standalone HTTP helper built from `board/casio-be300/be300_wget.c`.

### VR41xx TLB Compatibility

Both the emulator and real hardware implement VR41xx TLB, which differs from standard R4000. Do NOT change these to standard R4000 values:
- **PageMask**: VR41xx format (PM_4K=0x1800, not standard 0x0)
- **build_adjust_context**: +2 shift (VR41xx Context.BadVPN2 starts at bit 6, not standard bit 4)
- **EntryLo PFN position**: bit 8 (not standard R4000 bit 6)

The mainline VR41xx `pfn_pte` stores PFN at `PAGE_SHIFT+2` (bit 14), designed for the 2.4-era `_PAGE_GLOBAL` at bit 6. In 4.2.9, `_PAGE_GLOBAL` moved to bit 5, so the patch series adjusts to `PAGE_SHIFT+1` to keep PFN aligned at EntryLo bit 8 after the TLB handler's SRL by 5.

### Real Hardware Notes

- **D-cache linesize**: 16 bytes (emulator reports 32)
- **TClock**: 41472000Hz (emulator reports 20736000Hz)
- **BogoMIPS**: ~110 (emulator varies)
- **Serial output**: Use `keep_bootcon` on cmdline to retain early printk output via companion UART past console switch. Without a ttyS0 driver, serial goes silent otherwise.
- **Bad page state warnings**: ~19 non-fatal "nonzero mapcount" warnings during `free_all_bootmem` for PFNs near top of RAM (0xe26-0xff1). Kernel continues with ~12MB usable.

### Source Overlays (src/)

CVS repository snapshots from the linux4.be project (2002-2006):
- `linux-latest/kernel-unstable-2.6.x/` — most recent BE-300 board support, drivers, configs
- `linux-latest/kernel-2.6/` — earlier 2.6 board support with debug.c (UART register details)
- `linux4be-2.4.18-20021129/` — full 2.4.18 kernel with BE-300 support

### Known-Good Reference Kernels (kernels/)

- `vmlinux-2.4` (Linux 2.4.18) — boots to userspace, `2.4.log` has sample output
- `vmlinux-2.6` (Linux 2.6.8.1) — boots to userspace, `2.6.log` has sample output

Compare boot output (PClock/VTClock/TClock, CPU revision, memory detection) against these references.
