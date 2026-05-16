# BE-300 OPIE Profile

This directory contains source overlays for the stock 16 MiB RAM OPIE NAND
image:

```sh
docker-compose run --rm mips-dev bash -c "./build_be300_opie_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-opie.nand --speed 0
```

The stock profile emits `linux-4.2.9/be300-opie.nand`, uses
`board/opie/opie-be300.config`, and leaves
`CONFIG_CASIO_BE300_SDRAM_MB=16` in the generated kernel `.config`. Do not boot
this image with `--sdram 64`; use the `opie64` image for that emulator mode.

The expanded emulator profile builds the same stack with a larger Opie
allowlist and a kernel configured for 64 MiB SDRAM:

```sh
./build_be300_opie64_nand.sh
./bin/be300 --sdram 64 --nand linux-4.2.9/be300-opie64.nand --speed 0
```

The profile builds Qt/Embedded 2.3.10 and a curated OPIE 1.2.5 core PDA set
for the fixed 16 MiB BE-300 NAND geometry. It intentionally replaces Nano-X in
that image profile so the Qt/OPIE libraries and applications have room in the
11 MiB JFFS2 rootfs partition.

The 64 MiB profile uses `opie-be300-64m.config`, enables extra PIM/tools,
Today plugins, input methods, taskbar applets, and a fuller Settings tab with
the stock Opie launcher wallpaper and three-column icon layout. The wallpaper is
installed as a PNG copy because this Qt/Embedded build keeps JPEG support
disabled. The screenshot style this approximates is the Opie/Qtopia launcher as
commonly shipped by OpenZaurus-era images. The profile trims nonessential
SysInfo device artwork so the JFFS2 image still fits the fixed rootfs partition.
It must be booted with the emulator's `--sdram 64` flag so Linux's registered
memory size matches the emulated hardware.

The 16 MiB profile was last verified on May 2, 2026 with:

```sh
./bin/be300 --nand linux-4.2.9/be300-opie.nand --speed 0 --detect-stall
```

The boot registered 16 MiB SDRAM, detected the Samsung 16 MiB NAND, mounted
JFFS2 from `/dev/mtdblock3`, and displayed the OPIE launcher. The generated
artifacts were a 16 MiB `be300-opie.nand`, an 11 MiB `rootfs-opie.jffs2`, and a
4.7 MiB `vmlinux`.

The BE-300 launcher patches force the category tab bar to use equal
positive-width tabs with direct, high-contrast painting. The stock Opie compact
tab layout depends on tab icons and can collapse inactive tabs on the BE-300
profile, leaving only invisible click targets at the top of the display.

Opie autostarts from BusyBox init on tty0, but `start-opie` switches that VT to
`KD_GRAPHICS` before launching `qpe -qws`. This allows the kernel's framebuffer
console to show boot text and the Linux4BE banner while keeping fbcon writes
from repainting over the Qt/Embedded LinuxFb UI. If QPE exits with an error,
the script returns tty0 to text mode and prints the last lines of
`/tmp/opie.log`.

The Opie power meter uses Linux APM emulation through `/proc/apm`. The BE-300
kernel currently reports the emulator as AC online with a 100% battery because
the emulator does not expose dynamic battery or charger state yet.

Qt/Embedded's BE-300 LinuxFb path uses `/dev/fb0` for the framebuffer mmap and
defaults to Qt's software raster code. An experimental accelerator can be enabled
with `BE300_QWS_ACCEL=1`; it maps the VRC4173 display engine through `/dev/mem`
for RGB565 solid fills and same-framebuffer scroll/copy. This mirrors the
emulator's framebuffer implementation at physical `0x0A000200` and falls back to
Qt's software raster code if the register mmap is unavailable.
`BE300_QWS_NOACCEL=1` keeps the software raster path even if acceleration is
requested.

The BE-300 Qt mouse handler reads the touchscreen through
`TPanel:/dev/input/event1`. It coalesces high-rate pressed-motion evdev reports
while preserving immediate press and release reports, which keeps launcher icon
taps and window close taps from turning into small drags or follow-on selection
changes.
