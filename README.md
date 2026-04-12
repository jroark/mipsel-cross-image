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
  assembly init in earlier work; the BusyBox initramfs has not yet been
  exercised on real HW in this tree.
- Framebuffer, polled keyboard, early printk over the companion-chip UART,
  and devtmpfs all work.

## Getting Started

### 1. Build the Docker container
```bash
docker-compose build
```
The container provides the `mipsel-linux-gnu` cross toolchain plus the
utilities needed to build the kernel, musl, and BusyBox.

### 2. Build the BE-300 kernel and initramfs
```bash
docker-compose run --rm mips-dev bash -c "./build_be300_kernel.sh"
```
This runs the full pipeline (see *Build Pipeline* below) and produces
`linux-4.2.9/vmlinux` with the initramfs embedded. Takes a few minutes on
first run (builds musl, installs kernel headers, builds BusyBox, builds
the kernel); subsequent runs reuse the musl/headers caches.

### 3. Boot it on the emulator (macOS host)
```bash
./bin/be300 --kernel linux-4.2.9/vmlinux \
    --cmdline "console=tty0 earlyprintk keep_bootcon" --speed 0
```
Emulator keys: `Q` quit, `S` screenshot (saved as `screenshot_*.bmp`),
`M` help. Useful flags: `--log-mmio`, `--trace`, `--speed 0` (unthrottled).

The early kernel messages go to both the companion-chip serial UART and
the framebuffer console. After `Console: switching to colour frame buffer
device` everything goes to the framebuffer — use `keep_bootcon` to keep
the kernel printks on serial as well.

For reference, the repo includes two known-good older kernels:
```bash
./bin/be300 --kernel kernels/vmlinux-2.4 --cmdline "console=tty0 root=/dev/ram"
./bin/be300 --kernel kernels/vmlinux-2.6
```

## Build Pipeline (`build_be300_kernel.sh`)

The build script does a lot of sed-driven kernel patching and cross-toolchain
trickery — see `CLAUDE.md` for the full story. At a high level:

- **Phase 0a** — Rebuild musl with `-march=mips2` if `musl-mipsel/lib/libc.a`
  still contains MIPS32 SPECIAL2 `mul` instructions. VR4131 is MIPS III and
  doesn't implement SPECIAL2, so any `mul rd, rs, rt` raises a Reserved
  Instruction exception and kills userspace with SIGILL.
- **Phase 0** — Install sanitized Linux UAPI headers (`make headers_install`)
  from linux-4.2.9 into `/work/musl-khdrs`. musl doesn't ship `linux/*.h`,
  and the older `uclibc-kernel-headers/` set lacks the `__UAPI_DEF_*` guards
  so it collides with musl's own `netinet/in.h`.
- **Phase 1** — Build a static BusyBox linked against musl:
  1. `make distclean && defconfig`, then disable applets that can't build
     against musl + sanitized 4.2.9 UAPI (all networking, runit, WTMP/UTMP,
     NFS/RPC, TC, `FEATURE_SYSLOGD_CFG`).
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
- **Phase 2–4** — Extract linux-4.2.9, apply GCC 10+ compat fixes
  (`yylloc` extern, `log2.h` noreturn/const, `-Werror` removal), inject
  BE-300 board support and a pile of kernel sed patches (VR41xx TLB
  compatibility fixes, VR4131 cache-bug split, 64-bit disabling, COW-safe
  `build_clear_page` replacement, etc.).
- **Phase 5–6** — Configure with `configs/be300_defconfig`
  (`CONFIG_INITRAMFS_SOURCE` points at `$ROOTFS`) and build `vmlinux`.
  The initramfs is embedded because the emulator has no `--initrd` flag.

## Repository Layout

```
build_be300_kernel.sh        Full BE-300 build (kernel + musl + BusyBox)
configs/be300_defconfig      Kernel defconfig
board/casio-be300/           Board support injected into the kernel tree
  setup.c                    arch_initcall, idle override, prom_putchar
  sfb.c                      Framebuffer driver (KSEG1 0xAA200000)
  keys.c                     Polled hardware buttons
  libgcc_helpers.c           mips2 libgcc replacements
  test_c_init.c              Diagnostic musl C /init
  test_page2.S               Diagnostic multi-page asm init
  Makefile
bin/be300                    BE-300 emulator (macOS arm64)
kernels/vmlinux-2.4          Known-good Linux 2.4.18 reference
kernels/vmlinux-2.6          Known-good Linux 2.6.8.1 reference
src/                         CVS snapshots from the linux4.be project
docs/                        VR4131 / VRC4173 manuals, hardware notes
CLAUDE.md                    Deep technical notes and gotchas
```

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
  and EntryLo PFN position all differ. Kernel patches in `build_be300_kernel.sh`
  keep these compatible for both the emulator and real hardware.

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
