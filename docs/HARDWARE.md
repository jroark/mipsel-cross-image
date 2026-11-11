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
  without replacing a configured handoff. Card presence comes from the `A008`
  card-detect inputs. Each power-up first restores the stock SPL socket
  baseline (`111C=1`, `A010=1073`, `A014=1061`, `A018=10B1`, GPIO5 driven
  high), then writes the card's COR through attribute memory at
  `0A00D000+addr` with the configuration window mapped (`A034` bit 2, `A024`
  bits 2-3 clear, `A020` bit 3): ATA gets CCSR FD / COR 43 / CCSR 01 at
  0x202/0x200 with readback and five tries; an I/O card gets `0x40|entry` at
  its CIS CONFIG base, the entry being the one decoding port 0x300 (else the
  default). These are glaze-os `kernel/drivers/cf.c`; on a real BE-300 a COR
  of zero left ATA disabled and a WL54-CF read back 0x41 at 0x200 and
  associated. The Wi-Fi driver resets and rewrites its COR through the same
  window, not the unverified `0B400100` alias.
- Socket-0 cards are classified by CIS FUNCID and MANFID (`card.h`): only an
  NE2000-compatible network card reaches `ne.c`'s register probe (3Com 0101
  and Lucent 0156 are excluded), and only FUNCID 4 storage gets an ATA host.
  On 4.2 that host is `pata_be300`: 8-bit data transfers after SET FEATURES
  01h on every reset, because on hardware each 16-bit data access carried one
  byte with a zero high byte (glaze-os `identify_as`/`read_sector`). 2.4's
  IDE channel is limited to FUNCID 4 but still uses 16-bit transfers.
- GIU lines other than 0 are disabled and their status cleared before the
  cascade is enabled (a CE RAM handoff left its serial line enabled and
  stormed on hardware), and the PCMCIA, button, audio and touch source words
  are written with bit 2 set at init, which also clears stale latches.
- Halt, power-off and restart stop the power MCU's watchdog (ARG0 35 / CMD0
  5C until STATUS&7 is 0, at most 1000 tries; cedmbltin.dll StopWDT) after
  stopping the keepalive timer, whose 53/3A pair would restart it. Without
  this a powered-off BE-300 resets about 150 s later. Halt and power-off also
  move the ETIME alarm out of reach (ECMP all ones, RTCINTREG cleared), since
  `rtc-vr41xx` leaves ECMP at 0 and the emulator then wakes HIBERNATE at once.
- 4.2 RTC writes wait 200 us before and after writing ETIME and read the count
  back, retrying up to three times (VR4131 UM 13.2.1; a real BE-300 read back
  the old count right after a write, glaze-os `rtc.c`). Patch 0007.
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

- **Reset does not invalidate the I-cache, and RAM keeps the last OS's data**
  (2026-11-01). The ROM's tag loop at `0xBFC00700` runs `cache 0x8,0(t0)` while
  it increments `a0`, so it clears one I-cache line. Its D-cache loop at
  `0xBFC0071C` is correct. After a Glaze RAM recovery, a reset into Linux could
  run stale Glaze lines at the kernel's addresses. The SPL's un-zeroed BSS also
  left `nand_ecc.c`'s lazily built RS tables holding Glaze data. Either one
  silently hangs before the LCD/backlight comes up. `spl_start.S` now runs this
  sequence from KSEG1 before any C, as Glaze's SPL does:
  `Index_Writeback_Inv_D` + `Index_Invalidate_I` over 32 KiB, then it zeroes
  `__bss_start..__bss_end`.

The emulator models these since `be300` `docs/POWER_ON_STATE.md`. It does not
model caches or leftover RAM contents, so it cannot catch the last rule. Images that
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

## Buzzer and hard icons

The piezo is the second BLG PWM channel, from stock `bltinbuz.dll` (glaze-os
`kernel/drivers/buzzer.c`, beeps heard on a real BE-300): stop `09A0`, set
gate `1128` bit 0, OR `0202` into the shared configuration `0984`, period
`09A4 = 1411200/Hz - 1`, duty `09A8 = period*(100-pulse)/100 - 1`, start
`09A0`. The backlight's own `0980/0988/098C` are never touched. Linux
exposes it as the "BE-300 Buzzer" input device (`board/casio-be300/buzzer.c`,
EV_SND `SND_TONE` hz / `SND_BELL`), so the console bell, `KIOCSOUND` and
`KDMKTONE` sound it; on 2.4, which has no input bell path, the driver takes
over `kd_mksound`. Tones are clamped to 80-6000 Hz at 50% duty. Framebuffer
blanking now clears only the backlight's mode nibble of `0984`, and keeps the
shared gate on while a tone sounds (glaze-os `display.c`).

The touch panel is 360 rows tall; rows 320-359 cover seven printed icons
below the LCD. A stroke whose first sample lands there produces no pointer
events; releasing it over the same icon, no more than 8 rows above the strip,
sends `KEY_F1..KEY_F7` from the "BE-300 Hard Icons" input device (zones from
touch.dll: columns 0-33, 34-68, 69-102, 103-136, 137-170, 171-205,
206-239; glaze-os `docs/os/HARD_ICONS.md`). A stroke that starts on the LCD
stays a pointer stroke clamped to row 319. The logic is in
`board/casio-be300/hard_icons.h`, shared by the 4.2 driver and the 2.4/2.6
`touch_filter.h`. Both new devices register after the existing ones, so the
4.2 order stays buttons `event0`, touch `event1`, Stowaway `event2` (buzzer
`event3`, icons `event4`).

On 2.4 the board Makefile's objects must come before `include
$(TOPDIR)/Rules.make`; the installer moves `buzzer.o hard_icons.o` there.
`audio.o` and `wifi.o` have always been appended after that include and so
have never been built on 2.4: `audio.c` needs `<asm/cacheflush.h>`, which 2.4
lacks. 2.4 kernels therefore have no OSS or CF Wi-Fi driver yet.

## Battery, display sleep and suspend

`board/casio-be300/battery.c` (all three kernels) reads the battery as
Windows CE's gwes.exe driver does (glaze-os `kernel/drivers/battery.c`):
GIUPIODL bit 12 is 1 on battery, bit 2 is 1 while charging with the
adapter in, the voltage is a 12-bit PIU A/D port-scan result at `0390`, and
the calibration comes from the EEPROM's bytes 0x94/0x95 (bit-banged at
`A19C/A1A0/A1A4` after `1124=0 A140=1 A194=0`), else CE's 4.2 V / 3.7 V
defaults. Every 2 s, only while the touch sequencer is idle, the scan is
stopped and GPIO8 driven low; 20 ms later one conversion is made and the
touch scan restarted. A sample is retried if the touch driver restarted the
scan meanwhile, and the conversion never acknowledges pending touch events.
Averaging, bands and the critical rule are CE's (`battery.h`). 4.2 answers
APM emulation (`/proc/apm`, replacing `power.c`'s fixed "AC, 100 %"); 2.4
and 2.6 get a `/proc/apm` in the same format. In the emulator 4.2 reports
`--battery 40 --battery-state battery` as 40 % offline and `60 charging`
as 59 % charging; the 2.4/2.6 file is built and booted but not yet read at
runtime. Real-hardware EEPROM contents and A/D readings are unmeasured.

Framebuffer blank level POWERDOWN (4) also powers the panel down with
stock NK 0x80079BB4's C48 sequence (bit 9, 20 ms, bits 1-3, 1 ms, C48=0,
C30=1); unblank runs the panel start again and restores brightness and
contrast. Unlike glaze-os, gate `110C` stays on: fbcon or a mapped
framebuffer may still write VRAM, and VRAM behind a stopped gate stalls
the bus.

4.2 idles with mainline `vr41xx_cpu_wait()` STANDBY; the busy-wait override
in `setup.c` is gone now that the emulator models STANDBY setting IE.

4.2 supports suspend to RAM (`echo mem > /sys/power/state`,
`board/casio-be300/pm.c`), following glaze-os `suspend_until()`: panel
down, MCU watchdog stopped, only POWERINTR and GIU line 0 with the GIRQ0
button source unmasked, Status IM2 only so the Count/Compare tick cannot
wake it, then SUSPEND (`.word 0x42000022`) with IE set, again until the
Power key is held or POWERINTR is raised. An interrupt taken between
enabling IE and SUSPEND resumes past it (EPC moved, as glaze's
`power_trap`). Resume restarts the watchdog and the panel. Patch 0008 keeps
the Stowaway input device across the serio reconnect, so event numbers do
not change. Two suspend/resume cycles pass in the emulator; glaze-os has not
yet verified SUSPEND's wake on hardware. Power-off remains HIBERNATE.

## CF hot plug and serial cards (4.2)

`setup.c` polls the card-detect inputs (`A008`) every 500 ms, as glaze-os
`pcmcia_poll()` does. On insertion it powers the socket from its stock
baseline (`be300_socket_power_up()`), waits up to a second for the CIS to
answer, writes the COR (`be300_card_configure()`) and creates the card's
device: `ne` for an NE2000-compatible card, `pata_be300` for storage, or a
16550 at I/O 0x3F8 as ttyS1 for a serial card (FUNCID 2: the RC56LD modem,
the BL-565 Bluetooth card). Removal unregisters it. Patch 0009 lets `ne.c`
bind a device registered after boot. `CONFIG_SERIAL_8250_NR_UARTS` is 2.

Emulator results: `--cf img --cf-insert-after 60` attaches sda and reads
correct sectors; `--cf-eject-after 60` removes sda; `--ne2000
--net-insert-after 60` brings up eth0, which pings 10.0.0.254;
`--cf-modem` answers `ATI` on ttyS1.

Not done: Wi-Fi cards are still bound once at boot by `wifi.c`; 2.4 and
2.6 have no hot plug; the PCMCIA jacket (socket 1 at `0x0B000000`, GIRQ0
source 6) and drivers for the 3c589 and Hermes cards are not written.

## USB function

The BE-300 is a USB 1.1 device. The companion's function controller
(`0x0A001300-0x0A00161F`, clock gate `1114`) answers enumeration itself
from the descriptor table written at `153C+4i`: VID 07CF, PID 2002, vendor
class, EP1 IN bulk 64, EP2 OUT bulk 64, EP3 IN interrupt 8. Linux 4.2 drives
its bulk pipe as `/dev/ttyBEU0` (`board/casio-be300/usb_serial.c`), with
glaze-os's register sequence (`kernel/drivers/usb.c`, which enumerated,
ran its debugger and carried USB networking on hardware): polled each tick
with GIRQ0 source 7 masked, RX by PIO from `14D4`, TX by DMA from an
uncached page, CDC SET_CONTROL_LINE_STATE accepted and other requests
stalled. Output is discarded until the host has set DTR, as with an
unplugged serial cable, and a bus reset or deconfiguration hangs the tty
up. On a Linux host use `modprobe usbserial vendor=0x07cf product=0x2002`;
run a getty on ttyBEU0 for a USB shell or pppd over it for networking.
`tools/be300_usb_serial_test.py <nand>` checks both directions through the
emulator's usbredir bridge (`--pcconnect-dock usb-sync`). 2.4 and 2.6 have
no driver yet.

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
GIU pin isolation and line clearing, MCU protocol with status=3, the socket
baseline, ATA and I/O COR writes with readback retries, watchdog stop/start
and the power-off alarm disarm.

`tests/card_cis.c` runs `card.h`'s classification and COR selection over the
CIS images the emulator presents for ATA, NE2000, XI-825, WL54-CF, 3c589,
Hermes and the CF modem (several read from real cards):

```sh
cc -std=gnu89 -O2 -Wall -Wextra -Werror -Itests/include \
    -fsanitize=address,undefined tests/card_cis.c -o /tmp/be300-card-cis
/tmp/be300-card-cis
```

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
The emulator models the MCU watchdog (stop/start, a 150 s timeout, STATUS 3
while running; be300 `src/hw/cmcu.c`), but takes the 53/3A poll alone as a
reload, which is unconfirmed on hardware. Survival there is **not** a
physical MCU watchdog test. The host transaction test
separately verifies the keepalive/reload register protocol with status 3.

Logs, source snapshots, test kernels and NAND copies remain outside Git under
`/workspace/setup/linux-hw-upgrade/`. The boot directories are
`boot26-release-check`, `boot42-release-check` and the supplemental
`boot42-final`. No boot assets or guest modules are included in this change.

During that earlier validation the original Linux4BE 2.4 archive was
unavailable. Its new board
drivers, reconstructed from the committed patch series, pass staging and
repeat-staging checks. The blank callback adaptation was checked against
upstream 2.4's `fb_info.blank` interface (void callback, rather than the
later `fb_ops.fb_blank`). This is **not** a compiled or boot-tested 2.4
kernel. Provide the original archive to complete that verification.

## Current-emulator NAND compatibility (2026-10-31)

The current emulator reproduces the ROM's NAND-boot transfer limit: MODE 5
provides 512 data bytes and eight spare bytes. The shared SPL and all three
source-built kernel NAND readers now select MODE 4 before consuming the last
eight spare bytes. Linux 4.2 tracks stream position across partial reads and
skipped bytes, including reads of the spare area. The installer upgrades trees
already carrying the v1 hardware integration marker as well as fresh trees.

Linux4BE 2.4 also accesses the companion before its board initcall. Its
`kernel/printk.c` polling UART now enables SIU clocks before accessing the
unit. Its framebuffer initializer enables the two VRAM clocks before fbcon
can draw; full panel setup and settling delays remain in the board initcall,
after delay calibration. The 2.4 patch series also fixes the OSS firmware
loader's errno linkage and disables compiler builtins that otherwise turn
its sprintf into a call to an unavailable external strcpy. Switching from a
GUI-only build to initrd/NAND-root mode replaces an empty ramdisk placeholder
with the donor initrd.

Run the focused host regression checks with:

```sh
python3 tests/nand_burst.py
cc -std=gnu89 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined \
    tests/hardware_regs.c -o /tmp/be300-hardware-regs
/tmp/be300-hardware-regs
```

The NAND check compiles the actual modern byte/skip reader against a strict
520-byte stream model and exercises split reads, spare-only skips and multiple
pages. It also checks both legacy patch layouts, upgrade idempotence and
both fresh and previously staged spare-drain layouts. Hardware-register checks
cover clock ordering,
LCD controls, PIU, GIRQ and the watchdog transaction sequence.


### Build and boot results

The local `mips-cross-dev` Docker image rebuilt every GUI profile, plus the
2.4 initrd/NAND-root and 2.6 kernel-only profiles. The original 2.4 archive was
available for this run, superseding the earlier uncompiled-2.4 limitation.
The host emulator executable's SHA256 was
`d8b6d76d8e1773b29ef7defe718de0fa9cca5709022f4eee3fb35343d20f5427`.
The sibling emulator checkout was at `1bd451a6` (power-state/watchdog model).

| Kernel | Build selector or wrapper | Observed boot result |
| --- | --- | --- |
| 2.4 | `BE300_2_4_UI=mw` | Microwindows launcher; touch opens a working terminal |
| 2.4 | `BE300_2_4_UI=opie` | OPIE desktop |
| 2.4 | `build_be300_2_4_pgui_nand.sh` | PicoGUI video-test pattern |
| 2.4 | `build_be300_2_4_pgui_demo_nand.sh` | PicoGUI desktop and on-screen keyboard |
| 2.4 | `BE300_2_4_UI=none BE300_2_4_ROOT=initrd` | Embedded ext2 root mounted; BusyBox console prompt |
| 2.4 | `BE300_2_4_UI=none BE300_2_4_ROOT=nand` | Ext2 bootstrap, JFFS2 root, framebuffer test exit=0; BusyBox console prompt |
| 2.6 | `BE300_2_6_UI=mw` | Microwindows launcher; touch opens a working terminal |
| 2.6 | `build_be300_2_6_opie_nand.sh` | OPIE desktop |
| 2.6 | `BE300_2_6_UI=none` | Expected VFS panic: this profile supplies no rootfs |
| 4.2 | `build_be300_kernel.sh` | Microwindows launcher; touch opens terminal |
| 4.2 | `BE300_LIBC=uclibc ./build_be300_kernel.sh` | Dynamic Microwindows/Dillo profile; touch opens terminal |
| 4.2 | `build_be300_opie_nand.sh` | OPIE desktop |
| 4.2 | `build_be300_opie64_nand.sh` | OPIE64 desktop with 64 MiB RAM |
| 4.2 | `build_be300_picogui_nand.sh` | PicoGUI desktop/terminal |
| 4.2 | `build_be300_tinyx_nand.sh` | TinyX dock with Term/Stat/Kbd buttons, 16 MiB RAM |

Builds used `docker run --rm -v "$PWD":/work -v /tmp/be300-compat:/validation
mips-cross-dev bash ...`; each selector above was run with its existing build
script. Per-profile logs and saved NANDs are under `/tmp/be300-compat/`.
Boots used disposable NAND copies in `/tmp/be300-compat/boots/<profile>/`,
with this command (serial port numbers were unique per run):

```sh
BE300_AUTOSTOP_SEC=180 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    /Users/jroark/src/mipsel-cross-image/bin/be300 --nand nand.bin --speed 0 \
    --ne2000 --serial1-bridge tcp-listen:18891@127.0.0.1
```

OPIE64 adds `--sdram 64`. Microwindows input checks additionally use
`--touch-script touch.txt`, containing `10000 down 40 30` and `10100 up`.
Screenshots show an opened terminal on all three kernel families. GUI boots
completed without `[BUS] stall` reports. The static and dynamic 4.2 profiles
and the 2.4/2.6 diagnostic shells wrote, synced, read back and removed a small
file on a disposable JFFS2 root. This does not validate physical NAND writes.

Longer runs used `BE300_AUTOSTOP_SEC=600`; a shell background job slept 161
guest seconds and printed `/proc/uptime` and `WATCHDOG_SURVIVED`. Observed
uptimes were 170.99 seconds on 2.4, 166.03 on 2.6 and 164.29 on 4.2. For shell
checks the legacy Microwindows staging used `BE300_MW_SERIAL_SHELL=1`. The
2.6 serial-console diagnostic also disabled `CONFIG_CASIO_BE300_STOWAWAY`:
serial console plus the dock driver otherwise stalled during boot because
they share the SIU. The normal framebuffer-console GUI images retain the
dock driver. All checks remain emulator-only; no new physical-device boot
is claimed.

Repacking the untouched prebuilt 2.4/2.6 donors now gets through the corrected
SPL, but those kernels still stall on their first ungated SIU access. Use
source rebuild mode for the current emulator; repacking cannot replace their
compiled-in drivers.

Final generated NANDs are restored under `linux-4.2.9/`. The extra names
`be300-uclibc.nand` and `be300-2_4-nand-root.nand` preserve alternatives that
normally overwrite `be300.nand` and `be300-2_4-rebuilt.nand`. Image hashes and
source-copy paths are recorded in `/tmp/be300-compat/images.json`. The legacy
Microwindows copies include the optional diagnostic serial-shell overlay.

## Limits

The follow-up [sound and Wi-Fi drivers](WIFI_SOUND.md) add OSS wave output
and XI-825/WL54-CF station networking. Their interfaces and validation limits
are documented separately. Existing
APM status estimates are not calibrated battery measurements. Physical NAND
now has a separate [ECC, inventory and recovery path](PHYSICAL_NAND.md), including
a NAND-capable MTD/JFFS2 backport for Linux 2.4. Default legacy emulator builds
retain their original data-only storage policy; use the explicit physical mode
and a backup-bound raw candidate for hardware.

Timing-field meanings, panel optical curves, factory EEPROM contents, full
suspend/reset retention, and the separate buzzer remain unmeasured. No live
SDRAM timings or unidentified clock-gate meanings are guessed. On real hardware
validate battery-disconnected boot, long-running watchdog service, touch,
card insertion and display sleep/wake before claiming complete board support.
