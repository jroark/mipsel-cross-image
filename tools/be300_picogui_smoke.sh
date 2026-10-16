#!/bin/bash
# PicoGUI (4.2.9) smoke test: tap reliability, app launch, redraw-on-close.
#
# The emulator has no scripted touch input, so this drives the guest over
# the ttyVR0 serial shell (--serial0-bridge) and uses /usr/bin/be300-tap
# (board/picogui/be300-tap.c) on the target to inject evdev taps and to
# hash framebuffer rows below omnibar's toolbar.  omnibar's clock and load
# meter repaint every second, so whole-screen checksums never settle.
#
# Checks:
#   taps     tap omnibar's Applications button N times; each tap must open
#            the menu (client area changes) and the dismiss tap must restore
#            the client area exactly
#   flood    one tap whose press is buried under a queue overflow
#            (be300-tap --flood) must still open the menu
#   apps     launch each .app from the shell, it must stay alive and change
#            the client area; killing it must restore the client area
#   menu     tap Applications, then the canvastst item; canvastst must run
#
# Usage: tools/be300_picogui_smoke.sh [nand]   (exit 0 = all passed)
# Env:   BE300_SMOKE_TAPS (default 20), BE300_SMOKE_DIR (default /tmp/...),
#        BE300_SMOKE_APPS_X/_Y, BE300_SMOKE_DISMISS_X/_Y, BE300_SMOKE_Y0
set -u
cd "$(dirname "$0")/.."

NAND=${1:-linux-4.2.9/be300-picogui.nand}
OUT=${BE300_SMOKE_DIR:-/tmp/be300_picogui_smoke}
TAPS=${BE300_SMOKE_TAPS:-20}
# Geometry on the 240x320 LCD, measured from the stock profile's screen.
APPS_X=${BE300_SMOKE_APPS_X:-40}        # omnibar "Applications" button
APPS_Y=${BE300_SMOKE_APPS_Y:-16}
DISMISS_X=${BE300_SMOKE_DISMISS_X:-200} # empty area outside the menu
DISMISS_Y=${BE300_SMOKE_DISMISS_Y:-280}
Y0=${BE300_SMOKE_Y0:-36}                # first row below the toolbar
MENU_ITEM_X=${BE300_SMOKE_MENU_ITEM_X:-40} # "canvastst" in the Applications
MENU_ITEM_Y=${BE300_SMOKE_MENU_ITEM_Y:-80} # menu (JFFS2 readdir order)
APPS="pterm atomicnav pgboard canvastst pg-keytest tpcal pg-desktop"

mkdir -p "$OUT"
LOG=$OUT/serial.log
ERR=$OUT/emu.err
: > "$LOG"; : > "$ERR"

# The emulator writes guest NAND writes (JFFS2 is mounted rw) back into the
# image file; boot a scratch copy so the build output stays pristine.
cp "$NAND" "$OUT/smoke.nand"
SDL_VIDEODRIVER=dummy ./bin/be300 --nand "$OUT/smoke.nand" --speed 0 --detect-stall \
    --serial0-bridge pty:auto 2>"$ERR" &
EMU=$!
READER=
cleanup() {
    [ -n "$READER" ] && kill "$READER" 2>/dev/null
    kill "$EMU" 2>/dev/null
    wait "$EMU" 2>/dev/null
}
trap cleanup EXIT

PTY=
for _ in $(seq 1 30); do
    PTY=$(grep -oE '/dev/ttys[0-9]+' "$ERR" 2>/dev/null | head -1)
    [ -n "$PTY" ] && break
    sleep 1
done
[ -z "$PTY" ] && { echo "no serial pty"; cat "$ERR"; exit 1; }
stty -f "$PTY" raw -echo 2>/dev/null || stty -F "$PTY" raw -echo
cat "$PTY" >> "$LOG" &
READER=$!

wait_for() {  # wait_for <ERE> <seconds>
    local i
    for i in $(seq 1 "$2"); do
        grep -qE "$1" "$LOG" && return 0
        sleep 1
    done
    return 1
}

N=0
# run <command> [timeout]: run on the target, wait for its completion marker.
run() {
    N=$((N + 1))
    printf '%s; echo "@@"%d"@@"\r' "$1" "$N" > "$PTY"
    wait_for "@@$N@@" "${2:-60}"
}

# fbsum <tag>: set SUM to the hash of the client area as the target sees
# it now.  (Not a $(...) helper: run must bump N in this shell.)
SUM=
fbsum() {
    SUM=
    run "echo $1=\$(be300-tap --fbsum $Y0 320)" || return 1
    SUM=$(grep -aoE "$1=[0-9a-f]{8}" "$LOG" | tail -1 | cut -d= -f2)
}

# kill_app <name>: BusyBox awk rejects bracket tricks like '[/]'.
kill_app() {
    run "kill \$(ps | awk -v a=/usr/bin/$1 'index(\$0,a) && !index(\$0,\"awk\") {print \$1}') 2>/dev/null; sleep ${2:-4}"
}

echo "[smoke] booting $NAND (serial $PTY)"
# The kernel console is tty0, so start-picogui's /dev/kmsg progress never
# reaches the serial line; poll from the shell instead.
wait_for 'press Enter to activate' 240 || { echo "[smoke] no serial console"; exit 1; }
printf '\r' > "$PTY"
sleep 2
run 'export PATH=/usr/bin:/bin:/sbin:/usr/sbin PGSERVER=/var/tmp/.pgui LD_LIBRARY_PATH=/usr/lib:/lib' \
    || { echo "[smoke] serial shell unresponsive"; exit 1; }
up=no
for _ in $(seq 1 60); do
    run "ps | grep -q '[/]usr[/]bin[/]omnibar' && ps | grep -q '[/]usr[/]bin[/]pterm' && echo UI_UP=yes; sleep 2"
    grep -aq 'UI_UP=yes' "$LOG" && { up=yes; break; }
done
[ "$up" = yes ] || { echo "[smoke] UI never came up"; exit 1; }
sleep 10

# pterm's blinking cursor would keep the client area from settling.
kill_app pterm 3
fbsum base; base=$SUM
echo "[smoke] client-area baseline $base"

fail=0

opened=0; restored=0
for i in $(seq 1 "$TAPS"); do
    run "be300-tap $APPS_X $APPS_Y; sleep 2"
    fbsum t${i}a; s1=$SUM
    [ "$s1" != "$base" ] && opened=$((opened + 1))
    run "be300-tap $DISMISS_X $DISMISS_Y; sleep 2"
    fbsum t${i}b; s2=$SUM
    [ "$s2" = "$base" ] && restored=$((restored + 1))
    base=$s2
done
echo "[smoke] taps: menu opened $opened/$TAPS, closed cleanly $restored/$TAPS"
[ "$opened" -eq "$TAPS" ] && [ "$restored" -eq "$TAPS" ] || fail=1

run "be300-tap --flood 200 $APPS_X $APPS_Y; sleep 2"
fbsum flood; s1=$SUM
if [ "$s1" != "$base" ]; then echo "[smoke] flood tap: ok"; else echo "[smoke] flood tap: LOST"; fail=1; fi
run "be300-tap $DISMISS_X $DISMISS_Y; sleep 2"
fbsum base2; base=$SUM

for app in $APPS; do
    # The .app wrappers exec the binary, so $! is the app's own pid (killing
    # by name would also take out the boot-time pg-desktop).
    run "/usr/share/picogui/appmenu/$app.app >/tmp/smoke-$app.log 2>&1 & echo \$! >/tmp/smoke.pid; sleep 6"
    alive=no
    run "kill -0 \$(cat /tmp/smoke.pid) && echo ALIVE_$app=yes"
    grep -aq "ALIVE_$app=yes" "$LOG" && alive=yes
    fbsum up_${app//-/_}; s1=$SUM
    visible=no; [ "$s1" != "$base" ] && visible=yes
    run "kill \$(cat /tmp/smoke.pid); sleep 4"
    fbsum down_${app//-/_}; s2=$SUM
    clean=no; [ "$s2" = "$base" ] && clean=yes
    echo "[smoke] $app: alive=$alive visible=$visible restored=$clean"
    [ "$alive$visible$clean" = yesyesyes ] || fail=1
    base=$s2
done

# Launch through the real menu: tap Applications, then the menu item.
run "be300-tap $APPS_X $APPS_Y; sleep 3; be300-tap $MENU_ITEM_X $MENU_ITEM_Y; sleep 8"
run "ps | grep -q '[c]anvastst' && echo MENU_LAUNCH=yes"
if grep -aq 'MENU_LAUNCH=yes' "$LOG"; then
    echo "[smoke] menu launch (canvastst): ok"
else
    echo "[smoke] menu launch (canvastst): FAILED"; fail=1
fi

grep -a 'BE300_STALL' "$ERR" | tail -3
echo "[smoke] serial log: $LOG"
[ "$fail" -eq 0 ] && echo "[smoke] PASS" || echo "[smoke] FAIL"
exit "$fail"
