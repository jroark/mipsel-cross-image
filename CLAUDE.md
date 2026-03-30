# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a cross-compilation environment for porting Linux to the Casio Cassiopeia BE-300 PDA. The BE-300 uses a NEC VR4131 CPU (MIPS III, little-endian) with a VRC4173 companion chip for peripherals. The current effort is porting Linux 4.2.9 to boot to userspace on the BE-300 emulator.

## Build Commands

All builds run inside the Docker container. The host mounts the repo at `/work`.

```bash
# Build the Docker cross-compilation image
docker-compose build

# Build the BE-300 kernel (full pipeline: BusyBox + initramfs + kernel)
docker-compose run --rm mips-dev bash -c "./build_be300_kernel.sh"

# Build just the Malta/QEMU kernel (simpler, for reference)
docker-compose run --rm mips-dev bash -c "./build_tcl_kernel.sh"

# Test with the BE-300 emulator (run on macOS host, not in Docker)
./bin/be300 --kernel linux-4.2.9/vmlinux --cmdline "console=tty0 earlyprintk" --speed 0

# Useful debug flags
./bin/be300 --kernel linux-4.2.9/vmlinux --cmdline "console=tty0 earlyprintk" --speed 0 --log-mmio 2>mmio.log
# Redirect stdout for kernel serial output, stderr for emulator diagnostics:
./bin/be300 --kernel linux-4.2.9/vmlinux --cmdline "console=tty0 earlyprintk" --speed 0 >/tmp/be300_boot.log 2>/tmp/be300_err.log

# Test known-good reference kernels
./bin/be300 --kernel kernels/vmlinux-2.4 --cmdline "console=tty0 root=/dev/ram"
./bin/be300 --kernel kernels/vmlinux-2.6
```

Emulator keys: Q=quit, S=screenshot, M=help. Useful flags: `--log-mmio`, `--trace`, `--sfb-5bit-green`, `--speed 0` (unthrottled).

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

These files are injected into the kernel tree by `build_be300_kernel.sh`:
- **setup.c** — `arch_initcall` sets I/O port base, `prom_putchar()` for early printk via companion UART
- **sfb.c** — Framebuffer driver, directly accesses VRAM at KSEG1 address 0xAA200000 (no ioremap)
- **Makefile** — builds setup.o and sfb.o

The build script also patches `arch/mips/vr41xx/Kconfig` and `Platform` to add the CASIO_BE300 config option.

### Build Pipeline (build_be300_kernel.sh)

1. Build BusyBox with `-march=mips32` (avoids MIPS32r2 instructions the VR4131 can't execute)
2. Create initramfs directory with BusyBox, /init script, /dev nodes via initramfs_list.txt
3. Download linux-4.2.9-patched.tar.xz from Tiny Core Linux
4. Apply GCC 10+ fixes: yylloc extern, log2.h noreturn/const, -Werror removal
5. Inject board support files and Kconfig patches
6. Configure with `configs/be300_defconfig`, set CONFIG_INITRAMFS_SOURCE
7. Build vmlinux (initramfs is embedded — emulator has no --initrd flag)

### Key Constraints

- **No single source of truth**: Cross-reference all sources (2.4.18 tree, 2.6.x overlays, patches, hardware docs, boot logs, emulator behavior) when making hardware decisions
- **Emulator is strictly 32-bit**: The be300 emulator runs 32-bit MIPS code only. Disassembly of both known-good kernels (2.4.18, 2.6.8.1) confirms zero 64-bit instructions (no sd, ld, daddu, daddiu, dsll, dsrl). The 4.2.9 kernel's dynamically generated `clear_page`/`copy_page` functions use `sd`/`ld` by default because VR4131 reports `cpu_has_64bit_gp_regs=true`. This MUST be disabled — force `clear_word_size=4` and `copy_word_size=4` in `arch/mips/mm/page.c`.
- **Emulator has no --initrd**: Initramfs must be built into vmlinux via CONFIG_INITRAMFS_SOURCE
- **Memory registration**: Common VR41xx `prom_init()` doesn't call `add_memory_region()`. The build script patches it to register 16MB. Do NOT rely solely on `mem=16M` on the cmdline — this has caused the kernel to allocate pages beyond physical RAM (writes to non-existent memory are silently dropped by the emulator, corrupting page tables and file data).
- **Emulator address reporting bug**: The emulator reports 263K+ "memory WRITE to non-existant paddr" messages for KSEG0 writes. A C wrapper for `clear_page` confirmed the kernel virtual addresses ARE valid (< 0x81000000). The emulator's physical address computation/reporting is wrong, but the data IS written to the correct location. This is cosmetic — NOT the root cause. Using `--sdram 64` eliminates all reported OOB writes but doesn't fix the userspace crash.
- **serial_be300 is incomplete**: The custom serial TTY driver in the source overlays is unfinished
- **VR4131 cache bug**: Hit_Writeback_Inv_D must be split into separate writeback + invalidate (patches in `patches/`). The build script patches `flush_dcache_line()` and `protected_flush_dcache_line()` in `r4kcache.h`. Note: the emulator may not emulate the instruction cache, so this fix may be irrelevant for emulator testing but is needed for real hardware.
- **BusyBox ISA**: Must not use MIPS32r2 instructions. The toolchain's libc is mips32r2 so `file` will still report "rel2", but BusyBox code uses `-march=mips32` via EXTRA_CFLAGS. Binaries must be compiled with `-mno-abicalls -fno-pic` for `-nostdlib` builds (PIC without libc's crt0 leaves `$gp` uninitialized).
- **Docker mknod**: Cannot create device nodes in unprivileged Docker; use kernel's initramfs_list.txt format instead
- **simplefb doesn't work**: The mainline `simplefb` driver uses `ioremap_wc()` which doesn't work for the BE300's KSEG1-mapped VRAM. Use the ported `sfb.c` instead, which directly accesses 0xAA200000 as a KSEG1 virtual address.
- **Framebuffer console requires CFB helpers**: `CONFIG_FB_CFB_FILLRECT/COPYAREA/IMAGEBLIT` must be force-selected in Kconfig since no standard driver selects them. The build script adds `select FB_CFB_*` to the CASIO_BE300 Kconfig entry.

### Boot Status (as of March 2026)

**BOOTS TO USERSPACE** — The 4.2.9 kernel boots and executes userspace code (test_init.S).

The root cause of the prior userspace failure was a VR41xx `pfn_pte` shift mismatch:
- The VR41xx `pfn_pte` in `pgtable-32.h` stored PFN at `PAGE_SHIFT+2` (bit 14), designed for the 2.4-era PTE layout where `_PAGE_GLOBAL` was at bit 6
- In 4.2.9, `_PAGE_GLOBAL` moved to bit 5, so the TLB handler SRLs by 5 instead of 6
- After SRL by 5, PFN landed at EntryLo bit 9 instead of the VR41xx-correct bit 8
- Result: every user physical address was 2x too high, pointing beyond 16MB RAM
- **Fix**: `sed -i 's/PAGE_SHIFT + 2/PAGE_SHIFT + 1/g' arch/mips/include/asm/pgtable-32.h`

**Important**: The emulator faithfully implements VR41xx TLB hardware. Do NOT change:
- PageMask values (PM_4K=0x1800 is correct for VR41xx)
- build_adjust_context +2 shift (VR41xx Context.BadVPN2 starts at bit 6)
- EntryLo PFN position (VR41xx has PFN at bit 8, not standard R4000 bit 6)

Only the pfn_pte shift needed adjustment to compensate for the _PAGE_GLOBAL bit position change.

### Source Overlays (src/)

CVS repository snapshots from the linux4.be project (2002-2006):
- `linux-latest/kernel-unstable-2.6.x/` — most recent BE-300 board support, drivers, configs
- `linux-latest/kernel-2.6/` — earlier 2.6 board support with debug.c (UART register details)
- `linux4be-2.4.18-20021129/` — full 2.4.18 kernel with BE-300 support

### Known-Good Reference Kernels (kernels/)

- `vmlinux-2.4` (Linux 2.4.18) — boots to userspace, `2.4.log` has sample output
- `vmlinux-2.6` (Linux 2.6.8.1) — boots to userspace, `2.6.log` has sample output

Compare boot output (PClock/VTClock/TClock, CPU revision, memory detection) against these references.
