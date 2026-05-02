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
utilities needed to build the kernel, musl, and BusyBox.

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
The kernel command line baked into the NAND image carries
`console=ttyVR0,115200 consoleblank=0 root=/dev/mtdblock3 rootfstype=jffs2`.

Kernel messages stay on the companion-chip serial UART so Microwindows can
own the framebuffer without fbcon text overwriting the UI.

To exercise the NE2000 networking smoke test (DHCP + DNS + wget), boot
with `--ne2000` attached:
```bash
./bin/be300 --nand linux-4.2.9/be300.nand --ne2000 \
    --net-mac 02:de:ad:be:ef:01 --speed 0
```
When `--ne2000` is present, `/bin/start-network` brings `eth0` up during
boot and starts DHCP in the background. Run `/bin/ne2000-net-test` from the
serial shell for the blocking DHCP/DNS/HTTP smoke test.

### Optional OPIE images
The build can also replace the default Microwindows UI with Qt/Embedded 2.3.10
and OPIE 1.2.5.

For the stock 16 MiB RAM profile:
```bash
docker-compose run --rm mips-dev bash -c "./build_be300_opie_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-opie.nand --speed 0
```

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
- **Phase 1** — Build BusyBox linked against the BE-300 musl toolchain:
  1. `make distclean && defconfig`, keep the selected networking applets used
     by the NE2000 smoke test, and disable only applets that still need niche
     headers or unsupported runtime pieces (runit, WTMP/UTMP, NFS/RPC, TC,
     `FEATURE_SYSLOGD_CFG`).
  2. Patch a private copy of `libgcc.a` at `/tmp/libgcc_patched/`: the Debian
     cross toolchain's libgcc is built with `-march=mips32r2` and its 64-bit
     helpers (`__divdi3`, `__moddi3`, `__udivdi3`, `__umoddi3`, `__fixdfdi`,
     `__fixunsdfdi`, `__floatdidf`, `__floatundidf`, `__lshrdi3`, `__ashldi3`,
     `__ashrdi3`, `__negdi2`) use SPECIAL2 `mul`. Strip those objects and
     add mips2-compiled replacements from
     [`board/casio-be300/libgcc_helpers.c`](board/casio-be300/libgcc_helpers.c).
  3. `make busybox EXTRA_CFLAGS="-march=mips2 ..." EXTRA_LDFLAGS="... -B/tmp/libgcc_patched"`.
  4. Populate `$ROOTFS` (`bin/busybox`, applet symlinks, `/init → /bin/busybox`,
     `/etc/inittab` that mounts proc/sys/dev and spawns a shell on tty0).
- **UI profile** — Build the selected user interface into `$ROOTFS`:
  the default `BE300_UI=microwindows` path builds Nano-X/Microwindows tools,
  `BE300_UI=opie` builds the curated 16 MiB OPIE profile, and
  `BE300_UI=opie64` builds the expanded OPIE profile and merges
  `configs/be300_64m.config`.
- **Phase 2–3** — Extract linux-4.2.9 and apply
  `patches/linux-4.2.9/be300/series`. The series contains the GCC/UAPI
  compatibility fixes, BE-300 board support, VR41xx TLB/PTE fixes, VR4131
  cache-bug split, 32-bit page-operation forcing, VDSO disable,
  interrupt/GPIO fixes, NE2000 autoprobe suppression, and `be300_defconfig`.
- **Phase 5–6** — Configure with `configs/be300_defconfig`
  from the applied patch series and build `vmlinux`. The kernel mounts the
  JFFS2 root filesystem from NAND mtd3 directly.

## Repository Layout

```
build_be300_kernel.sh        Full BE-300 build (kernel + musl + BusyBox)
build_be300_opie_nand.sh     OPIE image for the stock 16 MiB RAM profile
build_be300_opie64_nand.sh   Emulator OPIE image with 64 MiB SDRAM config
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
board/opie/                  Qt/Embedded and OPIE source overlays/configs
bin/be300                    BE-300 emulator (macOS arm64)
kernels/vmlinux-2.4          Known-good Linux 2.4.18 reference
kernels/vmlinux-2.6          Known-good Linux 2.6.8.1 reference
src/                         CVS snapshots from the linux4.be project
docs/                        VR4131 / VRC4173 manuals, hardware notes
CLAUDE.md                    Deep technical notes and gotchas
```

Generated and vendored build trees such as `linux-4.2.9/`, `rootfs_be300/`,
`musl-*`, `busybox-1.24.2/`, `microwindows/`, `qt-*-be300/`,
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
