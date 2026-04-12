# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a cross-compilation environment for building Linux kernels for the Casio Cassiopeia BE-300 PDA. The BE-300 uses a NEC VR4131 CPU (MIPS III, little-endian) with a VRC4173 companion chip for peripherals. Linux 4.2.9 boots to an interactive BusyBox shell on the BE-300 emulator (real hardware has also reached userspace with an earlier assembly-only init).

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
- **setup.c** — `arch_initcall` sets I/O port base, idle override, `prom_putchar()` for early printk via companion UART
- **sfb.c** — Framebuffer driver, directly accesses VRAM at KSEG1 address 0xAA200000 (no ioremap)
- **keys.c** — Polled input driver for the hardware buttons
- **libgcc_helpers.c** — mips2-compiled replacements for libgcc 64-bit helpers (see Toolchain Notes)
- **Makefile** — builds setup.o, sfb.o, keys.o

Test / diagnostic programs (not linked into the kernel):
- **test_c_init.c** — minimal musl C /init used to isolate the COW / data-page bug
- **test_page2.S** — minimal asm init that reads data from the second page to validate EntryLo1

The build script also patches `arch/mips/vr41xx/Kconfig` and `Platform` to add the CASIO_BE300 config option.

### Build Pipeline (build_be300_kernel.sh)

**Phase 0a** — Rebuild musl with `-march=mips2` if `libc.a` still contains SPECIAL2 `mul` (VR4131 is MIPS III — see Toolchain Notes below).

**Phase 0** — Install sanitized Linux UAPI headers (`make headers_install`) for musl into `/work/musl-khdrs`. musl doesn't ship Linux `linux/*.h` UAPI; `uclibc-kernel-headers` can't be used because it lacks the `__UAPI_DEF_*` guards and collides with musl's `netinet/in.h`.

**Phase 1** — Build BusyBox statically linked against musl:
1. `make distclean && defconfig`
2. Disable all networking applets (linux-4.2.9 UAPI headers still have UAPI/libc collisions on `linux/in.h` / `linux/netfilter_ipv4.h`), runit (`BUG_need_to_implement_gettimeofday_ns`), WTMP/UTMP, NFS/RPC, TC, syslogd cfg
3. Patch a private copy of `libgcc.a` (`-B/tmp/libgcc_patched`): strip `_divdi3.o _moddi3.o _udivdi3.o _umoddi3.o _fixdfdi.o _fixunsdfdi.o _floatdidf.o _floatundidf.o _lshrdi3.o _ashldi3.o _ashrdi3.o _negdi2.o` and replace with mips2-compiled `libgcc_helpers.o`
4. `make busybox EXTRA_CFLAGS="-march=mips2 -specs musl-gcc.specs -isystem musl-khdrs/include" EXTRA_LDFLAGS="-specs musl-gcc.specs -B/tmp/libgcc_patched"`
5. Install busybox to `$ROOTFS/bin/busybox`, create applet symlinks, make `/init → /bin/busybox`, write `/etc/inittab` that mounts proc/sys/dev and spawns a shell on tty0

**Phase 2–6** — Kernel build:
1. Download linux-4.2.9-patched.tar.xz from Tiny Core Linux
2. Apply GCC 10+ fixes: yylloc extern, log2.h noreturn/const, -Werror removal
3. Inject board support files and Kconfig patches
4. Configure with `configs/be300_defconfig`, set CONFIG_INITRAMFS_SOURCE
5. Build vmlinux (initramfs is embedded — emulator has no --initrd flag)

### Key Constraints

- **No single source of truth**: Cross-reference all sources (2.4.18 tree, 2.6.x overlays, patches, hardware docs, boot logs, emulator behavior) when making hardware decisions
- **Emulator is strictly 32-bit**: The be300 emulator runs 32-bit MIPS code only. Disassembly of both known-good kernels (2.4.18, 2.6.8.1) confirms zero 64-bit instructions (no sd, ld, daddu, daddiu, dsll, dsrl). The 4.2.9 kernel's dynamically generated `clear_page`/`copy_page` functions use `sd`/`ld` by default because VR4131 reports `cpu_has_64bit_gp_regs=true`. This MUST be disabled — force `clear_word_size=4` and `copy_word_size=4` in `arch/mips/mm/page.c`.
- **Emulator has no --initrd**: Initramfs must be built into vmlinux via CONFIG_INITRAMFS_SOURCE
- **Memory registration**: Common VR41xx `prom_init()` doesn't call `add_memory_region()`. The build script patches it to register 16MB. Do NOT rely solely on `mem=16M` on the cmdline — this has caused the kernel to allocate pages beyond physical RAM (writes to non-existent memory are silently dropped by the emulator, corrupting page tables and file data).
- **serial_be300 is incomplete**: The custom serial TTY driver in the source overlays is unfinished. Use `keep_bootcon` on the kernel cmdline to retain early printk serial output past normal console registration.
- **VR4131 cache bug**: Hit_Writeback_Inv_D must be split into separate writeback + invalidate. The build script patches `flush_dcache_line()` and `protected_writeback_dcache_line()` in `r4kcache.h`. Required for real hardware; also works on the emulator.
- **Userspace ISA — use `-march=mips2`, NOT `mips32`**: VR4131 is MIPS III and does NOT implement the MIPS32 SPECIAL2 opcode space. The SPECIAL2 `mul rd, rs, rt` instruction (which GCC happily emits under `-march=mips32`) raises a Reserved Instruction exception and kills the process with SIGILL. Build musl, BusyBox, and anything else linked into userspace with `-march=mips2`. Binaries compiled with `-nostdlib` additionally need `-mno-abicalls -fno-pic` so `$gp` isn't referenced before crt0 would initialize it.
- **libgcc.a is mips32r2 — patch it**: The Debian `gcc-cross-mipsel-linux-gnu` package's `libgcc.a` was compiled with `-march=mips32r2` and its 64-bit helper routines (`__divdi3`, `__moddi3`, `__udivdi3`, `__umoddi3`, `__fixdfdi`, `__fixunsdfdi`, `__floatdidf`, `__floatundidf`, `__lshrdi3`, `__ashldi3`, `__ashrdi3`, `__negdi2`) contain SPECIAL2 `mul`. The build script creates a patched copy of libgcc.a in `/tmp/libgcc_patched/`, strips those objects, and adds C replacements from `board/casio-be300/libgcc_helpers.c` compiled with `-march=mips2`. Pass `-B/tmp/libgcc_patched` via EXTRA_LDFLAGS so gcc prefers the patched archive. There is no multilib for mips2 (`gcc -print-multi-lib` only lists n32/n64), so rebuilding gcc from source is the only alternative — not worth it.
- **COW bug in build_clear_page patch**: The dynamically-generated `copy_page` was accidentally patched to become `clear_page_simple` by a sed that matched `memset(labels, 0, sizeof(labels));` in both `build_clear_page` and `build_copy_page`. This zeroed the destination of every COW copy, so userspace data-segment pages read as zeros after `padzero` triggered COW. The sed is now scoped to the `build_clear_page` function only (`/^void build_clear_page/,/^void build_copy_page/`).
- **Docker mknod**: Cannot create device nodes in unprivileged Docker; use kernel's initramfs_list.txt format instead
- **simplefb doesn't work**: The mainline `simplefb` driver uses `ioremap_wc()` which doesn't work for the BE300's KSEG1-mapped VRAM. Use the ported `sfb.c` instead, which directly accesses 0xAA200000 as a KSEG1 virtual address.
- **Framebuffer console requires CFB helpers**: `CONFIG_FB_CFB_FILLRECT/COPYAREA/IMAGEBLIT` must be force-selected in Kconfig since no standard driver selects them. The build script adds `select FB_CFB_*` to the CASIO_BE300 Kconfig entry.

### Toolchain Notes

The Debian `gcc-cross-mipsel-linux-gnu` and its sibling `libc6-mipsel-cross` target mips32r2 by default. To target the VR4131 (MIPS III), everything linked into userspace must be built with `-march=mips2` (MIPS II is the highest ISA that neither uses SPECIAL2 nor 64-bit instructions — MIPS III is technically a better fit but `-march=mips3` enables `dmult`/`dsll` etc. that the emulator can't execute). `-march=mips2` produces strict 32-bit MIPS II code that runs on VR4131 and the emulator.

- **musl**: rebuild from source with `CC="mipsel-linux-gnu-gcc -march=mips2"`. Phase 0a of `build_be300_kernel.sh` does this if `musl-mipsel/lib/libc.a` still has `mul` instructions.
- **libgcc**: patched in-place at build time (see `libgcc.a is mips32r2` under Key Constraints).
- **BusyBox**: built with `EXTRA_CFLAGS="-march=mips2 ..."`.
- **Kernel headers for musl**: `make headers_install` into `/work/musl-khdrs`. Do NOT use `uclibc-kernel-headers/` — it predates the `__UAPI_DEF_*` guards and collides with musl's `netinet/in.h`. linux-4.2.9 headers are also old but usable if you only include them for selected applets; the build script disables all networking applets to sidestep residual `linux/in.h` collisions.

### VR41xx TLB Compatibility

Both the emulator and real hardware implement VR41xx TLB, which differs from standard R4000. Do NOT change these to standard R4000 values:
- **PageMask**: VR41xx format (PM_4K=0x1800, not standard 0x0)
- **build_adjust_context**: +2 shift (VR41xx Context.BadVPN2 starts at bit 6, not standard bit 4)
- **EntryLo PFN position**: bit 8 (not standard R4000 bit 6)

The mainline VR41xx `pfn_pte` stores PFN at `PAGE_SHIFT+2` (bit 14), designed for the 2.4-era `_PAGE_GLOBAL` at bit 6. In 4.2.9, `_PAGE_GLOBAL` moved to bit 5, so the build script adjusts to `PAGE_SHIFT+1` to keep PFN aligned at EntryLo bit 8 after the TLB handler's SRL by 5.

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
