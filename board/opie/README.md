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
Today plugins, input methods, and taskbar applets, and trims nonessential
SysInfo device artwork so the JFFS2 image still fits the fixed rootfs
partition. It must be booted with the emulator's `--sdram 64` flag so Linux's
registered memory size matches the emulated hardware.
