#!/usr/bin/env python3
"""End-to-end test of /dev/ttyBEU0 (board/casio-be300/usb_serial.c) on the
emulator's USB function controller.

The emulator exposes the controller as a usbredir device
(--pcconnect-dock usb-sync --pcconnect-bridge tcp:...). This script is the
host: it accepts that connection, waits for enumeration, selects the
configuration and sets DTR (CDC SET_CONTROL_LINE_STATE), sends a line to
EP2 OUT and waits for the guest's reply on EP1 IN. The guest is driven over
the ttyVR0 serial shell (--serial0-bridge). The usbredir peer follows
glaze-os tests/usb_runtime.py.

Usage: tools/be300_usb_serial_test.py <4.2 nand> [--emulator bin/be300]
Exit 0 when both directions carried their line.
"""
import argparse
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


class Peer:
    def __init__(self, sock):
        self.sock, self.ident, self.offered = sock, 0, False

    def send(self, kind, data=b""):
        self.ident += 1
        self.sock.sendall(struct.pack("<III", kind, len(data), self.ident) + data)
        return self.ident

    def exact(self, n):
        data = bytearray()
        while len(data) < n:
            b = self.sock.recv(n - len(data))
            if not b:
                raise RuntimeError("usbredir connection closed")
            data += b
        return bytes(data)

    def packet(self):
        kind, n, ident = struct.unpack("<III", self.exact(12))
        data = self.exact(n)
        if kind == 1:
            self.offered = True
        elif kind == 2:
            self.offered = False
        return kind, ident, data

    def response(self, kind, ident):
        while True:
            k, i, data = self.packet()
            if (k, i) == (kind, ident):
                return data

    def configure(self):
        i = self.send(6, b"\x01")                     # set_configuration 1
        assert self.response(8, i)[0] == 0
        h = struct.pack("<BBBBHHH", 0, 0x22, 0x21, 0, 3, 0, 0)  # DTR|RTS
        i = self.send(100, h)
        assert self.response(100, i)[3] == 0

    def write(self, data):
        i = self.send(101, struct.pack("<BBHIH", 2, 0, len(data), 0, 0) + data)
        assert self.response(101, i)[1] == 0

    def read(self):
        i = self.send(101, struct.pack("<BBHIH", 0x81, 0, 4096, 0, 0))
        data = self.response(101, i)
        return data[10:] if data[1] == 0 else b""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("nand", type=Path)
    ap.add_argument("--emulator", type=Path,
                    default=Path(__file__).resolve().parents[1] / "bin/be300")
    a = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="be300-usb-"))
    shutil.copyfile(a.nand, work / "run.nand")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(60)
    err = open(work / "emu.log", "wb")
    emu = subprocess.Popen(
        [str(a.emulator), "--nand", str(work / "run.nand"), "--speed", "0",
         "--serial0-bridge", "pty:auto", "--pcconnect-dock", "usb-sync",
         "--pcconnect-bridge", f"tcp:127.0.0.1:{listener.getsockname()[1]}"],
        cwd=work, env=dict(os.environ, SDL_VIDEODRIVER="dummy"),
        stdout=subprocess.DEVNULL, stderr=err)
    ok = {"host_rx": False, "guest_rx": False}
    try:
        sock, _ = listener.accept()
        sock.settimeout(300)
        peer = Peer(sock)
        peer.send(0, b"be300-usb-serial-test".ljust(64, b"\0") + struct.pack("<I", 0x52))
        pty = None
        for _ in range(60):
            m = re.search(rb"/dev/ttys\d+", (work / "emu.log").read_bytes())
            if m:
                pty = m.group().decode()
                break
            time.sleep(1)
        if not pty:
            raise RuntimeError("no serial pty")
        subprocess.run(["stty", "-f", pty, "raw", "-echo"], check=True)
        tty = os.open(pty, os.O_RDWR | os.O_NOCTTY)
        log = bytearray()

        def reader():
            while True:
                try:
                    b = os.read(tty, 4096)
                except OSError:
                    return
                if not b:
                    return
                log.extend(b)
        threading.Thread(target=reader, daemon=True).start()

        def wait_for(pattern, secs):
            end = time.monotonic() + secs
            while time.monotonic() < end:
                if re.search(pattern, bytes(log)):
                    return True
                time.sleep(0.5)
            return False

        def run(cmd):
            os.write(tty, cmd.encode() + b"\r")

        if not wait_for(rb"press Enter to activate", 300):
            raise RuntimeError("no serial console")
        os.write(tty, b"\r")
        time.sleep(2)
        end = time.monotonic() + 120
        while not peer.offered and time.monotonic() < end:
            peer.packet()
        if not peer.offered:
            raise RuntimeError("device did not enumerate")
        peer.configure()
        # Guest: raw line, collect what the host sends, then answer.
        run("stty -F /dev/ttyBEU0 raw -echo; (cat /dev/ttyBEU0 > /tmp/usbrx &); "
            "echo @@READY@@")
        if not wait_for(rb"@@READY@@\r?\n", 60):
            raise RuntimeError("guest shell did not answer")
        time.sleep(2)
        peer.write(b"ping-from-host\n")
        run("for i in 1 2 3 4 5 6 7 8 9 10; do grep -q ping /tmp/usbrx && break; "
            "sleep 1; done; echo RX=$(cat /tmp/usbrx); "
            "echo hello-from-be300 > /dev/ttyBEU0; echo @@SENT@@")
        if wait_for(rb"RX=ping-from-host", 60):
            ok["guest_rx"] = True
        got = bytearray()
        end = time.monotonic() + 60
        while time.monotonic() < end and b"hello-from-be300" not in got:
            got += peer.read()
            time.sleep(0.2)
        ok["host_rx"] = b"hello-from-be300" in got
        print("guest received host line:", ok["guest_rx"])
        print("host received guest line:", ok["host_rx"], bytes(got)[:64])
        run("dmesg | grep -i ttyBEU")
        wait_for(rb"ttyBEU0\r?\n", 20)
        print(bytes(log).decode(errors="replace").splitlines()[-3:])
    finally:
        emu.terminate()
        try:
            emu.wait(timeout=10)
        except subprocess.TimeoutExpired:
            emu.kill()
    return 0 if all(ok.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
