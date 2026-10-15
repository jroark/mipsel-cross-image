# BE-300 PicoGUI profile

Third UI profile for the BE-300 NAND build alongside `microwindows` and
`opie`/`opie64`. PicoGUI is a server-side-widgets GUI from the early 2000s
(Micah Dowty, last upstream tarball `picogui-0.46-brownbag` from 2003);
this profile builds Jim Huang's LGPL-2.1 maintenance fork at
[github.com/jserv/picogui](https://github.com/jserv/picogui) against our
mips2 + uClibc-ng (or musl) toolchain and packs the result into
`linux-4.2.9/be300-picogui.nand`.

## Quick start

```bash
docker compose run --rm mips-dev bash -c "./build_be300_picogui_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-picogui.nand --speed 0 --detect-stall
```

The wrapper sets `BE300_UI=picogui` and execs the main `build_be300_kernel.sh`,
which dispatches to `board/picogui/build_picogui_rootfs.sh` for the userspace
half (server + clients) and reuses the standard kernel pipeline for the rest.

By default this profile uses **uClibc-ng dynamic linking** (mirrors the
Microwindows uClibc-ng path). Override with `BE300_LIBC=musl
./build_be300_picogui_nand.sh` if you want the static-musl variant; that path
will work but spends a little more disk per client because every binary
links its own `libpgui` copy.

## Source pin

`build_picogui_rootfs.sh` reads the jserv/picogui commit to build from
`board/picogui/git_sha` (one line, full 40-character SHA). The committed
default is the placeholder `0000…`; the script refuses to build until you
pin a real SHA.

To pin or refresh:

```bash
# fetch latest SHA on master (manual review encouraged — pin a known-good)
sha=$(curl -fsSL https://api.github.com/repos/jserv/picogui/commits/master \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha"])')

echo "$sha" > board/picogui/git_sha

# (optional) vendor the tarball under archives/ for offline reproducibility
curl -fsSL "https://github.com/jserv/picogui/archive/${sha}.tar.gz" \
     -o "archives/picogui-jserv-${sha:0:12}.tar.gz"
git add board/picogui/git_sha "archives/picogui-jserv-${sha:0:12}.tar.gz"
```

The build script computes `${sha:0:12}` itself and looks for the tarball
under `archives/`; if it isn't there it downloads on demand and caches it.

## File layout

| File | Role |
|---|---|
| `build_picogui_rootfs.sh` | invoked from the main build with `(ROOTFS, MUSL_SPECS, KHDRS)` — orchestrates download → patch → autoreconf → configure → make → install → mips2-opcode scan |
| `picogui.config` | server build profile (drivers, widgets, app allowlist) — equivalent to upstream `pg1/server/configs/profile.tiny` with our additions |
| `evdev.c` | new `/dev/input/event*` input driver for pgserver (upstream lacks one); uses `EVIOCGNAME` to discover `BE-300 PIU touchscreen`, `BE-300 Buttons`, `Stowaway Keyboard` exactly like `board/microwindows/{mou,kbd}_evdev.c` |
| `patch_picogui_sources.py` | autoconf 2.69 modernization (`AM_CONFIG_HEADER` → `AC_CONFIG_HEADERS`), input/Makefile.am wiring for evdev.c, K&R/implicit-int fixups |
| `pgserverrc` | runtime config copied to `/etc/picogui/pgserverrc` — fbdev path, evdev device-name hints, theme/font paths, socket location |
| `calibration.identity` | identity affine touch calibration shipped to `/etc/picogui/calibration` so emulator/CI boots straight into picosm; `tpcal` overwrites this when the user runs it |
| `git_sha` | one-line jserv/picogui commit pin |

## Apps shipped

`pgserver`, `omnibar` (top toolbar: Applications/System menus, clock, load
meter), `pg-desktop` (thin NORMAL-app strip under the toolbar), `pterm`
(terminal, started at boot), `pgboard` (on-screen keyboard), `atomicnav`
(web browser; boot with `--ne2000`), `tpcal`, `canvastst`, `pg-keytest`,
and `be300-tap` (test helper, below).  The Applications menu lists the
`/usr/share/picogui/appmenu/*.app` wrappers.

## Runtime

`/sbin/init` (busybox) reads `/etc/inittab` (heredoc'd by
`build_be300_kernel.sh` for the picogui profile). On `tty0`:

```
tty0::respawn:/bin/start-picogui
```

`/bin/start-picogui` (also heredoc'd) puts the VT into KD_GRAPHICS via
`be300-vtmode`, starts `pgserver -c /etc/picogui/pgserverrc`, waits for
the `/var/tmp/.pgui` socket, then launches `omnibar`, `pg-desktop` and
`pterm`.  omnibar starts menu entries with fork+exec and logs each app to
`/tmp/<app>.log`.  The serial shell stays on `ttyVR0` in `askfirst` mode
(`--serial0-bridge pty:auto`); the kernel console is `tty0`, so read
`/dev/kmsg` diagnostics with `dmesg` from that shell.

## Touch, launch and redraw fixes

`patch_picogui_sources.py` and `evdev.c` carry these BE-300 fixes:

- **omnibar menus open on tap release** (`patch_omnibar_tap_menus`).
  Upstream opened them on pointer-down as press-drag-release menus, so a
  tap's own release closed the menu before anything could be picked.
- **pterm default shell** (`patch_pterm_default_shell`).  Upstream ran
  `/bin/sh -sh`; ash rejects `-sh` and exits, and pterm exited with it.
- **Root widget relayout** (`patch_root_resize_relayout`).  An app's root
  widget changing SIZE/SIDE/SIZEMODE (pgboard does this after it
  registers) only recalculated that widget, so the keyboard never drew and
  later apps got no space.  All layers are now recalculated and repainted.
- **Full relayout + repaint on disconnect** (`patch_closefd_full_redraw`).
  `divnode_recalc` only propagates to nodes whose rectangle changed, so
  marking the tree head alone stopped at omnibar's unchanged toolbar and
  the background node behind a closed app kept a 0x0 size: the app's
  last frame (and later a dismissed menu) stayed on the LCD.  The head
  now also gets `DIVNODE_FORCE_CHILD_RECALC`, as do the root-relayout and
  NORMAL-registration sites.
- **Full redraw ignores a stale INCREMENTAL flag**
  (`patch_full_redraw_drops_incremental`).  While another client's popup
  was on top, pterm's cursor blink left `DIVNODE_INCREMENTAL` set, and the
  repaint after the popup closed drew only the cursor cell.
- **evdev**: per-event `/dev/kmsg` tracing is compiled out (build with
  `-DBE300_EVDEV_TRACE` to restore it).  After `SYN_DROPPED` the driver
  resyncs from `EVIOCGKEY`/`EVIOCGABS`, and a release whose press was lost
  is still delivered as a click.

## Smoke test

`tools/be300_picogui_smoke.sh [nand]` boots a scratch copy of the image,
drives the serial shell, and uses `be300-tap` on the target to inject
taps (`be300-tap X Y [hold_ms]`, `be300-tap --flood N X Y`) and hash the
framebuffer below the toolbar (`be300-tap --fbsum Y0 Y1`).  It checks
menu open/close taps, a tap whose press is lost to a queue overflow,
each app's launch/visibility/repaint-on-close, and a real menu launch.
Tap coordinates are env-overridable (`BE300_SMOKE_*`).

## Constraints inherited from the rest of the build

- All picogui binaries pass through the line-1639 `check_rootfs_mips2`
  scan. SPECIAL2 (`mul`, `clz`, `clo`), MIPS32r2 (`movf`/`movt`,
  `seb`/`seh`, `wsbh`, `rdhwr`), and 64-bit ops are forbidden.
- libgcc is patched in `/tmp/libgcc_patched/` by the main script's
  `prepare_be300_libgcc`. `build_picogui_rootfs.sh` adds
  `-B/tmp/libgcc_patched -L/tmp/libgcc_patched` to its LDFLAGS so GCC
  picks up the mips2-clean version.
- Soft-float ABI throughout. Hard-float libgcc helpers leak `movt`; the
  patched libgcc replaces them with mips2 C versions from
  `board/casio-be300/libgcc_helpers.c`.

## Known issues

- pgboard launches and takes its 25% at the bottom (the terminal shrinks
  to make room), but its keyboard canvas draws nothing and the toolbar is
  transparent, so the strip shows stale pixels.  The compiled `.kb` header
  and symbols look right; the canvas rendering path is unresolved.  The
  smoke test reports `pgboard: visible=no` for this.
- The emulator writes guest NAND writes back into the image file (root is
  remounted rw), and JFFS2 has logged data-CRC errors in rewritten blocks.
  Boot a copy of the image when you don't want it modified.
- `tpcal` calibration file format is a placeholder; replace
  `calibration.identity` with the actual file `tpcal` writes after the
  first interactive run on the emulator.
