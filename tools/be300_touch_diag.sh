#!/bin/bash
# Throwaway touch bisection harness for the 2.4 OPIE build.
#
# Boots the emulator with the GUI visible AND --serial1-bridge. After
# OPIE is up it drives the ttyS0 askfirst shell with ONE simple command
# (no shell substitution, which the raw serial line mangles):
#     od -An -tx1 /dev/input/event1
# so every byte the kernel delivers through evdev to userspace streams
# onto the captured serial console while you tap. This bisects:
#   * hex bytes appear on tap  -> kernel+evdev deliver fine; bug is Qt-side
#   * no hex bytes on tap      -> kernel input_event->evdev delivery is the bug
# The kernel's own be300tpdbg poll-tick lines are captured too.
#
# Usage:  ./tools/be300_touch_diag.sh
#   1. Wait for the OPIE launcher AND the on-screen prompt below that
#      says ">>> TAP NOW".
#   2. Tap several launcher icons for ~10-15 s (press AND release).
#   3. Press Q in the emulator window (or close it) to quit.
#   4. Read the summary this prints.
set -u
cd "$(dirname "$0")/.."
NAND=linux-4.2.9/be300-2_4-opie.nand
LOG=/tmp/be300_touch_diag.log
ERR=/tmp/be300_touch_diag.emu.err
: > "$LOG"; : > "$ERR"; rm -f /tmp/be300_touch_diag.armed

echo "[diag] launching emulator (GUI + serial1-bridge)…"
./bin/be300 --nand "$NAND" --speed 0 --detect-stall --serial1-bridge pty:auto 2>"$ERR" &
EMU=$!

PTY=""
for i in $(seq 1 30); do
    PTY=$(grep -oE '/dev/ttys[0-9]+' "$ERR" 2>/dev/null | head -1)
    [ -n "$PTY" ] && break
    sleep 1
done
[ -z "$PTY" ] && { echo "[diag] ERROR no pty"; cat "$ERR"; kill "$EMU" 2>/dev/null; exit 1; }
echo "[diag] serial pty = $PTY  (kernel console -> $LOG)"
stty -f "$PTY" raw 115200 -echo 2>/dev/null || true
cat "$PTY" >> "$LOG" 2>/dev/null &
READER=$!

# Background driver: wait for qpe mainloop, activate askfirst shell,
# then start the raw evdev hexdumper. Bare command only — no $(), no
# quoting that the raw tty would mangle.
(
    for i in $(seq 1 50); do
        grep -qa 'be300-qpe] mainloop' "$LOG" 2>/dev/null && break
        sleep 3
    done
    sleep 3
    printf '\r'                               > "$PTY"; sleep 2
    printf 'od -An -tx1 /dev/input/event1\r'  > "$PTY"; sleep 2
    : > /tmp/be300_touch_diag.armed
) >/dev/null 2>&1 &
DRIVER=$!

echo
echo "  >>> Wait until the file /tmp/be300_touch_diag.armed appears"
echo "  >>> (or ~60 s after the OPIE launcher renders), THEN tap the"
echo "  >>> launcher icons for ~10-15 s (press AND release)."
echo "  >>> Then press Q in the emulator window to finish."
echo

wait "$EMU" 2>/dev/null
kill "$READER" "$DRIVER" 2>/dev/null
sleep 1

echo "=================================================================="
echo "[diag] kernel poll-tick (be300tpdbg) — proves kernel decodes coords:"
grep -a 'be300tpdbg' "$LOG" | sed 's/\r$//' | grep -E 'pg0|pg1|penchg' | tail -8
echo "  kernel tpdbg total: $(grep -ac 'be300tpdbg' "$LOG")"
echo "------------------------------------------------------------------"
echo "[diag] handler chain (min=64 evdev, open>0 => qpe opened event1):"
grep -aE 'be300tpdbg: (chain|  h=)' "$LOG" | sed 's/\r$//' | tail -4
echo "------------------------------------------------------------------"
echo "[diag] evdev probes for /dev/input/event1 (minor 1) — THE answer:"
echo "  OPEN  : $(grep -ac 'evdbg: OPEN min=1'  "$LOG")   $(grep -a 'evdbg: OPEN min=1'  "$LOG" | sed 's/\r$//' | tail -1)"
echo "  EVENT : $(grep -ac 'evdbg: event min=1' "$LOG")   $(grep -a 'evdbg: event min=1' "$LOG" | sed 's/\r$//' | tail -1)"
echo "  POLL  : $(grep -ac 'evdbg: poll min=1'  "$LOG")   $(grep -a 'evdbg: poll min=1'  "$LOG" | sed 's/\r$//' | tail -1)"
echo "  READ  : $(grep -ac 'evdbg: read min=1'  "$LOG")   $(grep -a 'evdbg: read min=1'  "$LOG" | sed 's/\r$//' | tail -1)"
echo "  => OPEN+EVENT but no POLL  : qpe's Qt event loop never select()s event1 (notifier not registered)"
echo "  => OPEN+EVENT+POLL no READ : select sees data but readMouseData slot never dispatched"
echo "  => OPEN+EVENT+POLL+READ    : kernel fully delivers; bug is Qt parse/emit after read"
echo "------------------------------------------------------------------"
echo "[diag] RAW evdev bytes from /dev/input/event1 (od hex lines):"
echo "  ('armed' marker present: $([ -f /tmp/be300_touch_diag.armed ] && echo YES || echo NO))"
# od -An -tx1 lines look like '  03 00 00 00 ...' — capture them after
# the od command echo, excluding shell/qpe noise.
awk '/od -An -tx1 \/dev\/input\/event1/{a=1;next} a' "$LOG" \
  | sed 's/\r$//' \
  | grep -aE '^ +[0-9a-f]{2}( [0-9a-f]{2})+ *$' | tail -30
EVCNT=$(awk '/od -An -tx1 \/dev\/input\/event1/{a=1;next} a' "$LOG" \
  | grep -acE '^ +[0-9a-f]{2}( [0-9a-f]{2})+ *$')
echo "  evdev hex line count: $EVCNT"
echo "------------------------------------------------------------------"
if [ "${EVCNT:-0}" -gt 0 ]; then
  echo "[diag] VERDICT: kernel+evdev DELIVER touch to userspace."
  echo "        => bug is Qt-side (handler/notifier). Next: instrument Qt."
else
  echo "[diag] VERDICT: NO evdev bytes reached userspace despite kernel"
  echo "        decoding coords => bug is in input_event->evdev delivery"
  echo "        (handle->open / EV_SYN gate / forwarding). Next: fix kernel."
fi
echo "[diag] full capture: $LOG"
echo "=================================================================="
