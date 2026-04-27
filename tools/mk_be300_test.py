#!/usr/bin/env python3
"""Build a minimal B000FF test NAND image: spin printing 'L' on the VRC4173 SIU.

This is a debugging tool, not part of the kernel build. It produces the same
structure as mk_be300_nand.py but with a hand-coded 14-instruction MIPS payload
instead of vmlinux, so we can isolate B000FF-format / boot-ROM issues from
kernel issues.

Layout matches the WinCE SPL container exactly:
  image_start = 0x80F00000, entry_va = 0x80F00004.
"""

import struct
import sys
from pathlib import Path

NAND_SIZE = 16 * 1024 * 1024
B000FF_OFFSET = 0x4000
LOAD_VA = 0x80F00000
ENTRY_VA = 0x80F00004

# UART base 0xAA008680 (VRC4173 SIU THR register, addr_mult=4 so reg 0 = base).
def insn(word: int) -> bytes:
    return struct.pack("<I", word & 0xFFFFFFFF)

# MIPS32 little-endian instruction encodings (hand-assembled).
# t0 = $8, t1 = $9. Opcode/rs/rt/imm bit layout per MIPS ISA reference.
LUI_T0_AA00   = 0x3C08AA00         # lui  $t0, 0xAA00
ORI_T0_8680   = 0x35088680         # ori  $t0, $t0, 0x8680  (t0 = 0xAA008680)
def addiu_t1(imm): return 0x24090000 | (imm & 0xFFFF)  # addiu $t1, $0, imm
SB_T1_T0      = 0xA1090000         # sb   $t1, 0($t0)
B_SELF        = 0x1000FFFF         # b   . (BEQ $0,$0,-1)
NOP           = 0x00000000

payload = b"".join(insn(w) for w in [
    NOP,                  # 0x80F00000  (sentinel; record 6 in WinCE was nop)
    LUI_T0_AA00,          # 0x80F00004  ENTRY: t0 = 0xAA000000
    ORI_T0_8680,          # 0x80F00008  t0 = 0xAA008680 (VRC4173 SIU THR)
    addiu_t1(ord('L')),   # 0x80F0000C
    SB_T1_T0,             # 0x80F00010  *t0 = 'L'
    addiu_t1(ord('i')),
    SB_T1_T0,
    addiu_t1(ord('v')),
    SB_T1_T0,
    addiu_t1(ord('e')),
    SB_T1_T0,
    addiu_t1(ord('!')),
    SB_T1_T0,
    addiu_t1(ord('\n')),
    SB_T1_T0,
    B_SELF,               # 0x80F00038  branch to self
    NOP,                  # 0x80F0003C  delay slot
])

records = bytearray()
records += struct.pack("<III", LOAD_VA, len(payload), 0xFFFFFFFF)
records += payload
# Terminator: 4-byte zero sentinel + (entry_va, 0, 0xFFFFFFFF), matching the
# WinCE SPL container layout exactly.
records += b"\x00\x00\x00\x00"
records += struct.pack("<III", ENTRY_VA, 0, 0xFFFFFFFF)

container = b"B000FF\n" + struct.pack("<II", LOAD_VA, len(records)) + bytes(records)

image = bytearray([0xFF]) * NAND_SIZE
image[B000FF_OFFSET:B000FF_OFFSET + len(container)] = container

# Partition table at page 0 (matches WinCE's layout — see mk_be300_nand.py
# for the rationale). Entry 1 must have a valid (start_sector, count)
# pair for the ROM walker's state-2 probe to fire.
container_sectors = (len(container) + 511) // 512
struct.pack_into("<II", image, 0 * 16 + 8, 0, 0x20)  # entry 0
struct.pack_into("<II", image, 1 * 16 + 8, B000FF_OFFSET // 512, container_sectors)

out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("test.nand")
out.write_bytes(image)
print(
    f"[mk_be300_test] {out}: payload={len(payload)} bytes, "
    f"records_total=0x{len(records):X}, entry=0x{ENTRY_VA:08X}"
)
