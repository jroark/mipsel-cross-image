# Physical Linux NAND

Source-built Linux 2.4.18, 2.6.8.1 and 4.2.9 now have a physical NAND path.
The stock device has 16 MiB RAM; OPIE64 and unchanged donor kernels are not
physical-install profiles. A data-only 16 MiB `.nand` remains an emulator/build
intermediate. The physical encoder produces 17,301,504 bytes, including spare
bytes, from a device-bound CE backup and inventory.

## Build and encode

Build the native helper on the host:

```sh
bash tools/build_nand_tools.sh
```

Take an exact two-pass backup with Glaze's RAM recovery service. Preserve the
original CE backup separately. Ordinary read-only recovery can take a backup;
only its isolated repair mode can program NAND.

```sh
GLAZE=../glaze-os
mkdir -p out/physical-nand
"$GLAZE/out/host/glaze-usb" nand-backup out/physical-nand/device.raw
python3 tools/physical_linux_nand.py --helper out/host/linux-nand-inventory \
  inventory --backup out/physical-nand/device.raw \
  --out out/physical-nand/inventory.json
```

All output paths must be new. The inventory is bound to the exact source
snapshot. The initial encoder accepts CE-format backups; it refuses an
installed physical image as a new factory inventory.

Inside the cross-toolchain container, select a source build:

```sh
BE300_PHYSICAL_NAND=1 ./build_be300_kernel.sh
BE300_PHYSICAL_NAND=1 BE300_2_6_UI=opie ./build_be300_2_6_kernel.sh
BE300_PHYSICAL_NAND=1 BE300_2_4_UI=opie ./build_be300_2_4_kernel.sh
```

Other stock-RAM UI wrappers inherit `BE300_PHYSICAL_NAND=1`. This mode pads a
fresh JFFS2 filesystem to `0xAB0000` bytes and keeps OPIE's `/root` persistent.
When filesystem blocks are quarantined, set `BE300_JFFS2_PAD` to
`16384 * (684 - number_of_quarantined_blocks_in_320_through_1003)` before
building. The packer requires this exact fresh size and never truncates a rootfs.

For the default 4.2 Microwindows profile, encode on the host:

```sh
python3 tools/physical_linux_nand.py --helper out/host/linux-nand-inventory \
  pack --logical linux-4.2.9/be300.nand \
  --rootfs linux-4.2.9/rootfs.jffs2 \
  --backup out/physical-nand/device.raw \
  --inventory out/physical-nand/inventory.json \
  --out out/physical-nand/linux.raw --plan out/physical-nand/placement.json
```

Use the matching logical NAND and JFFS2 outputs for other profiles. The encoder
requires the kernel's physical-support marker, excluding old donors and 64 MiB
kernels. It verifies every boot page through the strict production boot reader
before publishing the candidate. Backup, candidate and plans remain private
local artifacts under the ignored `out/physical-nand/` directory.

## Layout and storage

The geometry matches Glaze's physical v1 recovery envelope: 1024 physical
blocks, 32 pages per block, 512 data + 16 spare bytes per page.

| Blocks | Use |
| --- | --- |
| 0–319 | ROM-readable boot content, with logical block tags and RS ECC |
| 320–1003 | Linux JFFS2 filesystem, exposed as `mtd3` |
| 1004–1023 | Boot replacement pool; outside writable partitions |

Block zero must be usable. A quarantined boot block is relocated into a good
replacement block. Quarantined blocks retain every original byte and are excluded
from erase plans. The ECC/CRC-protected manifest at logical page one excludes
stale preserved CE tags before boot-map voting. Missing/duplicate maps,
uncorrectable pages, invalid manifests and exhausted replacement pools fail closed.
The encoder separately checks the ROM's SPL tag quorum: if a preserved
quarantined block retains a valid duplicate SPL tag, the candidate is refused.
The ROM cannot consult the manifest until it has loaded the SPL, so hiding that
duplicate only in the Linux boot reader would be unsafe.

Boot pages use the ROM/CE RS code over 512 data + 8 tag bytes, with eight parity
bytes in spare offsets 8–15. Filesystem parity uses an implicit all-FF tag so
JFFS2 can change OOB cleanmarkers without reprogramming parity. Filesystem OOB
0–3 and 6–7 are available to JFFS2, and byte 5 remains the bad-block marker.
Erased data/parity pages need no parity. Runtime bad-block markers are scanned
alongside the protected inventory on each boot. ROM tags are never interpreted
as Linux bad-block markers.

The SPL and kernel readers consume 520 bytes in MODE 5, then eight bytes in
MODE 4. Programming similarly splits MODE 7/6 and checks the real chip status.
Physical program/erase commands cannot target boot content or the replacement
pool. Linux 4.2 also verifies programmed pages and erased blocks by reading them
back. The legacy NAND core's write verification is enabled for physical builds.

Linux 2.4 uses a separate `linux-2.4.18-physical/` tree and the upstream
[MTD/JFFS2 20050122 snapshot](https://archive.debian.org/debian/pool/main/m/mtd/mtd_20050122.orig.tar.gz),
pinned by SHA-256 in `scripts/install_24_nand_backport.py`. This backports NAND
write buffering, bad-block interfaces and shared zlib into 2.4.18, with the
necessary list/timing/inode-cache compatibility helpers. The original generated
2.4 tree is retained. The 2.6 binding also incorporates the later upstream JFFS2
fix that tests OOB free *length*, allowing a free area at offset zero.

## Install and restore

Use Glaze's existing transaction preparer and repair service. Verify a physical
CF recovery boot and keep the card available throughout installation. A RAM
recovery service stays alive while NAND is programmed; normal Linux boot is a
separate reset after verification.

```sh
python3 "$GLAZE/tools/nand_transaction.py" \
  --source out/physical-nand/device.raw --target out/physical-nand/linux.raw \
  --factory-backup out/physical-nand/device.raw \
  --inventory out/physical-nand/inventory.json \
  --placement out/physical-nand/placement.json --out out/physical-nand/install.bin
python3 "$GLAZE/tools/nand_transaction.py" \
  --source out/physical-nand/linux.raw --target out/physical-nand/device.raw \
  --factory-backup out/physical-nand/device.raw \
  --inventory out/physical-nand/inventory.json --restore \
  --out out/physical-nand/restore.bin
```

Before programming, rehearse the actual source, candidate and plans against the
independent emulator NAND controller:

```sh
python3 tests/linux_nand_transaction.py --glaze-root "$GLAZE" \
  --emulator-root ../be300 --source out/physical-nand/device.raw \
  --target out/physical-nand/linux.raw \
  --install-plan out/physical-nand/install.bin \
  --restore-plan out/physical-nand/restore.bin \
  --log out/physical-nand/controller-rehearsal.log
```

This runs the production host writer, kernel repair state machine and NAND
driver under ASan/UBSan against the independent controller, including every
physical data/spare byte and descending block order. The Glaze checkout's
`host/libwolfssl.a`, libusb headers and an ASan-capable host compiler are needed.
The separate `tools/rehearse_linux_nand.py` adapter runs Glaze's full native USB
harness over a local Unix socket; it retains the harness's packet-safe reads.

In the explicit hardware repair boot, the authorized install command is:

```sh
"$GLAZE/out/host/glaze-usb" nand-apply out/physical-nand/device.raw \
  out/physical-nand/linux.raw out/physical-nand/install.bin --execute
```

The writer compares the complete physical source before erase, programs in
reverse block order with block zero last, checks chip status and reads back all
bytes. A failed preflight performs no erase. An interrupted install requires a
fresh two-pass snapshot and a new source-bound restore plan; do not reuse a
stale plan. Once Linux runs, JFFS2 changes the filesystem, so restoration also
needs a fresh snapshot rather than assuming NAND still equals the candidate.

## Validation record

Software validation includes full Docker builds for 4.2 Microwindows, 2.6 OPIE
and 2.4 OPIE/console; raw-ROM emulator boot; 4.2 and 2.6 writable JFFS2; a 4.2
file retained after emulator shutdown/restart; native ECC/map fault tests; and
complete install/restore through the independent controller. Tests:

```sh
python3 tests/nand_burst.py
python3 tests/nand_physical.py
python3 tests/physical_linux_nand.py
```

The native `tests/nand_ecc.c` and `tests/nand_boot.c` also exercise independent
RS syndrome/error fixtures, tag quorum, relocation, I/O failures and duplicate
maps. Generated artifacts and individual boot logs are kept outside tracked
source. Hardware results are recorded below as they are completed.

### Hardware results (2026-11-01)

Flashed with Glaze `nand-apply` on a stock 16 MiB BE-300. Each flash was
verified by a full read-back that included spare bytes.

| Image | Result |
| --- | --- |
| 4.2 Microwindows, original touch driver | Boots; touch dead |
| 4.2 Microwindows, Glaze scan mode, SPL without cache flush or BSS zeroing | Black, no backlight |
| Same kernel, SPL cache flush and BSS zeroing | Black, no backlight |
| 4.2 Microwindows, `BE300_SPL_DIAG` SPL + progress marks | Boots; touch registers but is erratic |
| Same, plus the stroke filter | Boots; touch accurate |
| 2.4 OPIE, `BE300_SPL_DIAG` SPL + stroke filter | Boots to the launcher; touch works |

The cause of the black-screen builds is still open; see CLAUDE.md. 2.6 OPIE and
the 2.4/2.6 PicoGUI images are built and boot in the emulator. They have not
been run on hardware.
