# BE-300 TinyX profile

Fourth UI profile for the BE-300 NAND build alongside `microwindows`,
`opie`/`opie64`, and `picogui`. Where the others are GUI shims that
implement only an Xlib subset (Nano-X+NXlib, Qt/Embedded QWS, or
PicoGUI's own protocol), this profile ships the actual mainline X11
stack: kdrive `Xfbdev` from
[xorg-server-1.6.5.901](https://www.x.org/releases/individual/xserver/)
(the last release with kdrive intact), matchbox-window-manager 1.2 as
a single-client fullscreen WM, and `rxvt` 2.7.10 as the default user-facing
terminal (`xterm` 253 remains available via `BE300_TINYX_TERMINAL=xterm`).

## Quick start

```bash
docker compose run --rm mips-dev bash -c "./build_be300_tinyx_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-tinyx.nand --speed 0 --detect-stall --stowaway-keyboard
```

The wrapper sets `BE300_UI=tinyx` and execs `build_be300_kernel.sh`,
which dispatches to `board/tinyx/build_tinyx_rootfs.sh` for the
userspace half and reuses the standard kernel pipeline for the rest.

By default this profile uses **uClibc-ng dynamic linking** (same default
as picogui). Override with `BE300_LIBC=musl ./build_be300_tinyx_nand.sh`
if you want the static-musl variant.

## Source pins

`board/tinyx/xorg_versions` is the single source of truth for every
upstream version. The rootfs builder sources it and downloads each
tarball into `archives/` on demand. To bump a version, edit the
`xorg_versions` file and remove the corresponding `archives/*.tar*`
entry (if vendored).

## File layout

| File | Role |
|---|---|
| `build_tinyx_rootfs.sh` | invoked from the main build with `(ROOTFS, MUSL_SPECS, KHDRS)` — orchestrates the X.Org modular library stack, xorg-server, matchbox, terminal, host-side XKB keymap compile, font install, opcode scan |
| `xorg_versions` | pinned upstream versions (sourced as plain `KEY=value` lines) |
| `keymap.us.xkb` | flat `xkb_keymap { … };` fed to a host `xkbcomp` at build time → `us.xkm` shipped at `/usr/share/X11/xkb/compiled/us.xkm` |
| `matchbox-window-manager.rc` | runtime config copied to `/etc/matchbox/matchbox-window-manager.rc`; disables titlebar, pins 6x13 as the default font |
| `patch_xorg_sources.py` | autoconf/automake modernization for the 1.6.x tree (`configure.in` → `configure.ac`, `AM_CONFIG_HEADER` → `AC_CONFIG_HEADERS`, drop dead `config-hal`/`config-udev` requires); pattern mirrors `board/picogui/patch_picogui_sources.py` |

## Apps shipped (v1)

`Xfbdev`, `matchbox-window-manager`, `rxvt` by default. No browser — that remains
the Microwindows/Dillo profile's territory. No additional X11 clients
(xclock, xeyes, etc.) in v1 to keep the 16 MiB JFFS2 budget reasonable.

## Runtime

`/sbin/init` (busybox) reads `/etc/inittab` (heredoc'd by
`build_be300_kernel.sh` for the tinyx profile). On `tty0`:

```
tty0::respawn:/bin/start-tinyx
```

`/bin/start-tinyx` (also heredoc'd) puts the VT into KD_GRAPHICS via
`be300-vtmode`, pins evdev nodes for the touchscreen and Stowaway
keyboard by device-name (mirrors `board/microwindows/{kbd,mou}_evdev.c`),
starts `/bin/be300-fbrefresh` to make Xfbdev mmap writes visible in the
emulator, then starts `Xfbdev :0 -fb /dev/fb0 -ac -kb -noreset -mouse evdev,... -keybd evdev,...`.
It waits for `/tmp/.X11-unix/X0` to appear, launches
`matchbox-window-manager`, then respawns a terminal running `/bin/sh` in a
loop. The serial shell stays on
`ttyVR0` in `askfirst` mode just like the other profiles.

## Constraints inherited from the rest of the build

- All TinyX binaries pass through the parent `check_rootfs_mips2`
  scan. SPECIAL2 (`mul`, `clz`, `clo`), MIPS32r2 (`movf`/`movt`,
  `seb`/`seh`, `wsbh`, `rdhwr`), and 64-bit ops are forbidden — the
  builder runs a per-package scan as well so library-level regressions
  are caught fast.
- libgcc is patched in `/tmp/libgcc_patched/` by the main script's
  `prepare_be300_libgcc`. The builder propagates
  `-B/tmp/libgcc_patched -L/tmp/libgcc_patched` via LDFLAGS so GCC
  picks up the mips2-clean version.
- Soft-float ABI throughout (uClibc-ng default). Hard-float libgcc
  helpers leak `movt`; the patched libgcc replaces them with mips2 C
  versions from `board/casio-be300/libgcc_helpers.c`.
- libXfont is built `--disable-freetype --enable-builtins --disable-fc`
  to keep the freetype bytecode loops out of the image. PCF bitmaps
  only: `6x13`, `fixed`, `cursor`.

## Known issues / open questions

- xorg-server 1.6.5 autoconf assumes pre-2.69 macros; the
  `patch_xorg_sources.py` modernization runs `autoreconf -fi` after
  patching, and the picogui pattern shows this works for similar
  vintage trees.
- kdrive's upstream evdev pointer driver logs absolute motion but does
  not convert it to X pointer events; `patch_xorg_sources.py` patches
  ABS_X/ABS_Y plus BTN_TOUCH into absolute button-1 pointer input.
- Runtime uses `-kb` and kdrive's built-in key table rather than invoking
  target-side `xkbcomp`; the precompiled `us.xkm` remains staged for future
  full-XKB experiments.
- 16 MiB is tight. If xterm is explicitly selected and the image overflows,
  switch back to the default `BE300_TINYX_TERMINAL=rxvt`.
