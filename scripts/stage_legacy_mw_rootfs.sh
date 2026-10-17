#!/bin/bash
# Stage the 2003 linux4.be Microwindows/Nano-X donor ramdisk (BusyBox 0.60.5,
# uClibc 0.9.19, nano-X + nanowm + launcher + demo apps, extracted from
# vmlinux-mw) as a JFFS2 mtd3 rootfs.  Shared by the Linux 2.4.18
# (build_be300_2_4_kernel.sh, BE300_2_4_UI=mw) and 2.6.8.1
# (build_be300_2_6_kernel.sh, BE300_2_6_UI=mw) mw profiles, the same way
# scripts/stage_legacy_opie_rootfs.sh is shared by their OPIE profiles.
#
# usage: stage_legacy_mw_rootfs.sh --devtable <file> --out <rootfs.jffs2>
#            (--rootfs-gz <donor-ramdisk.gz> | --donor <vmlinux-mw>)
#
#   --rootfs-gz  gzipped ext2 donor ramdisk (2.4 caches it as
#                linux-2.4.18/.mw-rootfs.gz)
#   --donor      vmlinux carrying the ramdisk in __rd_start..__rd_end
#
# Both kernels need the BSD pty nodes (/dev/ptyp*, /dev/ttyp*) the 2003
# nxterm hardcodes; they are appended to the device table when missing.
set -euo pipefail

REPO=/work
DEVTABLE=""
JFFS2_ROOTFS=""
PGUI_ROOTFS_GZ=""
DONOR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --devtable) DEVTABLE=$2; shift 2 ;;
        --out) JFFS2_ROOTFS=$2; shift 2 ;;
        --rootfs-gz) PGUI_ROOTFS_GZ=$2; shift 2 ;;
        --donor) DONOR=$2; shift 2 ;;
        *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
    esac
done
[[ -n "$DEVTABLE" && -n "$JFFS2_ROOTFS" ]] || { echo "ERROR: --devtable and --out are required" >&2; exit 2; }
[[ -f "$DEVTABLE" ]] || { echo "ERROR: $DEVTABLE missing" >&2; exit 1; }

echo "--- Building JFFS2 rootfs from microwindows ramdisk contents ---"
JFFS2_WORK=$(mktemp -d)
trap 'rm -rf "$JFFS2_WORK"' EXIT

if [[ -z "$PGUI_ROOTFS_GZ" ]]; then
    [[ -f "$DONOR" ]] || { echo "ERROR: --rootfs-gz or an existing --donor is required" >&2; exit 2; }
    PGUI_ROOTFS_GZ="$JFFS2_WORK/donor.gz"
    python3 - "$DONOR" "$PGUI_ROOTFS_GZ" <<'PYEOF'
# Copy the donor kernel's embedded initrd (__rd_start..__rd_end) out of
# the PT_LOAD segment that contains it.
import struct, sys
src, out = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
e_shoff = struct.unpack_from('<I', data, 32)[0]
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', data, 46)
def shdr(i):
    return struct.unpack_from('<IIIIIIIIII', data, e_shoff + i * e_shentsize)
shstr_off = shdr(e_shstrndx)[4]
def name(tab, off):
    return data[tab + off:].split(b'\x00', 1)[0].decode()
secs = [shdr(i) for i in range(e_shnum)]
symtab = next(s for s in secs if name(shstr_off, s[0]) == '.symtab')
strtab_off = secs[symtab[6]][4]
syms = {}
for i in range(symtab[5] // symtab[9]):
    st_name, st_value = struct.unpack_from('<II', data, symtab[4] + i * symtab[9])
    syms[name(strtab_off, st_name)] = st_value
rd_start, rd_end = syms.get('__rd_start'), syms.get('__rd_end')
if rd_start is None or rd_end is None:
    raise SystemExit(f"ERROR: {src} missing __rd_start/__rd_end symbols")
e_phoff = struct.unpack_from('<I', data, 28)[0]
e_phnum = struct.unpack_from('<H', data, 44)[0]
for i in range(e_phnum):
    p_type, p_offset, p_vaddr, _pa, p_filesz = struct.unpack_from('<IIIII', data, e_phoff + i * 32)
    if p_type == 1 and p_vaddr <= rd_start < p_vaddr + p_filesz:
        rel = p_offset + rd_start - p_vaddr
        open(out, "wb").write(data[rel:rel + rd_end - rd_start])
        print(f"extracted {rd_end - rd_start} byte ramdisk from {src}")
        break
else:
    raise SystemExit(f"ERROR: __rd_start not inside a PT_LOAD segment of {src}")
PYEOF
fi
[[ -f "$PGUI_ROOTFS_GZ" ]] || { echo "ERROR: $PGUI_ROOTFS_GZ missing" >&2; exit 1; }

DEVTABLE_PGUI="$JFFS2_WORK/devtable.txt"
cp "$DEVTABLE" "$DEVTABLE_PGUI"
grep -q '^/dev/ptyp' "$DEVTABLE_PGUI" || cat >> "$DEVTABLE_PGUI" <<'PTYS'

# BSD ptys for the 2003 nxterm, which hardcodes /dev/ptyp%d (added by
# scripts/stage_legacy_mw_rootfs.sh).
/dev/ptyp       c 666 0 0 2  0  0  1 16
/dev/ttyp       c 666 0 0 3  0  0  1 16
PTYS

cp "$PGUI_ROOTFS_GZ" "$JFFS2_WORK/rd.gz"
gunzip -f "$JFFS2_WORK/rd.gz"
mkdir "$JFFS2_WORK/root"
debugfs -R "rdump / $JFFS2_WORK/root" "$JFFS2_WORK/rd" >/dev/null

# Same /dev cleanup as pgui (rdump fabricates regular files for char
# devs; the static devtable owns them at runtime).
find "$JFFS2_WORK/root/dev" -maxdepth 1 -type f -delete 2>/dev/null || true
# Drop any rdumped symlinks that collide with devtable char nodes.
rm -f "$JFFS2_WORK/root/dev/tty0" "$JFFS2_WORK/root/dev/fb"

# The mw donor ships an /etc/profile but no /etc/passwd or /etc/group.
# Add the same stubs the pgui path uses so `id`, `whoami`, and shell
# prompt rendering work.  Append to existing profile (preserves the
# donor's SDL_NOMOUSE=1 / USER=root) instead of clobbering.
cat > "$JFFS2_WORK/root/etc/passwd" <<'PWD_'
root:x:0:0:root:/:/bin/sh
PWD_
cat > "$JFFS2_WORK/root/etc/group" <<'GRP_'
root:x:0:
GRP_
cat >> "$JFFS2_WORK/root/etc/profile" <<'PROFILE_'

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/
export TERM=xterm
export PS1='# '
PROFILE_
echo "--- staged /etc/passwd + /etc/group + appended /etc/profile ---"

# Wrapper that nxterm execs as its child.  Forces interactive mode
# explicitly: busybox sh started by execv("/bin/sh", "/bin/sh", NULL)
# is non-interactive by default — no PS1, no command echo — even
# when stdin/stdout are a tty.  Setting up the env in this wrapper
# also avoids depending on nxterm to call /etc/profile (it doesn't).
cat > "$JFFS2_WORK/root/usr/bin/mw-shell" <<'SHWRAP'
#!/bin/sh
# /usr/bin precedes /bin in PATH so the ls/grep shims (below) shadow
# the busybox applets and pipe through cat — that makes isatty(stdout)
# false inside busybox, which is what its color-output code keys off.
# Setting TERM=dumb/vt100 doesn't suppress 0.60.5's ls colors; the
# isatty trick does.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/
export USER=root
export TERM=vt100
export PS1='# '
# Print diagnostic banner so we can confirm the shim landed and what
# /bin/ls actually is on this boot.  Goes to stderr (nxterm tty).
echo "=== mw-shell debug ===" 1>&2
echo "/bin/ls -la /bin/ls:" 1>&2
/bin/busybox ls -la /bin/ls 1>&2
echo "head /bin/ls:" 1>&2
/bin/busybox head -3 /bin/ls 1>&2
echo "PATH=$PATH" 1>&2
echo "===" 1>&2
exec /bin/sh -i
SHWRAP
chmod 0755 "$JFFS2_WORK/root/usr/bin/mw-shell"

# Patch nxterm's hardcoded window geometry.  The 2003 nxterm binary
# was built without BE300_TOUCHSCREEN defined, so it uses the source
# defaults stdcol=80 stdrow=50 (microwindows/src/demos/nanox/nxterm.c
# lines 75-77), producing a 480x650 px window at 6x13 SystemFixed
# which is twice the 240x320 LCD in both axes.  The -g flag in the
# donor binary is advertised but not honored (verified at runtime).
# Patch the two `li t8, <imm>` instructions in main() that load the
# initial col/row values:
#   vaddr 0x406ecc:  ADDIU t8,$0,80  (0x24180050)  -> 38 (0x24180026)
#   vaddr 0x406fac:  ADDIU t8,$0,50  (0x24180032)  -> 20 (0x24180014)
# giving a 228x260 px window that fits the LCD with the title bar.
python3 - "$JFFS2_WORK/root/bin/nxterm" <<'PYEOF'
import struct, sys
p = sys.argv[1]
with open(p, 'rb') as f: d = bytearray(f.read())
e_phoff = struct.unpack_from('<I', d, 28)[0]
e_phnum = struct.unpack_from('<H', d, 44)[0]
def va2off(va):
    for i in range(e_phnum):
        base = e_phoff + i*32
        p_type, p_offset, p_vaddr, _pa, p_filesz, _ms, _f, _a = \
            struct.unpack_from('<IIIIIIII', d, base)
        if p_type == 1 and p_vaddr <= va < p_vaddr + p_filesz:
            return p_offset + (va - p_vaddr)
    raise SystemExit("vaddr 0x%x not in any LOAD segment" % va)
off1 = va2off(0x406ecc)  # stdcol: li t8, 80
off2 = va2off(0x406fac)  # stdrow: li t8, 50
if bytes(d[off1:off1+4]) != b'\x50\x00\x18\x24':
    raise SystemExit("nxterm stdcol pattern at file off 0x%x mismatch: got %s" %
                     (off1, bytes(d[off1:off1+4]).hex()))
if bytes(d[off2:off2+4]) != b'\x32\x00\x18\x24':
    raise SystemExit("nxterm stdrow pattern at file off 0x%x mismatch: got %s" %
                     (off2, bytes(d[off2:off2+4]).hex()))
d[off1] = 0x26  # 80 -> 38
d[off2] = 0x14  # 50 -> 20
open(p, 'wb').write(d)
print("nxterm patched: stdcol 80->38, stdrow 50->20 (window fits 240x320)")
PYEOF

# Overlay /bin/launcher.cnf with a fuller app set than the donor
# ships.  Donor stock has Tetris / NanoBreaker / Landmine / Slider /
# Terminal / Clock / Magnifier / Scribble / SoftKeyboard / Roach /
# Tux / NXEyes (12 apps).  Add TuxChess, Map (was commented), Image
# view, Clients, EventTest, TouchCal, Term2 so the user has a
# tappable entry for every Nano-X app the donor includes.  Apps
# without a dedicated icon use `-` (per launcher.cnf docs).
# Shell-wrapper launcher uses to exec apps.  Launching directly
# via launcher's fork+execvp produces a pc=0 / vaddr=0 TLBL crash
# for nxterm (same family of bug the picogui session hit — child
# inherits broken signal disposition or fd state from launcher,
# and the freshly-exec'd binary jumps to NULL through the bad
# callback during init).  Inserting an intermediate /bin/sh
# process gives the child a clean signal mask and reaped fd table
# before nxterm starts.
cat > "$JFFS2_WORK/root/usr/bin/mw-launch" <<'LAUN_'
#!/bin/sh
# Wrap with busybox setsid + detach so the target gets a fresh
# session/process-group BEFORE its own setsid call would have
# failed (the cause of the pc=0 TLBL crash on nxterm when launched
# from launcher).  /bin/setsid isn't symlinked in the donor; call
# busybox directly.  Log to /tmp so silent failures are recoverable.
echo "[$(date)] mw-launch $*" >> /tmp/mw-launch.log
( exec /bin/busybox setsid "$@" </dev/null >>/tmp/mw-launch.log 2>&1 ) &
LAUN_
chmod 0755 "$JFFS2_WORK/root/usr/bin/mw-launch"

# Populated launcher.cnf.  Skipping:
#   - $window_background_image: clears LCD with the bg graphic and
#     hides the panel.
#   - the Terminal entry: launching nxterm via launcher fork+exec
#     (even through /bin/sh or a double-forked /usr/bin/mw-launch)
#     hits a pc=0 / vaddr=0 TLBL crash before nxterm can render its
#     window.  nxterm launched directly from rcS works fine, so
#     rcS launches a persistent nxterm instead and the launcher
#     panel covers everything else.
# Apps without dedicated icons use `-`.  mw-launch (small daemon-
# style shell wrapper that double-forks + redirects stdio to
# /dev/null) is on the wrapper path in case it helps any other
# apps avoid the same crash.
# launcher's panel is hardcoded for a screen larger than the BE-300's
# 240x320 LCD — empirically only 4-6 tiles fit before the panel
# either renders off-screen or aborts entirely (verified: 3 entries
# = panel visible, 12 entries = no panel + pc=0 crash).  Cap at 5
# apps so the panel lays out cleanly.  Terminal omitted since
# launcher fork+exec of nxterm crashes (rcS launches it directly).
# 5 verified-working entries.  Terminal is omitted because
# launcher-fork-of-nxterm crashes at pc=0 TLBL regardless of
# wrapper / setsid / detach — the 2003 donor wired Terminal into
# the cnf aspirationally but nxterm was probably only ever launched
# from /bin/startx on the original distribution.  rcS auto-launches
# a persistent nxterm so users still have a shell.
cat > "$JFFS2_WORK/root/bin/launcher.cnf" <<'LAUNCHCNF'
$screensaver_timeout 120

Clock bin/nxclock.pgm bin/nxclock
Tetris bin/ntetris.ppm bin/ntetris
Roach bin/nxroach.pgm bin/nxroach
SoftKbd bin/nxkbd.pgm bin/nxkbd
Tux bin/tux.ppm bin/tux
LAUNCHCNF
echo "--- overlaid /bin/launcher.cnf with $(grep -cE '^[A-Z]' "$JFFS2_WORK/root/bin/launcher.cnf") app entries ---"

# Touch bridge — 2003 nano-X has no /dev/input device strings, so
# it can't read the BE-300 touchscreen on its own.  be300_nxbridge
# reads /dev/input/event1 (touch — patch 0010 evdev) and forwards
# via GrInjectPointerEvent over /tmp/.nano-X.  Built freestanding
# with raw o32 syscalls (same recipe as be300_inputbridge for pgui)
# so it runs on the 2.4.18 + uClibc 0.9.19 donor rootfs without
# needing a matching libc toolchain.
NXBRIDGE_BIN="$JFFS2_WORK/root/usr/bin/be300_nxbridge"
mkdir -p "$(dirname "$NXBRIDGE_BIN")"
mipsel-linux-gnu-gcc -march=mips2 -static -nostdlib -nostdinc \
    -fno-pic -mno-abicalls -fomit-frame-pointer -fno-builtin \
    -Os -Wall -Wl,--entry=_start \
    -o "$NXBRIDGE_BIN" "$REPO/board/casio-be300/be300_nxbridge.c"
mipsel-linux-gnu-strip "$NXBRIDGE_BIN"
chmod 0755 "$NXBRIDGE_BIN"
python3 -c "
import struct, sys
p = sys.argv[1]
with open(p, 'rb') as f: d = bytearray(f.read())
ef = struct.unpack_from('<I', d, 36)[0]
new = (ef & ~0xF0000000) | 0x10000000
if new != ef:
    struct.pack_into('<I', d, 36, new)
    open(p, 'wb').write(d)
" "$NXBRIDGE_BIN"
echo "--- built be300_nxbridge $(stat -c%s "$NXBRIDGE_BIN" 2>/dev/null || stat -f%z "$NXBRIDGE_BIN") bytes ---"

# Replace the donor ntetris with a rebuild of the same 2003 source
# that is played with the BE-300 front buttons (BE-300 Buttons evdev
# node) instead of on-screen buttons.  Static musl, so it does not
# need the donor libnano-X.so.
"$REPO/board/microwindows/build_ntetris_2003.sh" "$JFFS2_WORK/root/bin/ntetris"

# ls/grep shims that defeat busybox 0.60.5's color-output detection
# by piping through cat (forces isatty(stdout)=0 inside busybox, so
# it omits the SGR escapes nxterm renders literally).  Lighter than
# a sed-strip pass and works without --color=never (busybox 0.60.5
# doesn't grok --color args).
#
# Replace /bin/ls (a symlink to busybox) directly so the shim is
# invoked regardless of PATH lookup — an earlier attempt to drop the
# shim into /usr/bin/ls with /usr/bin first in PATH did not take
# effect (likely a busybox sh path-hash quirk).  /bin/grep
# mirrors the pattern.
rm -f "$JFFS2_WORK/root/bin/ls" "$JFFS2_WORK/root/bin/grep"
# Use a temp file rather than a pipe — BusyBox 0.60.5 sh's pipeline
# appears to hang on this kernel/uClibc combination (observed: the
# ls output truncates partway and the shell never returns to its
# prompt).  Redirecting to a file still defeats isatty(STDOUT) inside
# busybox ls, which is what its color code keys off, so colors stay
# suppressed without the pipe.
cat > "$JFFS2_WORK/root/bin/ls" <<'LS_'
#!/bin/sh
T=/tmp/.ls.$$
/bin/busybox ls "$@" >$T 2>&1
RC=$?
/bin/busybox cat $T
/bin/busybox rm -f $T
exit $RC
LS_
chmod 0755 "$JFFS2_WORK/root/bin/ls"
cat > "$JFFS2_WORK/root/bin/grep" <<'GR_'
#!/bin/sh
T=/tmp/.grep.$$
/bin/busybox grep "$@" >$T 2>&1
RC=$?
/bin/busybox cat $T
/bin/busybox rm -f $T
exit $RC
GR_
chmod 0755 "$JFFS2_WORK/root/bin/grep"

# Diagnostic wrapper for the nxterm-rendering question.  Prints a
# banner BEFORE handing off to /bin/sh -i so we can tell "nxterm is
# silent because the shell is silent" apart from "nxterm doesn't
# render output at all".  Each line is also tee'd to a log on tmpfs
# so the user can recover what was attempted in case the screen
# stays black.
cat > "$JFFS2_WORK/root/usr/bin/mw-diag" <<'DIAG'
#!/bin/sh
exec 1>/tmp/mw-diag.out 2>&1
echo "==== mw-diag start ===="
echo "pid=$$  argv0=$0  stdin tty? $(tty 2>/dev/null || echo no)"
echo "uname: $(uname -a)"
echo "ls /:"
ls /
echo "date: $(date)"
echo "TERM=$TERM"
# Now restore stdio to whatever nxterm gave us (re-open the controlling tty).
exec </dev/tty >/dev/tty 2>/dev/tty
cat /tmp/mw-diag.out
echo "==== handing off to /bin/sh -i ===="
export PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/ USER=root TERM=xterm PS1='# '
exec /bin/sh -i
DIAG
chmod 0755 "$JFFS2_WORK/root/usr/bin/mw-diag"

# Resolver setup: /etc/resolv.conf -> /tmp/resolv.conf (tmpfs at
# runtime), and a static /etc/hosts since the emulator NATs TCP but
# ships no DNS forwarder.  Same content as the pgui path.
ln -sf /tmp/resolv.conf "$JFFS2_WORK/root/etc/resolv.conf"
cat > "$JFFS2_WORK/root/etc/hosts" <<'HOSTS'
127.0.0.1   localhost
93.184.215.14   example.com
93.184.215.14   www.example.com
1.1.1.1     cloudflare cf one.one.one.one
8.8.8.8     dns google-public-dns
208.67.222.222   opendns
HOSTS

# Production mw rcS.  CWD must be "/" when launcher runs because
# /bin/launcher.cnf references icons + binaries with "bin/..."
# prefixes (CWD-relative).  Nano-X opens /dev/fb0 directly (already
# in static devtable as char 29:0) and /dev/tty0 for keyboard input
# via VT raw-kbd ioctls — both are present.  Touch may not work out
# of the box: the 2003 nano-X binary contains no /dev/input or
# /dev/be300tpanel device strings, so its compiled-in mouse driver
# is probably a stub or expects a legacy device path our 4.2.9-style
# patch series doesn't create.  Userspace bridge can come later.
cat > "$JFFS2_WORK/root/etc/init.d/rcS" <<'RCSMW'
#!/bin/sh
/bin/mount -t proc none /proc
/bin/mount -t devpts devpts /dev/pts 2>/dev/null
/bin/mount -t tmpfs -o size=1m tmpfs /tmp 2>/dev/null
/bin/hostname linux4be
/bin/echo "Welcome to Linux4BE (microwindows)"

# Loopback (BusyBox ifconfig 2.4.x does not auto-install 127.0.0.0/8).
/sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up
/sbin/route add -net 127.0.0.0 netmask 255.0.0.0 lo 2>/dev/null

# eth0 (NE2000 at 0x300 IRQ 72 via patches 0013 + ne=0x300,72 cmdline).
# gxemul user-mode NAT: 10.0.0.0/8 with gateway/DNS at 10.0.0.254
# (NOT QEMU 10.0.2.x).  Boot with --ne2000 --net-mac 02:de:ad:be:ef:02.
/sbin/ifconfig eth0 10.0.0.1 netmask 255.0.0.0 up 2>/dev/null
/sbin/route add default gw 10.0.0.254 2>/dev/null
echo 'nameserver 10.0.0.254' > /tmp/resolv.conf
echo 'nameserver 8.8.8.8'    >> /tmp/resolv.conf

# Nano-X expects CWD=/ so launcher.cnf "bin/..." paths resolve.
cd /
# nano-X server: opens /dev/fb0 + /dev/tty0.  -x 240 -y 320 explicitly
# matches the BE-300 LCD geometry; without these flags nano-X 2003 picks
# a default of 320x240 (landscape, palmtop convention) and clients render
# wider than the framebuffer, cutting text off the right edge.  Log to
# /tmp so we can read back why clients fail to connect if the screen
# stays blank.
/bin/nano-X -x 240 -y 320 >/tmp/nano-X.log 2>&1 &
NANOX=$!
# Nano-X creates /tmp/.nano-X (its UNIX-domain socket) once it has
# initialized the screen.  Wait for the socket before launching clients —
# 1-second sleeps weren't long enough; clients failed to connect and
# exited silently, leaving the screen at the nano-X splash.
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S /tmp/.nano-X ] && break
    sleep 1
done
# Window manager.
/bin/nanowm >/tmp/nanowm.log 2>&1 &
sleep 1
# Terminal — full-screen on the 240x320 LCD.  /usr/bin/mw-shell exports
# PS1/TERM/PATH and execs /bin/sh -i.  Requires the BSD pty nodes
# /dev/ptyp0..15 and /dev/ttyp0..15 (added to be300_2_4_devtable.txt) —
# the 2003 nxterm binary hardcodes `/dev/ptyp%d` (no fallback) and was
# silently failing to allocate a pty before those nodes existed.
#
# Empirically the 2003 nxterm IGNORES the `[program {args}]` argv tail
# (verified May 24 2026: mw-shell ran no diagnostics; BusyBox banner
# from /bin/sh -i appeared regardless).  nxterm reads the SHELL env
# var to pick what to launch (strings show `SHELL=` + getenv()), so
# point that at our wrapper.  nxterm also force-sets TERM=vt52 for
# the child; mw-shell re-exports TERM=vt100 to undo that.
export SHELL=/usr/bin/mw-shell
# Touch bridge: /dev/input/event1 -> GrInjectPointerEvent.  Must run
# AFTER nano-X has created /tmp/.nano-X (the bridge retries the connect
# up to 30 x 200 ms internally, but we still gate on the socket file
# above for sanity).
/usr/bin/be300_nxbridge </dev/null >/tmp/nxbridge.log 2>&1 &
# Persistent nxterm from rcS so the user has a guaranteed shell to
# inspect /tmp/mw-launch.log while we debug the launcher-fork-of-
# nxterm crash.
cd /
/bin/nxterm >/tmp/nxterm.log 2>&1 &
sleep 2
# launcher renders the tappable app panel.
/bin/launcher /bin/launcher.cnf >/tmp/launcher.log 2>&1 &
wait $NANOX
RCSMW
chmod 0755 "$JFFS2_WORK/root/etc/init.d/rcS"

# ELF e_flags rewrite (mips32r2 -> mips2) — idempotent for 2003
# binaries which are already pre-2009 format.  Same as pgui path.
echo "--- Rewriting ELF e_flags arch bits for 2.4.18 elf_check_arch ---"
python3 - "$JFFS2_WORK/root" <<'PYEOF'
import os, struct, sys
root = sys.argv[1]
patched = 0
for dirpath, _, files in os.walk(root):
    for fn in files:
        p = os.path.join(dirpath, fn)
        try:
            if os.path.islink(p):
                continue
            with open(p, 'rb') as f:
                head = f.read(40)
            if head[:4] != b'\x7fELF':
                continue
            if head[4] != 1 or head[5] != 1:
                continue
            machine = struct.unpack_from('<H', head, 18)[0]
            if machine != 8:
                continue
            ef = struct.unpack_from('<I', head, 36)[0]
            new = (ef & ~0xF0000000) | 0x10000000
            if new == ef:
                continue
            with open(p, 'r+b') as f:
                f.seek(36)
                f.write(struct.pack('<I', new))
            patched += 1
        except (OSError, struct.error):
            pass
print(f'patched {patched} ELF files (0x70000000 -> 0x10000000)')
PYEOF

# Debug knob: the donor has no /etc/inittab, so BusyBox 0.60.5 runs rcS as
# sysinit and never reaches its console shell (rcS ends in `wait`).
# BE300_MW_SERIAL_SHELL=1 runs rcS as `once` instead and adds an askfirst
# shell on the dock UART (ttyS0, --serial1-bridge; not with
# --stowaway-keyboard, which shares that UART).
if [[ "${BE300_MW_SERIAL_SHELL:-0}" == "1" ]]; then
    cat > "$JFFS2_WORK/root/etc/inittab" <<'INITTAB'
::once:/etc/init.d/rcS
ttyS0::askfirst:/bin/sh
INITTAB
    echo "--- BE300_MW_SERIAL_SHELL=1: askfirst shell on ttyS0 ---"
fi

echo "--- Building JFFS2 image $JFFS2_ROOTFS ---"
mkfs.jffs2 --root="$JFFS2_WORK/root" \
    --devtable="$DEVTABLE_PGUI" \
    --eraseblock=16384 --pagesize=512 --no-cleanmarkers \
    --pad=0xB00000 --little-endian \
    --output="$JFFS2_ROOTFS"
echo "  rootfs : $(ls -la "$JFFS2_ROOTFS" | awk '{print $5, $9}')"
