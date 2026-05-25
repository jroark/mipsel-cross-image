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

# Build the default Microwindows image without Dillo while isolating Nano-X.
docker-compose run --rm mips-dev bash -c "BE300_BUILD_DILLO=0 ./build_be300_kernel.sh"

# Build the experimental dynamic uClibc-ng Microwindows/Dillo image.
docker-compose run --rm mips-dev bash -c "BE300_LIBC=uclibc ./build_be300_kernel.sh"

# Build the optional OPIE NAND images
docker-compose run --rm mips-dev bash -c "./build_be300_opie_nand.sh"
docker-compose run --rm mips-dev bash -c "./build_be300_opie64_nand.sh"

# Build the experimental PicoGUI NAND image (BusyBox + jserv/picogui).
# Defaults to BE300_LIBC=uclibc dynamic linking; pin a real
# board/picogui/git_sha SHA before first run.
docker-compose run --rm mips-dev bash -c "./build_be300_picogui_nand.sh"

# Build the experimental TinyX NAND image (kdrive Xfbdev + matchbox + xterm).
# Defaults to BE300_LIBC=uclibc dynamic linking; pulls X.Org modular
# tarballs from x.org/releases into archives/ on first run.
docker-compose run --rm mips-dev bash -c "./build_be300_tinyx_nand.sh"

# Build the CompactFlash recovery image after the NAND/rootfs build
docker-compose run --rm mips-dev bash -c "./build_be300_cf_image.sh"

# Pack the prebuilt linux4.be reference kernels into bootable NAND images.
# Phase 1 (BE300_2_4_MODE=prebuilt) wraps kernels/vmlinux-2.4 / vmlinux-2.6
# in the existing SPL + B000FF container so they boot on the modern --nand
# emulator path (the old --kernel ELF loader is gone). 2.6 source rebuild
# is a Phase 3 TODO in /Users/jroark/.claude/plans/.
docker-compose run --rm mips-dev bash -c "BE300_2_4_MODE=prebuilt ./build_be300_2_4_kernel.sh"
docker-compose run --rm mips-dev bash -c "./build_be300_2_6_kernel.sh"
./bin/be300 --nand linux-4.2.9/be300-2_4.nand --speed 0 --detect-stall
./bin/be300 --nand linux-4.2.9/be300-2_6.nand --speed 0 --detect-stall

# Phase 2 / 2.5: build 2.4.18 from source with the modern Debian mipsel-linux-gnu
# cross toolchain. Extracts archives/linux4be-2.4.18-20021129.tar.gz to
# linux-2.4.18/, applies patches/linux-2.4.18-be300/series (modern-GCC
# fixes — HI/LO asm constraints, extern-inline conversion, get_user/put_user
# lvalue, __FUNCTION__ string-concat shim, cast-as-lvalue, -mips2/-m4100
# conflict, -fno-stack-protector, ramdisk.o relocatable link, plus the
# Phase-2.5 dead-strip fixes: `__attribute__((used))` on the __init_call /
# __initsetup / __exit_call / __exitdata / __exit / static_unused section
# tags, and an explicit `j _<symbol>` tail jump appended to the
# save_static_function asm wrapper so sys_clone/sys_fork no longer rely on
# linker-order fall-through into their _sys_* C bodies). Reuses the
# original initrd extracted from kernels/vmlinux-2.4's __rd_start..__rd_end,
# builds, and packs as linux-4.2.9/be300-2_4-rebuilt.nand. Status as of
# May 13, 2026: vmlinux builds cleanly with gcc 10.3.0; SPL loads it;
# kernel completes start_kernel(), spawns init/1, runs do_basic_setup,
# all surviving initcalls fire, mounts the embedded initrd as ext2 root,
# frees init memory, and reaches "Algorithmics/MIPS FPU Emulator v1.5" —
# byte-for-byte the same end-of-boot state as kernels/2.4.log. Userspace
# exec apparently runs but the framebuffer console stays black; this is
# now a Phase-2.6 follow-up (likely a CONFIG_NET / driver-set difference
# from the original config_be300, since "Dummy keyboard driver installed"
# replaced the BE-300 serial+kbd drivers).
docker-compose run --rm mips-dev bash -c "./build_be300_2_4_kernel.sh"

# Build a 2.4.18 NAND image whose JFFS2 mtd3 carries the 2002 jserv
# picogui ramdisk extracted from a prebuilt linux4.be kernel. The
# `demo` donor (vmlinux-pgui-demo) has the full picogui app set
# (pgserver, atomicnav, pgboard, omnibar, ~60 apps); the `test1` donor
# (vmlinux-pgui-test1) is the videotest-only minimal cut. Both
# wrappers set BE300_2_4_UI=pgui and source-rebuild the 2.4.18 kernel
# with the modern toolchain + patch series, including patch 0012
# (ip_fast_csum portable C — fixes a gcc 10 inline-asm miscompile
# that broke TCP loopback) and 0013 (VRC4173 PCMCIA bridge enable +
# GIRQ0 cascade drain, lets ne.c probe NE2000 at port 0x300 IRQ 72).
docker-compose run --rm mips-dev bash -c "./build_be300_2_4_pgui_demo_nand.sh"
docker-compose run --rm mips-dev bash -c "./build_be300_2_4_pgui_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-2_4-pgui-demo.nand --speed 0 --ne2000 --net-mac 02:de:ad:be:ef:01

# Build a 2.4.18 NAND image with the 2003 Microwindows/Nano-X
# userspace ramdisk extracted from vmlinux-mw (BusyBox 0.60.5,
# uClibc 0.9.19, nano-X server + nanowm + nxterm + ~30 Nano-X demo
# apps).  Wrapper sets BE300_2_4_UI=mw and BE300_2_4_RAMDISK_SRC=
# /work/vmlinux-mw, reuses the same kernel patch series as pgui +
# adds /dev/ptyp0..15 + /dev/ttyp0..15 BSD pty nodes (nxterm
# hardcodes /dev/ptyp%d) and an mw-specific touch bridge.
docker-compose run --rm mips-dev bash -c "./build_be300_2_4_mw_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-2_4-mw.nand --speed 0 --ne2000 --net-mac 02:de:ad:be:ef:02 --stowaway-keyboard

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
./bin/be300 --nand linux-4.2.9/be300-picogui.nand --speed 0 --detect-stall
./bin/be300 --nand linux-4.2.9/be300-tinyx.nand --speed 0 --detect-stall

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

Emulator keys: Q=quit, S=screenshot, M=help. Useful flags: `--log-mmio`, `--trace`, `--speed 0` (unthrottled).

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
- **Display**: 240x320 visible, RGB565, 16bpp at physical 0x0A200000 / KSEG1 0xAA200000, stride 512 bytes.
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

**Phase 0** — Install sanitized Linux UAPI headers (`make headers_install`) for the target userspace libc into `/work/musl-khdrs`. musl doesn't ship Linux `linux/*.h` UAPI; the old standalone `uclibc-kernel-headers` set can't be used because it lacks the `__UAPI_DEF_*` guards and collides with musl's `netinet/in.h`.

**Phase 0b** — If `BE300_LIBC=uclibc`, build dynamic uClibc-ng 1.0.51 from the local archive, downloading it if missing, into `/work/uclibc-sysroot`, generate `/work/mipsel-uclibc-*` wrapper tools, and install the shared runtime into the rootfs. This path is Microwindows-only; OPIE remains on the musl profile. uClibc-ng builds in Docker `/tmp` because its dynamic build creates both `.os` and `.oS` files, which collide on a case-insensitive macOS workspace.

**Phase 1** — Build BusyBox linked against the selected BE-300 libc toolchain, populate the selected JFFS2 rootfs source tree (`/work/rootfs_be300/`, `/work/rootfs_be300_opie/`, or `/work/rootfs_be300_opie64/`):
1. `make distclean && defconfig`
2. Keep selected networking applets enabled (`ifconfig`, `route`, `ip`, `udhcpc`, `nslookup`, `ping`) for the NE2000 boot smoke test, but trim the 16 MiB browser image hard: no BusyBox wget (replaced below), vi/less/more, nc/telnet/ftp, traceroute, IPv6 applets, netstat/nameif/ipcalc, IPC syslog, large shell history, tab completion, or extra ifconfig/IP tunnel/rule features.
3. Patch a private copy of `libgcc.a` (`-B/tmp/libgcc_patched`): strip `_divdi3.o _moddi3.o _udivdi3.o _umoddi3.o _fixdfdi.o _fixunsdfdi.o _floatdidf.o _floatundidf.o _lshrdi3.o _ashldi3.o _ashrdi3.o _negdi2.o` and replace with mips2-compiled `libgcc_helpers.o`
4. `make busybox EXTRA_CFLAGS="-march=mips2 -Os -fomit-frame-pointer -ffunction-sections -fdata-sections ..." EXTRA_LDFLAGS="-Wl,--gc-sections -Wl,-s ... -B/tmp/libgcc_patched"`
5. Install busybox to `$ROOTFS/bin/busybox`, create the reduced applet symlink set, replace `/bin/wget` with `board/casio-be300/be300_wget.c` because the BusyBox 1.24.2 wget applet faults on this target, point `/sbin/init` at busybox, install `/usr/share/udhcpc/default.script`, and write `/etc/inittab`. The serial shell uses `askfirst` so `/bin/sh` is not resident until requested. This tree becomes the JFFS2 image at Phase 7b and is the actual booted root filesystem.
6. For the default `BE300_UI=microwindows` profile, build the lean Nano-X app set (`nano-X demo-hello nxlaunch nxterm nxkbd nxweb` unless `BE300_MICROWINDOWS_APPS` overrides it), prune large PCF fonts, and install the launcher, terminal, keyboard, and browser wrapper. Set `BE300_INSTALL_DIAGNOSTICS=1` to also copy the framebuffer/touch diagnostic binaries. Unless `BE300_BUILD_DILLO=0` is set, `board/microwindows/build_dillo_rootfs.sh` builds Dillo 3.2.0 with FLTK 1.3.8 over Microwindows NXlib. The runtime `/bin/mw-browser` launches Dillo first and falls back to `/bin/nxweb` when Dillo is missing or `MW_BROWSER_ENGINE=nxweb` is set; when called with an HTTP(S) URL argument, it waits briefly for DHCP to populate `/tmp/resolv.conf` before starting the client. With `BE300_LIBC=uclibc`, BusyBox, Nano-X tools, Dillo, and helper utilities are dynamically linked through `/lib/ld-uClibc.so.0`.
7. For `BE300_UI=opie` and `BE300_UI=opie64`, `board/opie/build_opie_rootfs.sh` builds Qt/Embedded 2.3.10 and OPIE 1.2.5 with MIPS2-only toolchain flags and installs only the selected app/library/picture allowlist. The OPIE profiles mount `/root` as tmpfs and start `/bin/start-opie` on tty0 while keeping the serial shell on ttyVR0 in `askfirst` mode. The `opie64` profile also merges `configs/be300_64m.config` and enables extra PIM/tools, Today plugins, input methods, taskbar applets, stock Opie launcher wallpaper defaults via a PNG copy, and a fuller classic Settings tab.

**Phase 2–6** — Kernel build:
1. Download linux-4.2.9-patched.tar.xz from Tiny Core Linux
2. Apply `patches/linux-4.2.9/be300/series`
3. Overlay `configs/be300_defconfig` plus current board sources into the extracted tree, then configure. The stock NAND/browser config is intentionally lean: no CF/libata/SCSI, ext2/VFAT/NLS, fbcon/logo/fonts, ramdisk, KALLSYMS, devmem, old sysfs syscall, core dumps, AIO, epoll/signalfd/timerfd/eventfd, seccomp, hwrng, BSG/LBDAF, or IPsec XFRM modes. The kernel cmdline carries `root=/dev/mtdblock3 rootfstype=jffs2 rootwait`, so the kernel mounts JFFS2 from NAND mtd3 directly as `/` — no embedded initramfs.
4. Build vmlinux. `CONFIG_DEVTMPFS_MOUNT=y` causes the kernel to mount devtmpfs over `/dev` before exec'ing `/sbin/init` from the JFFS2 rootfs.

**Phase 7** — Build SPL + JFFS2 + NAND image:
- **7a**: extract `KERNEL_LOAD_VA`/`KERNEL_ENTRY_VA`/`KERNEL_SIZE` from the vmlinux ELF, compile `board/casio-be300/spl_start.S` + `spl.c` + `spl.lds` with those baked in via `-D`, link as `spl.elf`.
- **7b**: `mkfs.jffs2 --root=$ROOTFS --output=linux-4.2.9/<profile-rootfs>.jffs2 --eraseblock=16384 --pagesize=512 --no-cleanmarkers --pad=0xB00000 --little-endian` to package the Phase 1 tree as the mtd3 image.
- **7c**: `tools/mk_be300_nand.py --vmlinux ... --spl ... --rootfs <profile-rootfs>.jffs2 --out linux-4.2.9/<profile>.nand` packs everything into the 16 MiB NAND image (partition table at page 0, SPL B000FF container at `0x4000`, flat kernel binary at `0x14000`, JFFS2 rootfs at `0x500000`).

Known-good stock OPIE evidence (May 2, 2026): `docker compose run --rm mips-dev bash -c "./build_be300_opie_nand.sh"` produced `linux-4.2.9/be300-opie.nand` (16 MiB), `rootfs-opie.jffs2` (11 MiB), and `vmlinux` (4.7 MiB). Booting with `./bin/be300 --nand linux-4.2.9/be300-opie.nand --speed 0 --detect-stall` registered `CONFIG_CASIO_BE300_SDRAM_MB=16` / `memory: 01000000 @ 00000000`, detected the Samsung 16 MiB NAND, mounted JFFS2 from `/dev/mtdblock3`, and reached the OPIE launcher.

Known-good Microwindows/Dillo evidence (May 3, 2026): `docker compose run --rm mips-dev bash -c "./build_be300_kernel.sh"` produced `linux-4.2.9/be300.nand` (16 MiB), `rootfs.jffs2` (11 MiB padded), an unpacked `rootfs_be300/` of 3.9 MiB, a stripped static `rootfs_be300/usr/bin/dillo` (1.6 MiB), and a kernel flat payload of `0x2E95AC` bytes (`mipsel-linux-gnu-size linux-4.2.9/vmlinux`: text 2,900,784, data 148,608, bss 80,448). Booting with `./bin/be300 --nand linux-4.2.9/be300.nand --ne2000 --net-mac 02:de:ad:be:ef:01 --speed 0 --detect-stall` registered `memory: 01000000 @ 00000000` with `12980K/16384K available`, detected the Samsung 16 MiB NAND, mounted JFFS2 from `/dev/mtdblock3`, configured DHCP on `eth0`, launched Dillo to `http://example.com/`, and exited with `[BE300_STALL_SUMMARY] fired=0`.

2.4.18 microwindows profile (May 24, 2026, working): `docker compose run --rm mips-dev bash -c "./build_be300_2_4_mw_nand.sh"` produces `linux-4.2.9/be300-2_4-mw.nand` — the source-rebuilt 2.4.18 kernel + the 2003 linux4.be Microwindows/Nano-X demo ramdisk extracted from `vmlinux-mw` (BusyBox 0.60.5, uClibc 0.9.19 dynamic, nano-X server + nanowm + nxterm + the launcher app menu + ~30 Nano-X demo apps: ntetris, nbreaker, landmine, tuxchess, nxclock, nxkbd, nxcal, nxmag, nxroach, nxeyes, world, nxview, scribble, ...). Boot with `./bin/be300 --nand linux-4.2.9/be300-2_4-mw.nand --speed 0 --ne2000 --net-mac 02:de:ad:be:ef:02 --stowaway-keyboard`. Working end-to-end: kernel boot, JFFS2 root, nano-X driving 240×320 LCD, nanowm, the tappable launcher panel with all demo apps, nxterm with interactive shell, Stowaway IR keyboard (via VT keybdev path — `CONFIG_INPUT_KEYBDEV=y` forwards `stowaway_be300` input events to /dev/tty0 which nano-X reads), touch (via `board/casio-be300/be300_nxbridge.c` — raw o32-syscall client that connects to `/tmp/.nano-X` and translates `/dev/input/event1` evdev frames into `GrInjectPointerEvent` requests; protocol cribbed from `microwindows/src/nanox/nxproto.h` and verified against the donor's `libnano-X.so` disassembly), and NE2000 Ethernet (eth0 at 10.0.0.1 via gxemul NAT, same shape as the pgui-demo profile).

Three donor-specific quirks the build script papers over:
- The 2003 nxterm binary hardcodes `/dev/ptyp%d` (no fallback) for BSD pty allocation, so the devtable creates `/dev/ptyp0..15` (major 2) + `/dev/ttyp0..15` (major 3); UNIX98 ptmx alone wasn't enough.
- BusyBox 0.60.5 ls emits SGR colors when `isatty(stdout)` is true and nxterm doesn't process escape codes, so `/bin/ls` is replaced with a tempfile-redirect shim (`>$T 2>&1; cat $T`) — a `|cat` pipe also defeats isatty but the BB 0.60.5 sh pipeline appears to hang on this kernel.
- The donor's nxterm was built without `BE300_TOUCHSCREEN`, so the source defaults `stdcol=80 stdrow=50` make a 480×650 px window — twice the LCD in both axes. The build script binary-patches the two `li t8, <imm>` instructions in `main()` (vaddr 0x406ecc: 80→38, vaddr 0x406fac: 50→20) so the window fits cleanly. Defensive: the patch script verifies the exact `24180050` / `24180032` bytes are present before rewriting.

2.4.18 picogui-demo profile (May 24, 2026, realistic ceiling): `docker compose run --rm mips-dev bash -c "./build_be300_2_4_pgui_demo_nand.sh"` produces `linux-4.2.9/be300-2_4-pgui-demo.nand` — the source-rebuilt 2.4.18 kernel + the 2002 jserv picogui demo ramdisk on JFFS2 mtd3. Boots with `./bin/be300 --nand linux-4.2.9/be300-2_4-pgui-demo.nand --speed 0 --ne2000 --net-mac 02:de:ad:be:ef:01`. Working end-to-end: kernel boot, JFFS2 root, pgserver on the 240x320 LCD, app launchers, pgboard virtual keyboard, pterm, omnibar Applications menu (via `/demos` → `/usr/share/picogui/appmenu` symlink workaround for omnibar's CWD-relative opendir), Stowaway IR keyboard (no modifier passthrough from emulator), touch input via `board/casio-be300/be300_inputbridge.c` (raw o32 syscalls so it runs without libc on 2002 uClibc), NE2000 Ethernet (the emulator's gxemul-derived NAT uses `10.0.0.0/8` with gateway/DNS at `10.0.0.254` — *not* QEMU's 10.0.2.x; rcS configures eth0 statically as 10.0.0.1), and atomicnav fetching real HTTP/HTTPS over the wider internet. **Ceiling**: the 2002 pgserver binary registers `"html"` as a textformat name but ships no `html_load`/`html_save` symbols at all — so atomicnav fetches pages successfully but pgserver falls back to plaintext display of the raw response body. HTML rendering wasn't implemented in this 2002 cut; the patched `html_load_be300` lives in `picogui-jserv-be300-uclibc/pg1/server/widget/textbox_document.c` and is the renderer used by the modern 4.2.9 picogui profile. Multi-app launch from omnibar is also limited: the 2002 `managed_rootless` appmgr only supports one normal app at a time, so the per-launcher kill-others wrapper does not reliably hand off between e.g. atomicnav and pterm. For a usable web browser, use the 4.2.9 picogui profile below instead.

PicoGUI profile (May 9, 2026, in development): `docker compose run --rm mips-dev bash -c "./build_be300_picogui_nand.sh"` produces `linux-4.2.9/be300-picogui.nand` from the BusyBox + jserv/picogui stack. The wrapper sets `BE300_UI=picogui` which selects `ROOTFS=/work/rootfs_be300_picogui`, `rootfs-picogui.jffs2`, and `be300-picogui.nand`, defaults `BE300_LIBC=uclibc` (dynamic; override with `BE300_LIBC=musl` for static), and dispatches to `board/picogui/build_picogui_rootfs.sh`. The picogui source pin lives in `board/picogui/git_sha` (placeholder `0000…` in repo — pin a real jserv commit before first build); the rootfs builder downloads the GitHub archive into `archives/picogui-jserv-<sha12>.tar.gz`, applies `board/picogui/patch_picogui_sources.py` (autoconf modernization + `evdev.c` driver registration), overlays `board/picogui/evdev.c` (new `/dev/input/event*` shim that mirrors `board/microwindows/{mou,kbd}_evdev.c` device-name discovery), `autoreconf -fi`, configures with `--with-config=board/picogui/picogui.config --enable-driver-evdev`, builds the v1 app set (`pgserver`, `pgboard`, `pterm`, `picosm`, `tpcal`), installs into `$ROOTFS`, copies `pgserverrc` + identity calibration into `/etc/picogui/`, and feeds binaries through the same line-1639 `check_rootfs_mips2` opcode scan. Inittab launches `/bin/start-picogui` (heredoc'd in `build_be300_kernel.sh`) on tty0 with `respawn`; the serial shell stays on ttyVR0 in `askfirst`.

TinyX profile (May 10, 2026, in development): `docker compose run --rm mips-dev bash -c "./build_be300_tinyx_nand.sh"` produces `linux-4.2.9/be300-tinyx.nand` from the BusyBox + kdrive Xfbdev + matchbox + terminal stack. The wrapper sets `BE300_UI=tinyx`, which selects `ROOTFS=/work/rootfs_be300_tinyx`, `rootfs-tinyx.jffs2`, and `be300-tinyx.nand`, defaults `BE300_LIBC=uclibc` (dynamic; override with `BE300_LIBC=musl` for static), applies `configs/be300_tinyx.config` for `/dev/mem`, and dispatches to `board/tinyx/build_tinyx_rootfs.sh`. Versions for the X.Org modular library stack are pinned in `board/tinyx/xorg_versions` (xproto..pixman..xorg-server-1.6.5..matchbox-window-manager-1.2..rxvt-2.7.10 by default, xterm-253 optional); the rootfs builder caches each tarball under `archives/` and stages headers and intermediate libraries into `/tmp/xorg-stage` before installing the runtime into `$ROOTFS`. `board/tinyx/patch_xorg_sources.py` modernizes the 1.6.x autoconf tree (`configure.in` → `configure.ac`, `AM_CONFIG_HEADER` → `AC_CONFIG_HEADERS`, drops dead `config-hal`/`config-udev` requires), fixes XACE callback-record lifetime, and patches kdrive evdev so BE-300 ABS_X/ABS_Y plus BTN_TOUCH becomes absolute pointer input; libXfont builds `--disable-freetype --enable-builtins --disable-fc` so only PCF bitmaps are linked. A host xkbcomp compiles `board/tinyx/keymap.us.xkb` to `/usr/share/X11/xkb/compiled/us.xkm` for future full-XKB experiments, but runtime currently uses `-kb` to avoid target-side xkbcomp. Inittab launches `/bin/start-tinyx` (heredoc'd in `build_be300_kernel.sh`) on tty0 with `respawn`; the launcher starts `/bin/be300-fbrefresh` to dirty emulator framebuffer mmap writes, pins evdev nodes by device-name like the Microwindows drivers, starts `Xfbdev :0 -fb /dev/fb0 -ac -kb -noreset -wr -mouse evdev,,device=/dev/input/eventN,rawcoord -keybd evdev,,device=/dev/input/eventM`, waits for the X socket, launches matchbox, spawns `/usr/bin/be300-xstatus` as the persistent visible client (banner + clock + uptime + eth0 IP, source at `board/tinyx/be300_xstatus.c`), and respawns a terminal running `/bin/sh` with an exponential backoff that gives up after 5 fast-exit failures (`be300-xstatus` remains on screen if the terminal can't come up). rxvt-2.7.10 is built with `--disable-shared --enable-static` so its `librxvt.la` folds into the rxvt binary instead of producing a separate `librxvt.so.1` — `readelf -d` confirms the runtime rxvt links only `libX11.so.6` + `libc.so.0`, matching matchbox's link footprint. The serial shell stays on ttyVR0 in `askfirst`; boot with `--stowaway-keyboard` to enable the hardware keyboard path.

Known-good TinyX evidence (May 13, 2026): `docker compose run --rm mips-dev bash -c "./build_be300_tinyx_nand.sh"` produces `linux-4.2.9/be300-tinyx.nand` (16 MiB), `rootfs-tinyx.jffs2` (11 MiB padded), Xfbdev (1.2 MiB stripped), `be300-xstatus` (9.3 KiB), and rxvt-2.7.10 (78 KiB stripped, `librxvt.so.1` folded in by `--disable-shared --enable-static`). T20 mips2 opcode scan is clean. Boot with `./bin/be300 --sdram 64 --nand linux-4.2.9/be300-tinyx.nand --speed 0 --detect-stall` — the `--sdram 64` is required because the stack OOM-kills Xfbdev at 13 MiB usable. The kernel boots, JFFS2 mounts, `/bin/start-tinyx` launches, `Xfbdev :0` initializes after ~360 emulator ticks, `matchbox-window-manager` connects and configures keyboard shortcuts, `be300-xstatus` maps a 240x320 fullscreen window that renders the "BE-300 TinyX" banner + a 1 Hz live clock from `time(2)` + uptime from `sysinfo()` + the eth0 IP address (or "ip none"), and `/usr/bin/rxvt` runs `/bin/tinyx-shell` showing the `be300#` BusyBox prompt and an X11 I-beam cursor. Screenshots `screenshot_20260513_093954.bmp` / `_094425.bmp` show the matchbox-stacked banner + terminal on the LCD. `[BE300_STALL_SUMMARY] fired=0` on exit. The terminal respawn loop defaults on (set `BE300_TINYX_ENABLE_TERMINAL=0` to revert to the banner-only steady state); Xfbdev has been observed to SIGSEGV inside `BlockHandler` after 40–50 seconds of dispatch-loop activity, after which the launcher respawns rxvt but the X server stays down — a residual MIPS PIC codegen issue on this build, not blocking interactive use of a single session.

Three changes were needed to get the X server through its first dispatch loop iteration on uClibc-ng MIPS PIC: (a) `board/tinyx/patch_xorg_sources.py::patch_disable_smart_schedule` defaults `Bool SmartScheduleDisable = TRUE` in `dix/dispatch.c` — the SmartScheduleClient call between `WaitForSomething()` and `ReadRequestFromClient()` was the trigger for a function-pointer reload landing at 0; (b) `patch_os_io_local_binding` was extended to mark `ReadRequestFromClient` and `InsertFakeRequest` hidden in both `include/os.h` and `os/io.c` so the calls bind locally; (c) `board/tinyx/build_tinyx_rootfs.sh::build_xorg_server` passes `-Wl,-Bsymbolic-functions` and `configs/be300_tinyx.config` now declares `CONFIG_CASIO_BE300_SDRAM_MB=64`.

Known-good dynamic uClibc-ng evidence (May 3, 2026): `docker compose run --rm mips-dev bash -c "BE300_LIBC=uclibc ./build_be300_kernel.sh"` produced `linux-4.2.9/be300.nand` (16 MiB), `rootfs.jffs2` (11 MiB padded), an unpacked `rootfs_be300/` of 3.4 MiB, dynamic `rootfs_be300/usr/bin/dillo` (1.4 MiB), `rootfs_be300/lib/libuClibc-1.0.51.so` (540 KiB), and the same `0x2E95AC` kernel flat payload. `readelf` showed `/lib/ld-uClibc.so.0` as the interpreter and `Tag_GNU_MIPS_ABI_FP: Soft float` for BusyBox, Nano-X tools, Dillo, and the uClibc runtime. The final binary scan found no VR4131-unsupported integer opcodes, and a targeted scan confirmed the previous crash word `00151001` was absent from Dillo, BusyBox, and `libuClibc-1.0.51.so`. After the Stowaway URL-entry and uClibc DNS-service patches, the rebuilt rootfs launches `/bin/mw-browser` blank by default, Dillo's `src/ui.cc` contains the fallback that focuses the location entry for the first unhandled printable key plus an explicit URL-entry Enter handler, Dillo's `src/dns.c` passes service `"80"` to `getaddrinfo()`, and the opcode scan remains clean. A temporary diagnostic NAND booted with `--ne2000 --net-mac 02:de:ad:be:ef:08 --speed 0 --detect-stall`, configured DHCP on `eth0`, and confirmed `/bin/wget -T 25 -O /tmp/frogfind.html http://frogfind.com/` fetched a 1163-byte response without a stall.

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
- **Default NAND kernel is browser-lean, not CF-capable**: `configs/be300_defconfig` optimizes the stock 16 MiB NAND image for Dillo/Nano-X headroom. CF/libata/SCSI, ext2/VFAT/NLS, fbcon/logo/fonts, ramdisk, KALLSYMS, devmem, core dumps, AIO, epoll/signalfd/timerfd/eventfd, seccomp, hwrng, BSG/LBDAF, and IPsec XFRM modes are out of the default kernel. Use `build_be300_cf_image.sh`, which merges `configs/be300_cf.config`, when the CF recovery/root path is the target.
- **Memory registration**: Common VR41xx `prom_init()` doesn't call `add_memory_region()`. The patch series registers `CONFIG_CASIO_BE300_SDRAM_MB`, default 16MB for stock BE-300 images. The expanded OPIE emulator profile merges `configs/be300_64m.config` and must be booted with `--sdram 64`. Do NOT rely solely on `mem=...` on the cmdline — this has caused the kernel to allocate pages beyond physical RAM (writes to non-existent memory are silently dropped by the emulator, corrupting page tables and file data).
- **serial_be300 is incomplete**: The custom serial TTY driver in the source overlays is unfinished. Use `keep_bootcon` on the kernel cmdline to retain early printk serial output past normal console registration.
- **VR4131 cache bug**: Hit_Writeback_Inv_D must be split into separate writeback + invalidate. The patch series updates `flush_dcache_line()` and `protected_writeback_dcache_line()` in `r4kcache.h`. Required for real hardware; also works on the emulator.
- **Userspace ISA — use `-march=mips2`, NOT `mips32`**: VR4131 is MIPS III and does NOT implement the MIPS32 SPECIAL2 opcode space. The SPECIAL2 `mul rd, rs, rt` instruction (which GCC happily emits under `-march=mips32`) raises a Reserved Instruction exception and kills the process with SIGILL. Build musl, BusyBox, and anything else linked into userspace with `-march=mips2`. Binaries compiled with `-nostdlib` additionally need `-mno-abicalls -fno-pic` so `$gp` isn't referenced before crt0 would initialize it.
- **libgcc.a is mips32r2 — patch it**: The Debian `gcc-cross-mipsel-linux-gnu` package's `libgcc.a` was compiled with `-march=mips32r2`; its 64-bit helper routines (`__divdi3`, `__moddi3`, `__udivdi3`, `__umoddi3`, `__fixdfdi`, `__fixunsdfdi`, `__floatdidf`, `__floatundidf`, `__lshrdi3`, `__ashldi3`, `__ashrdi3`, `__negdi2`) contain SPECIAL2 `mul`, and its float/double comparison helpers can contain MIPS32 conditional moves (`movf`/`movt`). The build script creates a patched copy of libgcc.a in `/tmp/libgcc_patched/`, strips those objects, and adds C replacements from `board/casio-be300/libgcc_helpers.c` compiled with `-march=mips2`. Pass `-B/tmp/libgcc_patched` via EXTRA_LDFLAGS so gcc prefers the patched archive. There is no multilib for mips2 (`gcc -print-multi-lib` only lists n32/n64), so rebuilding gcc from source is the only alternative — not worth it.
- **uClibc-ng dynamic profile**: `BE300_LIBC=uclibc` selects uClibc-ng 1.0.51, not the unmaintained 2012 uClibc tree. It is built with a soft-float ABI because Microwindows and Dillo contain floating-point code. The Debian cross compiler has no soft-float multilib, so link warnings about `crtbegin.o`, `crtend.o`, and some `libgcc.a` members being tagged hard-float are expected; some libgcc/math helper paths can still contain FPU opcodes and rely on Linux/MIPS math emulation if reached. Dillo launch previously tripped `movt` from libgcc's double-compare helper, so the rootfs build now scans installed executables/shared libraries for unsupported VR4131 integer opcodes. Dillo's DNS path also passes service `"80"` to `getaddrinfo()` because the uClibc-ng NULL-service resolver path hung under Dillo; Dillo ignores the returned port, and this matches the known-working `/bin/wget` helper behavior. Treat the final `readelf -A` attributes and unsupported-instruction scan as the verification source.
- **Microwindows Dillo uses NXlib, not full X11**: `board/microwindows/config.be300` enables `NX11=Y` and installs `rgb.txt` at `/usr/share/microwindows/rgb.txt` for NXlib color-name lookup. FLTK is patched with Microwindows' `patch-fltk-1.3.8`, plus a BE-300 opaque-region patch because NXlib stores `Region` server-side and FLTK's masked pixmap path otherwise dereferences `Region->rects` and crashes in `Fl_Xlib_Graphics_Driver::draw(Fl_Pixmap*)`. Keep `BE300_NXLIB_OPAQUE_REGION` on the FLTK library build unless NXlib grows client-side region rectangles.
- **Stowaway keyboard focus is Nano-X focus**: FLTK can focus Dillo's URL widget after a tap while Nano-X still routes hardware key events to the previously focused client. `build_be300_kernel.sh` patches Nano-X `srvevent.c` so button-down first moves keyboard focus to the visible window under the pointer that accepts key-down events, and patches NanoWM `wmevents.c` so client button-down also calls `GrSetFocus(window->wid)` while still delivering the click. `board/microwindows/build_dillo_rootfs.sh` also patches Dillo so the first unhandled printable key focuses the location entry and inserts that key, which makes Stowaway URL typing work even if the page area has FLTK focus. The Dillo patch handles Enter explicitly in the URL input and top-level fallback path so `FL_WHEN_ENTER_KEY` delivery is not the only way to start loading the typed URL. Keep these patches with the Microwindows/Dillo profile unless Nano-X gains equivalent click-to-focus behavior upstream.
- **Dillo must stay in a 16 MiB RAM profile**: `board/microwindows/build_dillo_rootfs.sh` builds Dillo with the BE-300 low-memory patch: no splash cache, 2 KiB IO buffers, 64 KiB initial receive buffers, a 512 KiB decoded page cap, a 240x320 image-area cap, no GIF decoder, stripped binary, no installed help docs, and CSS/image loading disabled in `/etc/dillo/dillorc`. The page cap is build-time configurable with `BE300_DILLO_MAX_PAGE_BYTES=<bytes>`, but raising it on the stock 16 MiB image can bring back OOM kills on modern pages.
- **COW bug in build_clear_page patch**: The dynamically-generated `copy_page` was once accidentally patched to become `clear_page_simple` by a range that matched `memset(labels, 0, sizeof(labels));` in both `build_clear_page` and `build_copy_page`. This zeroed the destination of every COW copy, so userspace data-segment pages read as zeros after `padzero` triggered COW. The patch series changes only `build_clear_page`.
- **Do NOT force per-page D-cache flush in `__update_cache`**: An unconditional `if (1)` replacement of the `exec || pages_do_alias(...)` guard in `arch/mips/mm/cache.c` is a no-op on the emulator (which doesn't simulate the D-cache) but hangs real hardware at `Calibrating delay loop...` — something in the per-page flush path on VR4131 silicon prevents the timer interrupt from delivering, so `jiffies` never advances. An earlier cycle of work hit the same thing ("per-page flush breaks real HW framebuffer"). Leave `__update_cache` at its stock behavior. The real fix for data-page-zeros was keeping the `clear_page_simple` hook out of `build_copy_page`, not this.
- **Docker mknod**: Cannot create device nodes in unprivileged Docker. Not an issue at runtime — the kernel mounts devtmpfs (`CONFIG_DEVTMPFS_MOUNT=y`) over `/dev` on the JFFS2 root before exec'ing `/sbin/init`, so all required device nodes appear dynamically.
- **NAND and `--ne2000` can coexist only via the XFER path**: the legacy NAND DIO ports (`PA 0x0A00D200/D202`) live inside the VRC4173 PCMCIA card window (`0x0A00D000-0x0A00D7FF`). `board/casio-be300/nand.c` therefore drives NAND through the VRC4173 XFER engine (`PA 0x0A00A4xx` / `0x0A00B000`), and `board/casio-be300/setup.c` enables the PCMCIA bridge so CF/NE2000 can own the C000/D000 windows without stealing NAND I/O. Do not reintroduce DIO-backed Linux NAND access unless the emulator decode model is changed with it.
- **simplefb doesn't work**: The mainline `simplefb` driver uses `ioremap_wc()` which doesn't work for the BE300's KSEG1-mapped VRAM. Use the ported `sfb.c` instead: kernel CFB helpers write through uncached KSEG1 0xAA200000, while fbdev mmap and `fix.smem_start` expose physical 0x0A200000 to LinuxFb clients.
- **OPIE LinuxFb acceleration**: The default BE-300 Qt/Embedded LinuxFb path is Qt's software raster code over `/dev/fb0`. The experimental accelerator is opt-in with `BE300_QWS_ACCEL=1`; it maps VRC4173 registers through `/dev/mem` and uses display-engine mode 0 for solid RGB565 fills and mode 1 for same-framebuffer scroll/copy. The contract matches the emulator model at PA 0x0A000200: destination offset registers 0x210/0x214, source offset registers 0x218/0x21C, width/height 0x208/0x20C, trigger 0x234. `BE300_QWS_NOACCEL=1` keeps the software raster path even if acceleration is requested.
- **Framebuffer console requires CFB helpers**: `CONFIG_FB_CFB_FILLRECT/COPYAREA/IMAGEBLIT` must be force-selected in Kconfig since no standard driver selects them. The patch series adds `select FB_CFB_*` to the CASIO_BE300 Kconfig entry.

### Toolchain Notes

The Debian `gcc-cross-mipsel-linux-gnu` and its sibling `libc6-mipsel-cross` target mips32r2 by default. To target the VR4131 (MIPS III), everything linked into userspace must be built with `-march=mips2` (MIPS II is the highest ISA that neither uses SPECIAL2 nor 64-bit instructions — MIPS III is technically a better fit but `-march=mips3` enables `dmult`/`dsll` etc. that the emulator can't execute). `-march=mips2` produces strict 32-bit MIPS II code that runs on VR4131 and the emulator.

- **musl**: rebuild from source with `CC="mipsel-linux-gnu-gcc -march=mips2"`. Phase 0a of `build_be300_kernel.sh` does this if `musl-mipsel/lib/libc.a` still has `mul` instructions.
- **uClibc-ng**: optional with `BE300_LIBC=uclibc`; dynamically linked, Microwindows-only, built from `uClibc-ng-1.0.51.tar.xz` into `/work/uclibc-sysroot`.
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
