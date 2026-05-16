# Casio Cassiopeia BE-300 — Linux 4.2.9 Port

A cross-compilation environment and build pipeline that produces a Linux 4.2.9
kernel + BusyBox userspace for the Casio Cassiopeia BE-300 PDA (NEC VR4131,
MIPS III, little-endian, 16 MB RAM). The resulting `vmlinux` boots to an
interactive BusyBox `ash` shell on the BE-300 emulator.

For deep hardware / porting notes see [`CLAUDE.md`](CLAUDE.md).

## Status

- Linux 4.2.9 boots to userspace on the BE-300 emulator and reaches a
  BusyBox `/bin/sh` prompt on the framebuffer console (tty0).
- Real hardware (VR4131 silicon) has booted to userspace with a minimal
  assembly init in earlier work; the current JFFS2/NAND rootfs path has not
  yet been exercised on real HW in this tree.
- Framebuffer, polled keyboard, early printk over the companion-chip UART,
  and devtmpfs all work.

## Getting Started

### 1. Build the Docker container
```bash
docker-compose build
```
The container provides the `mipsel-linux-gnu` cross toolchain plus the
utilities needed to build the kernel, musl/uClibc-ng, and BusyBox.

### 2. Build the BE-300 NAND image
```bash
docker-compose run --rm mips-dev bash -c "./build_be300_kernel.sh"
```
This runs the full pipeline (see *Build Pipeline* below) and produces
`linux-4.2.9/vmlinux`, a 16 MiB NAND image at `linux-4.2.9/be300.nand`
that packages the SPL + kernel + JFFS2 rootfs, and a stripped BusyBox
rootfs tree at `rootfs_be300/`. Takes a few minutes on first run
(builds musl, installs kernel headers, builds BusyBox, Microwindows,
the kernel); subsequent runs reuse the musl/headers caches.

### 3. Boot it on the emulator (macOS host)
```bash
./bin/be300 --nand linux-4.2.9/be300.nand --speed 0
```
Emulator keys: `Q` quit, `S` screenshot (saved as `screenshot_*.bmp`),
`M` help. Useful flags: `--log-mmio`, `--trace`, `--speed 0` (unthrottled).
The kernel command line baked into the NAND image carries `console=tty0`,
`console=ttyVR0,115200`, `consoleblank=0`, `vt.global_cursor_default=0`, and
the NAND rootfs arguments.

The stock 16 MiB Microwindows browser kernel is built for RAM headroom, so it
does not include fbcon, the boot logo, or the framebuffer font payload.
Kernel messages remain available on the companion-chip serial UART, and Nano-X
opens `/dev/fb0` directly after userspace starts. Re-enable fbcon/logo in
`configs/be300_defconfig` only when boot-time framebuffer diagnostics matter
more than browser memory.

To exercise the NE2000 networking smoke test (DHCP + DNS + wget), boot
with `--ne2000` attached:
```bash
./bin/be300 --nand linux-4.2.9/be300.nand --ne2000 \
    --net-mac 02:de:ad:be:ef:01 --speed 0
```
When `--ne2000` is present, `/bin/start-network` brings `eth0` up during
boot and starts DHCP in the background. Run `/bin/ne2000-net-test` from the
serial shell for the blocking DHCP/DNS/HTTP smoke test.

The default NAND kernel no longer includes the CompactFlash/libata/SCSI/ext2/
VFAT/NLS stack. Build `linux-4.2.9/linux_cf.img` with
`./build_be300_cf_image.sh` when testing the CF recovery/root path.

### Default Microwindows browser
The default `BE300_UI=microwindows` image now builds Nano-X plus Dillo 3.2.0
through FLTK 1.3.8 on Microwindows' NXlib X11 compatibility layer. `/bin/mw-browser`
launches Dillo by default, with no startup URL when no argument is supplied, and
falls back to the older `/bin/nxweb` smoke-test browser if Dillo is absent or
`MW_BROWSER_ENGINE=nxweb` is set in the runtime environment.

The Dillo profile is intentionally small and biased toward 16 MiB RAM: HTTP
browsing is enabled, while TLS, cookies, GIF, JPEG, PNG, WebP, SVG, threaded
DNS, and XEmbed are disabled. The installed `dillorc` also disables external
stylesheets, embedded CSS, background images, image loading, persistent HTTP
connections, and parallel HTTP connections. The build strips installed
binaries, prunes Dillo docs and large Microwindows font payloads, keeps only
the browser-oriented Nano-X apps by default, and leaves the serial shell in
`askfirst` mode so an idle shell is not resident until requested. Build with
`BE300_BUILD_DILLO=0 ./build_be300_kernel.sh` inside the Docker container to
skip Dillo while debugging the base Nano-X image.

The BE-300 Dillo build caps decoded page data at 512 KiB by default so a large
page is rejected before it consumes all RAM. Override the build-time cap with
`BE300_DILLO_MAX_PAGE_BYTES=<bytes>` if you are testing a larger-memory image.

Stowaway keyboard input depends on Nano-X focus, not only FLTK widget focus.
The build patches Nano-X so a touch/button-down inside a client moves keyboard
focus to the window under the pointer before the click is delivered. Dillo is
also patched so the first unhandled printable key focuses the location entry
and inserts that key; this lets a hardware keyboard start typing a URL even
when the page area, rather than the URL field, has FLTK focus. The URL entry
also handles Enter explicitly so NXlib/FLTK shortcut delivery does not have to
trigger `FL_WHEN_ENTER_KEY` for the page load to start. Loading external HTTP
sites still requires booting the emulator with `--ne2000`.

For URL arguments such as `/bin/mw-browser http://frogfind.com/`, the browser
wrapper waits briefly for DHCP to write `/tmp/resolv.conf` before launching the
client. The BE-300 Dillo DNS patch also passes service `"80"` to
`getaddrinfo()` and ignores the returned port, matching the known-working
`/bin/wget` helper path and avoiding the uClibc-ng NULL-service resolver path.

An experimental dynamic uClibc-ng userspace is available for the Microwindows
profile:
```bash
docker-compose run --rm mips-dev bash -c "BE300_LIBC=uclibc ./build_be300_kernel.sh"
```
This keeps the default UI/browser stack but links BusyBox, Nano-X tools, Dillo,
and helper utilities against uClibc-ng 1.0.51 with `/lib/ld-uClibc.so.0` as the
runtime loader. It is intended to test whether shared libc text pages reduce
the resident memory cost of running Nano-X plus browser clients. The profile is
Microwindows-only for now; OPIE remains on the default musl path. uClibc-ng is
built in Docker `/tmp` because its dynamic build produces both `.os` and `.oS`
objects, which collide on the default macOS case-insensitive workspace.

The uClibc-ng profile uses a soft-float ABI for target objects because
Microwindows contains floating-point transform code. The Debian cross compiler
has no soft-float multilib, so link warnings about `crtbegin.o`/`libgcc.a`
being tagged hard-float are expected; some libgcc/math helper paths can still
contain FPU opcodes and rely on the kernel math emulator if reached. The
produced BusyBox, Nano-X apps, Dillo, and uClibc runtime report
`Tag_GNU_MIPS_ABI_FP: Soft float`; the final image scan is clean for
VR4131-unsupported integer opcodes, including the `movt` instruction that
previously crashed Dillo at launch.

Known-good Microwindows/Dillo evidence from May 3, 2026:
`docker compose run --rm mips-dev bash -c "./build_be300_kernel.sh"` produced a
16 MiB `linux-4.2.9/be300.nand`, an 11 MiB padded
`linux-4.2.9/rootfs.jffs2`, a 3.9 MiB unpacked `rootfs_be300/`, a 1.6 MiB
static `/usr/bin/dillo`, and a kernel flat payload of `0x2E95AC` bytes.
Booting with `./bin/be300 --nand linux-4.2.9/be300.nand --ne2000
--net-mac 02:de:ad:be:ef:01 --speed 0 --detect-stall` registered 16 MiB RAM
with `12980K/16384K available`, mounted JFFS2 from `/dev/mtdblock3`, configured
DHCP on `eth0`, launched Dillo to `http://example.com/`, and exited with
`[BE300_STALL_SUMMARY] fired=0`.

Known-good dynamic uClibc-ng evidence from May 3, 2026:
`docker compose run --rm mips-dev bash -c "BE300_LIBC=uclibc ./build_be300_kernel.sh"`
produced a 16 MiB `linux-4.2.9/be300.nand`, an 11 MiB padded
`linux-4.2.9/rootfs.jffs2`, a 3.4 MiB unpacked `rootfs_be300/`, dynamic
`/usr/bin/dillo` at 1.4 MiB, `libuClibc-1.0.51.so` at 540 KiB, and the same
`0x2E95AC` kernel flat payload. `readelf` showed `/lib/ld-uClibc.so.0` as the
interpreter for BusyBox, Nano-X tools, and Dillo, with Dillo reporting
`Tag_GNU_MIPS_ABI_FP: Soft float`. The rootfs scan found no unsupported
VR4131 integer opcodes, and a targeted scan confirmed the previous crash word
`00151001` was absent from Dillo, BusyBox, and `libuClibc-1.0.51.so`. After the
Stowaway URL-entry and uClibc DNS-service patches,
`BE300_LIBC=uclibc ./build_be300_kernel.sh` rebuilt the 16 MiB NAND with the
Dillo fallback key path and explicit URL-entry Enter handler present in
`src/ui.cc`, the `"80"` service `getaddrinfo()` path present in `src/dns.c`,
`/bin/mw-browser` launching Dillo blank by default and waiting briefly for DHCP
only when an HTTP(S) URL argument is supplied, and the rootfs opcode scan still
clean. A temporary diagnostic NAND booted with `--ne2000 --net-mac
02:de:ad:be:ef:08 --speed 0 --detect-stall`, configured DHCP on `eth0`, and
confirmed `/bin/wget -T 25 -O /tmp/frogfind.html http://frogfind.com/` fetched
a 1163-byte response without a stall.

### Optional OPIE images
The build can also replace the default Microwindows UI with Qt/Embedded 2.3.10
and OPIE 1.2.5.

For the stock 16 MiB RAM profile:
```bash
docker-compose run --rm mips-dev bash -c "./build_be300_opie_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-opie.nand --speed 0
```

This profile uses the emulator's default 16 MiB SDRAM size and the compact
`board/opie/opie-be300.config` allowlist. It does not merge
`configs/be300_64m.config`; a completed stock build should leave
`CONFIG_CASIO_BE300_SDRAM_MB=16` in `linux-4.2.9/.config`, produce a 16 MiB
`linux-4.2.9/be300-opie.nand`, and pack an 11 MiB
`linux-4.2.9/rootfs-opie.jffs2`.

For the expanded emulator-only profile:
```bash
docker-compose run --rm mips-dev bash -c "./build_be300_opie64_nand.sh"
./bin/be300 --sdram 64 --nand linux-4.2.9/be300-opie64.nand --speed 0
```

The 64 MiB profile keeps the stock images unchanged, registers the larger
SDRAM size in Linux, and builds a larger OPIE applet/PIM/tools set. Its
launcher defaults use the stock Opie wallpaper and a fuller Settings tab that
matches the classic Opie/Qtopia Settings screen more closely. It must be booted
with `--sdram 64`; do not substitute a `mem=` kernel argument.
The BE-300 launcher also overrides Opie's compact category tab geometry so the
top tabs remain visible and have positive-width click targets on the 240 pixel
display.

Known-good 16 MiB OPIE boot evidence from May 2, 2026:
`./bin/be300 --nand linux-4.2.9/be300-opie.nand --speed 0 --detect-stall`
registered `memory: 01000000 @ 00000000`, detected the Samsung 16 MiB NAND,
mounted `rootfs` from `/dev/mtdblock3` as JFFS2, and reached the OPIE launcher.

### 3b. Build an experimental TinyX image
For the kdrive `Xfbdev` + matchbox-window-manager + terminal profile (real X11
stack over the BE-300 framebuffer):
```bash
docker-compose run --rm mips-dev bash -c "./build_be300_tinyx_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-tinyx.nand --speed 0 --detect-stall --stowaway-keyboard
```

This profile fits the 16 MiB stock SDRAM target and defaults to
`BE300_LIBC=uclibc` dynamic linking. The rootfs builder pulls X.Org
modular sources (xproto..pixman..xorg-server-1.6.5..matchbox-window-manager-1.2..rxvt-2.7.10 by default, xterm-253 optional)
into `archives/` on first run, applies `board/tinyx/patch_xorg_sources.py`
for autoconf modernization, XACE callback lifetime, and kdrive evdev
touchscreen support. The launcher starts `/bin/be300-fbrefresh` for emulator
framebuffer dirtying, then `Xfbdev :0 -fb /dev/fb0 -ac -kb -noreset` with the
touchscreen and Stowaway keyboard event nodes pinned by device name. It also
pre-compiles a US XKB keymap for future full-XKB experiments and ships PCF
bitmap fonts only (`6x13`, `fixed`, `cursor`). Inittab launches
`/bin/start-tinyx` on tty0 with `respawn`; the serial shell stays on ttyVR0.

### 4. Build a CompactFlash recovery image
After the NAND build has populated `linux-4.2.9/` and `rootfs_be300/`:
```bash
docker-compose run --rm mips-dev bash -c "./build_be300_cf_image.sh"
```
This produces `linux-4.2.9/linux_cf.img`, a CF disk image with the stock
recovery filenames in the FAT16 boot partition and an ext2 Linux root
partition.

Boot it through the BE-300 recovery path:
```bash
./bin/be300 --restore --cf linux-4.2.9/linux_cf.img --speed 0
```

## Build Pipeline (`build_be300_kernel.sh`)

The kernel port is carried as a traditional patch series in
`patches/linux-4.2.9/be300/series`. The build script downloads/extracts the
Tiny Core Linux 4.2.9 source, applies that series, then configures and builds.
At a high level:

- **Phase 0a** — Rebuild musl with `-march=mips2` if `musl-mipsel/lib/libc.a`
  still contains MIPS32 SPECIAL2 `mul` instructions. VR4131 is MIPS III and
  doesn't implement SPECIAL2, so any `mul rd, rs, rt` raises a Reserved
  Instruction exception and kills userspace with SIGILL.
- **Phase 0** — Install sanitized Linux UAPI headers (`make headers_install`)
  from linux-4.2.9 into `/work/musl-khdrs`. musl doesn't ship `linux/*.h`,
  and the older `uclibc-kernel-headers/` set lacks the `__UAPI_DEF_*` guards
  so it collides with musl's own `netinet/in.h`.
- **Phase 0b** — When `BE300_LIBC=uclibc`, build dynamic uClibc-ng 1.0.51
  for MIPS2/soft-float into `/work/uclibc-sysroot`, generate the
  `/work/mipsel-uclibc-*` wrapper tools, and install its shared runtime into
  the rootfs. The classic uClibc 2012 source is not carried here; this path uses
  uClibc-ng from the local archive or downloads it if missing.
- **Phase 1** — Build BusyBox linked against the selected BE-300 libc toolchain:
  1. `make distclean && defconfig`, keep the selected networking applets used
     by the NE2000 smoke test, and trim shell/editor/diagnostic/network applets
     that are not needed by the 16 MiB browser image.
  2. Patch a private copy of `libgcc.a` at `/tmp/libgcc_patched/`: the Debian
     cross toolchain's libgcc is built with `-march=mips32r2` and its 64-bit
     helpers (`__divdi3`, `__moddi3`, `__udivdi3`, `__umoddi3`, `__fixdfdi`,
     `__fixunsdfdi`, `__floatdidf`, `__floatundidf`, `__lshrdi3`, `__ashldi3`,
     `__ashrdi3`, `__negdi2`) use SPECIAL2 `mul`, while its float/double
     comparison helpers can use `movf`/`movt`. Strip those objects and add
     mips2-compiled replacements from
     [`board/casio-be300/libgcc_helpers.c`](board/casio-be300/libgcc_helpers.c).
  3. `make busybox EXTRA_CFLAGS="-march=mips2 ..." EXTRA_LDFLAGS="... -B/tmp/libgcc_patched"`.
     For `BE300_LIBC=uclibc`, BusyBox is dynamically linked and its applet set
     is trimmed further to avoid unused legacy applets and uClibc-only symbol
     gaps.
  4. Populate `$ROOTFS` (`bin/busybox`, the reduced applet symlink set,
     `/sbin/init -> /bin/busybox`, `/etc/inittab` that mounts proc/sys/dev and
     starts the serial shell with `askfirst`).
- **UI profile** — Build the selected user interface into `$ROOTFS`:
  the default `BE300_UI=microwindows` path builds Nano-X/Microwindows tools and
  Dillo/FLTK/NXlib unless `BE300_BUILD_DILLO=0` is set, `BE300_UI=opie` builds
  the curated 16 MiB OPIE profile, and `BE300_UI=opie64` builds the expanded
  OPIE profile and merges `configs/be300_64m.config`.
- **Phase 2–3** — Extract linux-4.2.9 and apply
  `patches/linux-4.2.9/be300/series`. The series contains the GCC/UAPI
  compatibility fixes, BE-300 board support, VR41xx TLB/PTE fixes, VR4131
  cache-bug split, 32-bit page-operation forcing, VDSO disable,
  interrupt/GPIO fixes, NE2000 autoprobe suppression, the Linux4BE fbcon logo
  selection, and `be300_defconfig`. `build_be300_kernel.sh` then overlays the
  current `configs/be300_defconfig` and board sources into the extracted tree so
  the repo config remains the effective build input. The color-corrected 240x80 logo source lives at
  [`board/casio-be300/logo_linux4be_clut224.ppm`](board/casio-be300/logo_linux4be_clut224.ppm)
  and is copied into the extracted kernel tree before configuration.
- **Phase 5–6** — Configure with `configs/be300_defconfig`
  and build `vmlinux`. The default NAND/browser config disables CF/libata/SCSI,
  ext2/VFAT/NLS, fbcon/logo/fonts, KALLSYMS, ramdisk, old generic syscalls, and
  other unused kernel paths to keep resident memory low. The kernel mounts the
  JFFS2 root filesystem from NAND mtd3 directly.

## Repository Layout

```
build_be300_kernel.sh        Full BE-300 build (kernel + musl + BusyBox)
build_be300_opie_nand.sh     OPIE image for the stock 16 MiB RAM profile
build_be300_opie64_nand.sh   Emulator OPIE image with 64 MiB SDRAM config
build_be300_picogui_nand.sh  Experimental PicoGUI image (BusyBox + jserv/picogui)
build_be300_tinyx_nand.sh    Experimental TinyX image (kdrive Xfbdev + matchbox + terminal)
build_be300_cf_image.sh      CompactFlash recovery image build
configs/be300_defconfig      Kernel defconfig
configs/be300_64m.config     64 MiB BE-300 kernel config overlay
configs/be300_cf.config      CF boot config overlay
patches/linux-4.2.9/be300/   Canonical numbered kernel patch series
scripts/apply_patch_series.sh Applies a series file to an extracted tree
board/casio-be300/           SPL, CF loader, and userspace helper sources
  setup.c                    arch_initcall, idle override, prom_putchar
  sfb.c                      Framebuffer driver (PA 0x0A200000 / KSEG1 0xAA200000)
  keys.c                     Polled hardware buttons
  libgcc_helpers.c           mips2 libgcc replacements
  test_c_init.c              Diagnostic musl C /init
  test_page2.S               Diagnostic multi-page asm init
  Makefile
board/microwindows/          Nano-X config, apps, and Dillo rootfs builder
board/opie/                  Qt/Embedded and OPIE source overlays/configs
board/picogui/               jserv/picogui server, drivers, configs, builder
board/tinyx/                 kdrive Xfbdev + matchbox + terminal builder/configs
bin/be300                    BE-300 emulator (macOS arm64)
kernels/vmlinux-2.4          Known-good Linux 2.4.18 reference
kernels/vmlinux-2.6          Known-good Linux 2.6.8.1 reference
src/                         CVS snapshots from the linux4.be project
docs/                        VR4131 / VRC4173 manuals, hardware notes
CLAUDE.md                    Deep technical notes and gotchas
```

Generated and vendored build trees such as `linux-4.2.9/`, `rootfs_be300/`,
`musl-*`, `uclibc-sysroot/`, `uclibc-kernel-headers/`, `busybox-1.24.2/`, `microwindows/`, `qt-*-be300/`,
`opie-*-be300/`, and `rootfs_be300*` are ignored locally. Edit the source
inputs and patch series instead of generated outputs.

## Key Toolchain Constraints

All quickly explained; full detail in `CLAUDE.md`:

- **Use `-march=mips2`, not `-march=mips32`**, for anything linked into
  userspace — VR4131 is MIPS III with no SPECIAL2 opcode space.
- **The emulator is strictly 32-bit.** No `sd`/`ld`/`daddu`/`dsll`/etc.
  `arch/mips/mm/page.c` must force `clear_word_size=4` and `copy_word_size=4`.
- **Patch libgcc.a** (see Phase 1) — stock `libgcc.a` from the Debian cross
  toolchain is mips32r2.
- **No multilib** for mips2; `gcc -print-multi-lib` only lists n32/n64.
  Rebuilding gcc from source would be the only alternative.
- **VR41xx TLB is not standard R4000** — PageMask, Context BadVPN2 position,
  and EntryLo PFN position all differ. The kernel patch series keeps these
  compatible for both the emulator and real hardware.

## Reference Material

- [`docs/Vr4131-um_200203.pdf`](docs/Vr4131-um_200203.pdf) — NEC VR4131 User's Manual
- [`docs/Vrc4173.pdf`](docs/Vrc4173.pdf) — NEC VRC4173 companion chip manual
- [`docs/hardware.txt`](docs/hardware.txt), [`docs/hw_notes.txt`](docs/hw_notes.txt) — BE-300 hardware layout notes
- [`src/linux-latest/`](src/linux-latest/), [`src/linux4be-2.4.18-20021129/`](src/linux4be-2.4.18-20021129/) — linux4.be CVS snapshots
- [`CLAUDE.md`](CLAUDE.md) — full technical notes for contributors

## Testing Legacy Builds

The older generic build scripts still exist for reference (`build_tcl_kernel.sh`,
`build_busybox.sh`, `create_initramfs.sh`) and produce a Malta-board kernel
bootable in QEMU:
```bash
qemu-system-mipsel -M malta \
    -kernel linux-4.2.9/vmlinux \
    -initrd rootfs.gz \
    -append "console=ttyS0" -nographic
```
These are not wired into the BE-300 build pipeline.
