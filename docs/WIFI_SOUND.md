# BE-300 Linux sound and CF Wi-Fi

The shared board installer now adds Casio wave-output and CF wireless station
drivers to the source-built Linux profiles. They use Linux OSS, network and
Wireless Extensions interfaces, rather than Glaze syscalls. Board MMIO facts
come from the recovered WinCE drivers and the Linux hostap/Hermes and Libertas
protocol definitions. The kernel implementation is GPL-2.0-only; it does not
copy Glaze's GPLv3 driver implementation into the Linux kernel.

## Wave output

`board/casio-be300/audio.c` implements OSS playback, with a 32 KiB software
queue and two 4 KiB DMA buffers. The Casio block is at companion offsets
`0880..08CC`, with codec commands at `03C0`; it is **not** the VRC4173 manual's
AIU. Buffer registers are a current/next queue with inclusive KSEG1 ends.
Completed buffers are replenished through the next pair, even when hardware
repeatedly reports completion bit 0. Both completion bits are acknowledged.

The driver uses the companion audio IRQ (Linux IRQ 80), with timer fallback
and a bounded stalled-DMA failure path. Codec commands have bounded before/
after waits. Initialization, clock/power/start/stop sequencing and settling
delays follow the recovered `wavedev.dll` transactions. DMA memory is first
written back and invalidated, then filled through uncached aliases.

`/dev/dsp` accepts signed 16-bit little-endian PCM, mono or interleaved stereo,
at 8000, 11025, 16000, 22050, 32000 or 44100 Hz. `SNDCTL_DSP_SPEED` returns the
nearest supported rate. Format changes require drained output. The interface
supports blocking/nonblocking writes, poll, reset, sync/drain, format/rate/
channel negotiation, fixed fragment/space queries and queued-byte reporting.
Writes must contain whole PCM frames; capture and mmap are not implemented.
The single playback stream opens exclusively for writing.

`/dev/mixer` exposes master and PCM controls as aliases for one software
stereo gain, 0..100 per channel. A change reaches playback within the two DMA
buffers. It does not guess undocumented analog volume registers. Capture,
codec input and the separate hardware buzzer are not implemented.

The sound core allocates OSS minors; boot logs report them. With the default
single sound device, nodes are normally:

```sh
mknod /dev/dsp c 14 3
mknod /dev/mixer c 14 0
```

Use the reported minors when other sound devices are enabled. Set S16_LE,
channels and rate with OSS ioctls before playing a raw PCM file. WAV headers
must be parsed by a player, not sent to the PCM device.

## Wireless station interfaces

`board/casio-be300/wifi.c` exposes `wlan0` for these CIS identities:

| Card | MANFID/product | Firmware | Supported security |
|---|---|---|---|
| Z-Com XI-825 / PRISM | D601:0005 | Resident station firmware | Open, WEP 40/104 |
| AmbiCom WL54-CF / CF8385 | 02DF:8103 | External helper and main image | Open, WEP 40/104 |

The driver identifies the primary socket from bounded CIS tuples before NIC
writes. The generic ISA NE2000 probe only touches wired network cards;
recognized wireless cards stay reserved even when initialization fails.
4.2's board setup also skips ATA/wired-NIC platform registration for Wi-Fi;
the 2.4 board IDE address hook skips a wireless card. The existing wired and
CF paths remain separate alternatives for that socket.

Command/FIFO transactions and RX/TX run in a single worker, serialized with
control operations by a sleeping lock. The network transmit callback queues
packets instead of spinning or sleeping in a softirq. Source 0 stays masked;
a timer schedules bounded polling, so an unresponsive card does not hold the
GIU interrupt level or stall audio servicing. Removal stops the carrier and
queue, discards pending packets and keys, and stops card access. A replacement
of the same kind can be brought up after taking the interface down; new-card
discovery after an initially empty boot and replacing it with another model
are not implemented.

PRISM uses resident station firmware, host scan where available (with an
inquiry fallback), bounded command/BAP transactions, LTV RIDs and Ethernet/
SNAP conversion. CF8385 uses helper/main upload, checked command responses,
active scan TLVs, authentication/association and checked RX/TX descriptors.
Lengths, sequence numbers, firmware requests and descriptor bounds are
validated. Unaligned MIPS loads are avoided, including odd FIFO lengths.
WEP key material is never returned by the status ioctls or printed in logs.

Use Wireless Tools with the normal Linux interfaces, for example:

```sh
ifconfig wlan0 up
iwlist wlan0 scan
iwconfig wlan0 key off
iwconfig wlan0 essid 'your-network'
udhcpc -i wlan0
```

For WEP, set the key before the ESSID; disconnect (`iwconfig wlan0 essid off`)
before replacing keys. Live key changes return `EBUSY`. Five/13 byte keys or their ten/26 digit
hexadecimal forms are accepted by Wireless Tools; the kernel receives decoded
key bytes. Key slots 1..4 and open/shared authentication are supported. This
port does not implement WPA/WPA2/WPA3, ad-hoc/AP modes, or a supplicant. The
WL54-CF rejects RSN/WPA association through this interface rather than treating
it as an open network. It does not supply an RF/regulatory stack or automatic
credential persistence. Wireless Tools and DHCP userspace must be present in
the chosen root filesystem; no saved network credentials are embedded.

### WL54-CF firmware

Before `ifconfig wlan0 up`, install the unmodified card firmware locally as:

```text
/lib/firmware/libertas/cf8385_helper.bin
/lib/firmware/libertas/cf8385.bin
```

Firmware is loaded on interface-up, after the root filesystem is available.
The bounded regular-file loader is shared with 2.4 and 2.6.8.1, whose firmware
loading interfaces differ from 4.2's direct filesystem fallback. Missing,
empty, odd-sized or oversized files fail interface-up; no fallback NIC probe
is allowed to reset the card. Transfer requests, retry lengths and deadlines
are checked. A zero firmware MAC can be replaced by the CIS LAN_NODE_ID.

Firmware is an external prerequisite, not a source asset. Obtain a compatible
pair and its license from the vendor or linux-firmware. The Linux Marvell
license restricts use to Marvell silicon: it must not be bundled into a public
emulator NAND. Emulator tests here use synthetic structural records, never
vendor firmware. The vendor B0 helper and Linux B1 helper are different;
physical-card interoperability of either pair needs verification.

The WL54-CF COR uses the existing byte-addressed attribute bridge at
`0x0B400100`; the XI-825 uses the PRISM alias at `0x0A00D3E0`. These mappings
need physical BE-300 validation. **Never write WL54-CF COR at `0x0A00D200`: that
address is the board's NAND direct-I/O port.** No physical flash programming
or firmware flashing is performed by these drivers.

## Build and validation

`install_board_hardware.py` stages the drivers, board helpers and Kconfig
entries after the versioned patch series. `CONFIG_BE300_AUDIO` selects only
the sound core needed for OSS; `CONFIG_BE300_WIFI` selects Wireless Extensions
when networking is enabled. The 2.4 builder enables the sound core before
`oldconfig`; its Config.in adapter selects the board objects. Source rebuilds
are required. Prebuilt donor kernels cannot gain drivers by NAND repacking.

The original Linux4BE 2.4 source archive is still unavailable, so its added
source/config integration is **not** reported as compiled or boot-tested.
2.6.8.1 and 4.2.9 are compiled with the repository's source configurations and
a disposable test initramfs; full GUI/rootfs profile rebuilds are separate.

Native tests include the production transaction headers:

```sh
cc -std=gnu89 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined \
    tests/audio_regs.c -o /tmp/be300-audio-regs
/tmp/be300-audio-regs
cc -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
    -Wno-sign-compare -fsanitize=address,undefined -I/path/to/be300/src \
    tests/wifi_protocol.c /path/to/be300/src/hw/xi825.c \
    /path/to/be300/src/hw/wl54cf.c /path/to/be300/src/hw/wifi_security.c \
    -o /tmp/be300-wifi-protocol
/tmp/be300-wifi-protocol
```

The protocol test uses the independent emulator card models, without the
emulator VM, networking backend or guest assets. It checks both cards' init,
scan, open/WEP association, wrong-key rejection, byte-exact Ethernet TX,
removal, BAP bounds, invalid firmware sizes and bounded unready-card failure.
The production header also compiles as GNU89 with declaration-order warnings
promoted to errors. The models use C99/C11. The audio test checks six-rate
mono/stereo setup, codec command order, settling delays, stop and bounded
pre/post-command timeout cleanup. Both tests pass under ASan/UBSan.

`tools/avnet_smoke_init.c` is a freestanding MIPS o32 `/init` (compile like
`hw_smoke_init.c` in HARDWARE.md). It negotiates OSS stereo S16_LE at 22050 Hz,
sets left/right gain to 50/25, plays left then right pulses, drains and checks
zero pending bytes. It then brings up `wlan0`, scans, associates with the
synthetic BE300 AP, and exchanges an ARP request/reply with 10.0.0.254 through
a Linux packet socket. `-DTEST_WEP=1` configures the synthetic key `12345`.

The eight top-row blocks turn green for audio, interface-up, scan, association,
ARP TX, ARP RX and completion. A red block marks the failing step, even when
a dock driver owns the UART. The smoke program and firmware fixtures are test
inputs only; they are not installed into production root filesystems.

The open-network and WEP tests pass on both kernels with **each** card.
The final WEP probes also check OSS mixer identity and refusal of live key
changes. Final WEP captures are in `avnet26-final-xi`, `avnet26-final-wl`,
`avnet42-final-xi` and `avnet42-final-wl`. Tests boot
copies of packed NAND images from `/workspace/setup/linux-hw-upgrade/` with:

```sh
/workspace/setup/run-container.sh env BE300_AUTOSTOP_SEC=60 DISPLAY=:0 \
    BE300_AUDIO=0 /workspace/be300/build-host-service/be300 \
    --nand nand.bin --speed 0 --xi825 >stdout.log 2>stderr.log
# Repeat with --wl54cf. The images contain only structural test firmware.
# WEP probe: add BE300_WIFI_SECURITY=wep BE300_WIFI_KEY=12345 to env.
```

Both `avnet26-xi` and `avnet42-xi` also captured actual host PCM using `--audio`,
`BE300_AUDIO=1`, `SDL_AUDIODRIVER=disk` and `SDL_DISKAUDIOFILE=.../audio.raw`.
The captures contain independent left/right signals with peaks ±4096 and
±2048, matching the requested gains applied to ±8192 source samples. No ROMs,
NANDs, firmware binaries or audio captures are committed.

`-DTEST_WIRED=1` runs the audio and ARP checks against `eth0` with
`--ne2000`, skipping wireless scan/association. This checks the wired-card
probe remains usable after adding CIS ownership guards. Both kernels pass
this test (`avnet26-wired` and `avnet42-wired`), with all eight completion
blocks green.

Physical testing still needs cold start, headphone/speaker output, sustained
DMA without underruns, radio operation, card insertion/removal and firmware
compatibility. The emulator establishes protocol regression behavior rather
than electrical or acoustic correctness.
