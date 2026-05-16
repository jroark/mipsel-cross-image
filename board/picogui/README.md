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

## Apps shipped (v1)

`pgserver`, `pgboard` (onscreen keyboard), `pterm` (terminal), `picosm`
(launcher), `tpcal` (touch calibration). No browser — that remains the
Microwindows/Dillo profile's territory. No clocks (`lcdclock`/`wclock`)
in v1 to keep the attack surface small.

## Runtime

`/sbin/init` (busybox) reads `/etc/inittab` (heredoc'd by
`build_be300_kernel.sh` for the picogui profile). On `tty0`:

```
tty0::respawn:/bin/start-picogui
```

`/bin/start-picogui` (also heredoc'd) puts the VT into KD_GRAPHICS via
`be300-vtmode`, starts `pgserver -c /etc/picogui/pgserverrc`, waits for
`/tmp/pgsrv/.pgui` to appear, then launches `pgboard` and `picosm`. The
serial shell stays on `ttyVR0` in `askfirst` mode just like the other
profiles.

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

## Known issues / open questions

- `evdev.c` is a new ~250-line driver. Touch + Stowaway pathways mirror
  the proven Microwindows drivers, but the picogui registration
  vtable (`g_input_driver_evdev`) and main-loop fd hook are
  picogui-specific and need empirical verification on first boot.
- `picogui.config` variable spellings follow the canonical names that
  upstream `pg1/server/configs/profile.tiny` uses; if jserv's tree
  renamed any, `patch_picogui_sources.py` should normalize them.
- `tpcal` calibration file format is a placeholder; replace
  `calibration.identity` with the actual file `tpcal` writes after the
  first interactive run on the emulator.
