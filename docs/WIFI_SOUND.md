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
| AmbiCom WL54-CF / CF8385 | 02DF:8103 | External helper and main image | Open, WEP 40/104, WPA-PSK/TKIP, WPA2-PSK/CCMP |

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
Key material is never returned by the status ioctls or printed in logs.

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
port does not implement WPA3, enterprise EAP, protected management frames or
ad-hoc/AP modes. XI-825 WPA requests return `EOPNOTSUPP`. WL54-CF requires a
supplicant for WPA/WPA2; it rejects a protected AP when configured as open/WEP.
It does not supply an RF/regulatory stack or automatic credential persistence.
Wireless Tools and DHCP userspace must be present in the chosen root filesystem;
no saved network credentials are embedded.

### WL54-CF WPA/WPA2 PSK

Linux 2.6.8.1 and 4.2.9 expose standard WEXT authentication, association IE,
key-installation and deauthentication controls. On 2.6, a bounded `do_ioctl`
fallback accepts the newer command ABI while preserving the kernel's original
WE17 range, scan-event and ESSID layouts. It does not relabel the whole wireless
core as a newer version. The shared 2.4 source adapter remains uncompiled.

`wpa_supplicant -D wext` performs the handshake and derives keys in userspace;
the driver passes key material to the CF8385 firmware. Ordinary Ethernet traffic
stays blocked until both pairwise and group keys are accepted. EAPOL remains
available during authentication. Failed key replacement, disassociation, removal
and interface-down revoke access; transient key command buffers are erased.
Firmware MIC failures are forwarded to the supplicant for TKIP countermeasures.
The firmware owns wireless encryption, MIC/replay processing and radio behavior,
which still require physical-card validation.

Prepare a private configuration with mode 0600 (substitute your own SSID/PSK):

```text
ctrl_interface=/tmp/wpa
network={
    ssid="your-network"
    key_mgmt=WPA-PSK
    proto=RSN
    pairwise=CCMP
    group=CCMP
    psk="your-passphrase"
}
```

Then run:

```sh
mkdir -p /tmp/wpa
ifconfig wlan0 up
wpa_supplicant -B -D wext -i wlan0 -c /etc/wpa_supplicant.conf
wpa_cli -p /tmp/wpa -i wlan0 status
# Wait for wpa_state=COMPLETED, then:
udhcpc -i wlan0
```

For an older WPA/TKIP AP use `proto=WPA`, `pairwise=TKIP`, `group=TKIP`.
Fresh entropy from the kernel random pool is required; do not ship a reusable
random seed or disable the supplicant's entropy checks.

### Optional supplicant build

`scripts/build_wifi_userspace.sh` builds static, PSK-only wpa_supplicant and
wpa_cli 2.11. Its Debian upstream archive is pinned to SHA256
`4bc22d37533b53f0e9dfc4788cd7798457908dfb57e08ab5894a721061e66247`.
The profile uses WEXT, Linux packet sockets and internal crypto without external
TLS libraries. Source files and binaries stay in ignored `build-wifi/`.

After preparing the repository's MIPS2 musl and patched libgcc, run in the
build container (paths match the main builder):

```sh
BE300_WPA_CC='mipsel-linux-gnu-gcc -specs=/work/musl-mipsel/lib/musl-gcc.specs -B/tmp/libgcc_patched' \
BE300_WPA_KERNEL_HEADERS=/work/musl-khdrs \
BE300_WPA_LDFLAGS=-L/tmp/libgcc_patched \
    scripts/build_wifi_userspace.sh
BE300_WIFI_USERSPACE=/work/build-wifi/output ./build_be300_kernel.sh
```

`BE300_WIFI_USERSPACE` also reaches the shared OPIE and donor Microwindows
rootfs staging paths. Other root filesystems can be populated explicitly with
`python3 tools/stage_wifi_userspace.py build-wifi/output /path/to/rootfs` before
packing. The stager validates ELF32 little-endian MIPS inputs, installs both
tools in `/sbin` and preserves upstream license/source notices. It never installs
credentials or enables automatic association. The old-kernel musl thread-pointer
fallback supports this single-threaded client; it is not general pthread support.

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

To include WPA/TKIP and WPA2/CCMP key-scope, failed-replacement and data-gating
checks, add `-DBE300_WIFI_OPENSSL` and link `-lcrypto` when compiling the protocol
test (OpenSSL development headers are required). These tests inject keys into
the independent model; the guest boots below validate real handshake/crypto.

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

### WPA guest validation

Private test inputs and logs live under `/workspace/setup/linux-wpa/`, outside
Git. Static wpa_supplicant 2.11 uses the pinned profile above, musl 1.2.5, patched
libgcc, `-Os -march=mips2 -mfpxx` and sanitized 4.2.9 UAPI headers. The archive
build, MIPS instruction scan, valid staging and invalid-ELF rejection pass.
Kernel builds use the source configurations with a disposable initramfs:

```sh
python3 scripts/install_board_hardware.py --kernel 2.6 linux-2.6.8.1
make -C linux-2.6.8.1 ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- -j4 vmlinux
python3 tools/pack_legacy_kernel_nand.py --vmlinux linux-2.6.8.1/vmlinux \
    --out /path/to/private/test.nand --build-dir /path/to/private/spl
# Repeat with --kernel 4.2 and linux-4.2.9.
```

`-DTEST_WPA=1` in `avnet_smoke_init.c` runs the real supplicant from
`/sbin/wpa_supplicant` with a private `/etc/wpa_supplicant.conf`. The test rootfs
must include a freshly generated 256-byte `/entropy.seed`; the privileged probe
credits this **test fixture only** to the kernel random pool. Production images
receive neither a seed nor credentials. Progress and bounded supplicant log
bytes are captured in the framebuffer. The probe uses MIPS socket constants
and binds its packet socket before transmitting ARP.

Boot copies of packed NANDs from an artifact directory with:

```sh
/workspace/setup/run-container.sh env BE300_AUTOSTOP_SEC=180 DISPLAY=:0 \
    BE300_AUDIO=0 BE300_WIFI_SECURITY=wpa2 BE300_WIFI_KEY=password \
    /workspace/be300/build-host-service/be300 --nand nand.bin --speed 0 \
    --wl54cf >stdout.log 2>stderr.log
# WPA/TKIP: BE300_WIFI_SECURITY=wpa.
# Negative case: keep guest PSK fixed and use BE300_WIFI_KEY=wrongpassword.
```

Linux 2.6.8.1 and 4.2.9 complete WPA/TKIP and WPA2/CCMP key negotiation with
unmodified wpa_supplicant, ARP TX/RX and all eight completion blocks
(`boot42-wpa2-release`, `boot42-wpa-release`, `boot26-wpa2-release`,
`boot26-wpa-release`). Both wrong-password cases remain unauthorized and report
`reason=WRONG_KEY` (`boot26-wpa2-bad-key`, `boot42-wpa2-bad-key`); the probe never
proceeds to ARP. These kernels expose the stock 16 MiB RAM.
Firmware MIC event forwarding and over-the-air replay/countermeasure behavior
still need physical-card testing. Full GUI/rootfs profiles are not rebuilt by
these disposable-initramfs checks.
