# BE-300 OPIE Profile

This directory contains source overlays for the optional OPIE NAND image:

```sh
docker-compose run --rm mips-dev bash -c "./build_be300_opie_nand.sh"
./bin/be300 --nand linux-4.2.9/be300-opie.nand --speed 0
```

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
