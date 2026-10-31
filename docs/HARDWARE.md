# Shared BE-300 hardware initialization

The source-built Linux 2.4.18, 2.6.8.1 and 4.2.9 profiles use one board
initialization implementation in `board/casio-be300/hardware.c` and
`hardware-regs.h`. The versioned patch series are applied first, then
`scripts/install_board_hardware.py` installs this code and adapts the board
framebuffer, touch, NAND and interrupt drivers to each kernel's interfaces.
Prebuilt donor kernels cannot acquire these changes merely by repacking them;
use rebuild mode.

The register transactions come from the unmodified WinCE 3.0 SPL/OAL/drivers
and the Glaze original-LCD initializer (`jroark/glaze-os` commit `017abd7`).
The emulator is a regression target, not an electrical specification.

## Implemented support

- Independent original-panel startup before framebuffer registration: known
  clock gates, captured parameters, staged C48 enables, serial contrast C1,
  1 ms/1 ms/20 ms settling delays and 5 us contrast edges. The 240x320 RGB565
  framebuffer remains at PA 0x0A200000 with a 512-byte/256-pixel stride.
- Native brightness levels 0..5 and contrast 1..11; brightness duty zero means
  maximum illumination. Framebuffer blanking disables the backlight without
  modifying guest video memory; unblank restores its previous configuration.
- ScCmcu configuration and watchdog servicing: reload 150 seconds immediately
  and every five seconds, with the stock 0x53/0x3A transaction every 100 ms.
  Status is read, not required to become zero; hardware can report 3.
- Explicit button-control word A040=9EFF, analog-interface preparation, PIU
  reset with a bounded wait, and recovered touch configuration. The old
  touch power/sequencer/start bit definitions are corrected.
- GIU0 direction/type/active-level/hold configuration without altering other
  pins. Companion source control bit 3 follows Linux's IRQ mask/unmask state;
  source words are not treated as a bitmap W1C register at offset 0014.
  Each driver retains its existing interrupt or polling delivery policy.
- Socket power/reset/window preparation before cold-boot ATA/NIC probing,
  without guessing card COR values or replacing a configured handoff. Card
  presence comes from the `A008` card-detect inputs.
- Explicit NAND unit clock/PIO enables. The shared SPL now frames command and
  address phases like the recovered WinCE path, reads ACK, drains the full
  spare area, deselects transfers and bounds NAND/UART waits. A failed kernel
  load stops instead of executing a partially loaded image.

## Power-on rules (real hardware, 2026-10-30)

A real BE-300 booted from a battery pull (Glaze CF recovery, glaze-os
`docs/NAND_BOOT_AUDIT.md`, "Power-on findings") showed what a NAND-booted
kernel faces. Power+Reset does not clear the companion, so earlier "cold"
tests still ran on Windows CE's state. Each rule below was confirmed by
switching it on and off live over USB:

- **A read or write of a companion unit whose clock gate is off stalls the bus
  for good.** No timeout can catch it. At power-on only gate `111C` is on. The
  framebuffer stalls without `1100`/`110C`, and the companion SIU without
  `1108`/`112C`/`1138`/`113C`. `be300_regs_power_on()` sets CE's baseline
  first thing: gates `1104 1108 1120 112C 1138 113C`, `1B24=0 1B20=1 1B2C=1`,
  `A0DC=FF`, and GPIO4 (low) and GPIO6 (high) as outputs, which USB needed. The
  installer makes each kernel's first console access go through
  `be300_console_ready()`. The SPL and CF loader stay silent unless an SIU gate
  is already on.
- **`0008` bit 0 is the GIRQ0 output enable**, 0 at power-on
  (`be300_girq0_init` sets it). A source word needs bits 2 **and** 3; with bit
  2 clear its pending latch (bit 7) never clears.
- **`03C8` = 3 must be set before the PIU sequencer starts.** Set later, it
  takes effect only at the next `PIUCNT` write.
- **Card presence is `A008` bits 1-2** (active low). `1000` reads 4 only after
  CE has configured a card: 0 with a card after power-on, 8 with none.
- **Read a NAND page's spare bytes in two parts** (2026-10-31, the first Glaze
  boot from NAND). After the ROM's NAND boot, a MODE-5 burst ends after 520
  bytes: 512 data plus the first 8 spare bytes. Reading a 131st word from the
  `B000` stream hangs the bus. The ROM and Casio's SPL write MODE 4 (`A464 = 4`)
  and then read the last 8. The shared SPL, the 4.2 driver
  (`board/casio-be300/nand.c`, which the installer now copies into the tree)
  and the 2.6/2.4 drivers (the installer's `nand_drain`) all split this way.

The emulator models these since `be300` `docs/POWER_ON_STATE.md`. Images that
break a rule stop with a `[BUS] stall:` line instead of booting.

## Source evidence

Addresses are WinCE cached code addresses; early OAL traces use their A007
uncached aliases. All MMIO addresses below are companion offsets unless
prefixed with a physical base.

| Source | Recovered behavior |
|---|---|
| SPL 80F034A0, NK 80078F38 | C00..C24 parameter table; C48 0,1,101,103,10F,30F; C2C=1; contrast C1 |
| SPL 80F038DC, ddi 01A55900 | CMM/LCD gates and BLG enable/config/period/duty |
| ddi 01A56A5C | C4C data bit 2, rising clock bit 1, latch bit 0, MSB first |
| ddi 01A56BB0/01A56BD0 | Duty table 3339,3339,2553,1964,981,0 |
| NK 80076D94/80076DAC | Analog interface 03C8: 2, delay, 3 |
| touch 01A41274..01A41374 | Analog readiness, PIU reset/poll, 0308=05DC,030C=C8,0310=32,0318=1 |
| NK 80076D58, keybddr 01A3246C | Halfword A040=9EFF, separate from live button bytes A044/A045 |
| NK 800A5F60/6C/78/80 | GIU direction/type/active-level/hold selection |
| NK 800A5FEC..800A608C | Companion source initialization; owned controls 4 then C |
| cedmbltin 019F19C4/019F1A00/019F1A0C | MCU timeout reload and 0x53/0x3A keepalive |
| pcmcia 0198C15C..0198C338 | Socket power, reset and window preparation |
| SPL 80F0A654..64,80F0AD34..4C | NAND unit selection and phase/ACK framing |

The comparison NAND's SHA256 is
`cfafca7f1bdcdd82f9a9980b4a684a9830562c8b8f19bc1287131c83a674d6ec`.
It and the extracted guest modules are local-only assets, not repository files.

## Display controls

After boot `/dev/be300-display` is a misc character device. Read it to get
`brightness contrast`, or write two decimal numbers separated by whitespace:

```sh
cat /dev/be300-display
echo '3 5' > /dev/be300-display
```

Brightness 0 is the dimmest stock setting, not backlight power-off. Use the
framebuffer `FBIOBLANK` ioctl for blank/unblank. Repeated blank requests do not
overwrite the saved state. Level writes remain valid while blanked and take
effect on wake. Unknown serial-pin and BLG config bits are preserved.

On kernels without devtmpfs create the node using the dynamically allocated
minor listed beside `be300-display` in `/proc/misc`, major 10. Do not hardcode
a minor across kernel versions or configurations. The watchdog runs in-kernel
and needs no userspace daemon or device-node setup.

## Builds and checks

Run the existing build scripts in the cross-toolchain container:

```sh
BE300_2_4_MODE=rebuild ./build_be300_2_4_kernel.sh
BE300_2_6_MODE=rebuild ./build_be300_2_6_kernel.sh
./build_be300_kernel.sh
```

Their GUI/rootfs prerequisites are unchanged. The 2.4 build requires the
original `archives/linux4be-2.4.18-20021129.tar.gz`; vanilla 2.4.18 is not a
replacement for that board-support source. The 2.6 builder can reuse an
existing source tree after verifying its Makefile version, or download the
SHA256-checked official archive when extraction is needed. An exact 2.6.8.1
Git source used locally was `tbodt/linux-history`, tag `v2.6.8.1`, commit
`0b9aa6dd8cc89e1d491c19d4848b3e8b26e3ae4f`.

Staging is idempotent on build trees with the current adaptation marker.
Unknown or obsolete driver layouts fail instead of silently omitting support.
The hardware source stays canonical in `board/`; do not edit the generated
copies under `linux-*` to maintain a port.

Run the asset-free transaction test on the host:

```sh
cc -std=gnu89 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined \
    tests/hardware_regs.c -o /tmp/be300-hardware-regs
/tmp/be300-hardware-regs
```

It checks the recovered enable order and minimum waits, contrast command and
edges, duty semantics, reserved-bit preservation, bounded PIU reset failure,
GIU pin isolation and MCU protocol with status=3.

`tools/hw_smoke_init.c` is a freestanding MIPS o32 `/init` for validation with
no GUI/libc donor. It checks display read/write and invalid levels, draws a
stride-aware five-band RGB565 pattern with padding sentinels, exercises
FBIOBLANK and waits 160 guest seconds. Three colored pixels at the start of
the last row mark successful controls/blanking; they turn white after the
wait. This provides an observable result when a dock driver owns the UART.
It is a test payload, not a replacement for the shipped userspace profiles.

Compile it with the cross compiler and embed it in a disposable test
initramfs/initrd before packing through `tools/pack_legacy_kernel_nand.py`:

```sh
mipsel-linux-gnu-gcc -march=mips2 -mabi=32 -G0 -mno-abicalls -fno-pic \
    -ffreestanding -fno-builtin -fno-stack-protector -Os -nostdlib -static \
    -Wl,-e,_start -Wl,--build-id=none -o /tmp/hw-rootfs/init \
    tools/hw_smoke_init.c
```

For 4.2 enable CONFIG_BLK_DEV_INITRD and set CONFIG_INITRAMFS_SOURCE to a
directory containing `init`, `dev/`, and `proc/`. 2.6.8.1's original cpio
builder has a hardcoded file list; add the test `/init` to that generated
validation tree. 2.4 needs its existing embedded ext2 initrd path.

Always boot an image copy and capture stdout and stderr. An example is:

```sh
BE300_AUTOSTOP_SEC=180 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    /path/to/be300 --nand /tmp/test-copy.nand --speed 0 --ne2000 \
    > boot.stdout.log 2> boot.stderr.log
```

Check orderly-shutdown screenshots and test markers, not exit status alone.
Do not add generated kernels, NANDs, test initrds, ROMs or captured guest
modules to Git.

## Validation status

The cross-toolchain container compiled and linked Linux 2.6.8.1 and 4.2.9
with this board layer and packed NAND boot images using the shared SPL.
The 4.2 test uses `configs/be300_defconfig`; the 2.6 test uses the patched
`be300_2_6_defconfig`. Both add only a disposable embedded smoke-test `/init`
and serial command line (`ttyS0` on 2.6, `ttyVR0` on 4.2, `consoleblank=0`).
The shipped GUI/rootfs profiles were not rebuilt as part of this check.

The kernel and pack commands, run through
`/workspace/setup/run-container.sh` in the Linux checkout, were:

```sh
make -C linux-2.6.8.1 ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- -j4 vmlinux
python3 tools/pack_legacy_kernel_nand.py --vmlinux linux-2.6.8.1/vmlinux \
    --out /workspace/setup/linux-hw-upgrade/linux26-final.nand \
    --build-dir /workspace/setup/linux-hw-upgrade/spl26-final
make -C linux-4.2.9 ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- -j4 vmlinux
python3 tools/pack_legacy_kernel_nand.py --vmlinux linux-4.2.9/vmlinux \
    --out /workspace/setup/linux-hw-upgrade/linux42-final.nand \
    --build-dir /workspace/setup/linux-hw-upgrade/spl42-final
```

The final 2.6 image was booted for 120 host seconds; the final 4.2 image
was booted for 120 host seconds, each with a copied NAND and:

```sh
/workspace/setup/run-container.sh env BE300_AUTOSTOP_SEC=120 \
    DISPLAY=:0 BE300_AUDIO=0 /workspace/be300/build-host-service/be300 \
    --nand nand.bin --speed 0 --ne2000 >stdout.log 2>stderr.log
```

Both reached the smoke `/init`: screenshots have the five expected RGB565
bands at 240x320, with the 16-pixel padding excluded. Display registration,
level write/readback, invalid-level rejection and blank/unblank completed.
2.6's last-row marker turned white and UART reported watchdog survival after
160 guest seconds. A supplemental 600-host-second 4.2 run also reached the
white 160-guest-second marker. That longer run preceded the final 2.4-compatible
text-parser change; the final image repeats the controls/blanking check.
The emulator's MCU window is stubbed, so survival establishes kernel/userspace
liveness, **not** a physical MCU watchdog test. The host transaction test
separately verifies the keepalive/reload register protocol with status 3.

Logs, source snapshots, test kernels and NAND copies remain outside Git under
`/workspace/setup/linux-hw-upgrade/`. The boot directories are
`boot26-release-check`, `boot42-release-check` and the supplemental
`boot42-final`. No boot assets or guest modules are included in this change.

The original Linux4BE 2.4 source archive was unavailable. Its new board
drivers, reconstructed from the committed patch series, pass staging and
repeat-staging checks. The blank callback adaptation was checked against
upstream 2.4's `fb_info.blank` interface (void callback, rather than the
later `fb_ops.fb_blank`). This is **not** a compiled or boot-tested 2.4
kernel. Provide the original archive to complete that verification.

## Limits

The follow-up [sound and Wi-Fi drivers](WIFI_SOUND.md) add OSS wave output
and XI-825/WL54-CF station networking. Their interfaces and validation limits
are documented separately. Existing
APM status estimates are not calibrated battery measurements. The legacy MTD
NOR-emulation/OOB/ECC policy is not converted into a verified physical NAND
FTL by adding unit enables; physical flash writes still require a separately
validated ECC/bad-block/layout path. The SPL does not add speculative ECC.

Timing-field meanings, panel optical curves, factory EEPROM contents, full
suspend/reset retention, and the separate buzzer remain unmeasured. No live
SDRAM timings or unidentified clock-gate meanings are guessed. On real hardware
validate battery-disconnected boot, long-running watchdog service, touch,
card insertion and display sleep/wake before claiming complete board support.
