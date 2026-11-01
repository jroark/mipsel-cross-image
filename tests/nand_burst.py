#!/usr/bin/env python3
"""Host checks for NAND burst boundaries and staged-driver upgrades."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer', REPO / 'scripts/install_board_hardware.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def body(text, name):
    result = []
    installer.function_body(text, name, lambda b: result.append(b) or b)
    return result[0]


class BurstTests(unittest.TestCase):
    def test_legacy_fresh_and_upgrade(self):
        for version in ('2.4.18', '2.6.8.1'):
            patches = sorted((REPO / ('patches/linux-' + version + '-be300')).glob('*.patch'))
            text = '\n'.join(p.read_text() for p in patches)
            # Reconstruct the added NAND driver from its patch, independently
            # of the generated kernel trees available on this machine.
            start = text.index('+static void be300_read_raw_page')
            end = text.index('\n+}', start) + 3
            function = '\n'.join(line[1:] for line in text[start:end].splitlines())
            old = '/* Drain the 8-byte OOB region (we ignore content). */\n' + ('\t(void)*STREAM_PORT;\n' * 2).rstrip()
            staged = function.replace(old,
                '/* Drain all 16 spare bytes and release the transfer. */\n' +
                '\t(void)*STREAM_PORT;\n' * 4 +
                '\t*XFER_MODE = 0;\n\t*XFER_CMD = 0;')
            for candidate in (function, staged):
                updated = installer.nand_drain(candidate)
                self.assertEqual(updated, installer.nand_drain(updated))
                read = body(updated, 'be300_read_raw_page')
                self.assertEqual(read.count('(void)*STREAM_PORT;'), 4)
                before, after = read.split('*XFER_MODE = 0x04;')
                self.assertEqual(before.count('(void)*STREAM_PORT;'), 2)
                self.assertEqual(after.count('(void)*STREAM_PORT;'), 2)

    def test_modern_split_and_skip(self):
        text = (REPO / 'board/casio-be300/nand.c').read_text()
        # Compile the actual byte/skip functions with a strict stream model.
        code = '''
#include <assert.h>
#include <stdint.h>
typedef uint8_t u8;
static unsigned be300_nand_read_pos, cursor, mode, transitions;
#define BE300_NAND_PAGE_DATA 512
#define BE300_NAND_PAGE_RAW 528
#define BE300_NAND_MODE_READ_OOB2 4
#define BE300_NAND_XFER_MODE 0
static void *be300_nand_stream_io;
static void be300_nand_xfer_write(unsigned off, unsigned value) {
 (void)off; assert(cursor == 520); assert(value == 4);
 mode = value; transitions++;
}
static void be300_nand_wait_xfer_ready(void) {}
static u8 readb(void *io) {
 (void)io; assert(cursor < 528); assert(cursor < 520 || mode == 4);
 return (u8)cursor++;
}
static uint32_t readl(void *io) {
 unsigned i; uint32_t result = 0;
 assert(cursor + 4 <= 520);
 for (i = 0; i < 4; i++) result |= (uint32_t)readb(io) << (8 * i);
 return result;
}
'''
        for name, args, ret in [('be300_nand_stream_read_byte', 'void', 'u8'),
                                ('be300_nand_discard_stream', 'unsigned int len', 'void')]:
            code += 'static ' + ret + ' ' + name + '(' + args + ') {' + body(text, name) + '}\n'
        code += '''
int main(void) {
 unsigned page, i;
 for (page = 0; page < 3; page++) {
  cursor = be300_nand_read_pos = transitions = 0; mode = 5;
  be300_nand_discard_stream(page == 0 ? 0 : page == 1 ? 256 : 512);
  while (cursor < 519) (void)be300_nand_stream_read_byte();
  assert(transitions == 0);
  assert(be300_nand_stream_read_byte() == (u8)519);
  assert(transitions == 0);
  for (i = 520; i < 528; i++) assert(be300_nand_stream_read_byte() == (u8)i);
  assert(transitions == 1); assert(be300_nand_read_pos == 528);
  assert(be300_nand_stream_read_byte() == 0xff); assert(cursor == 528);
 }
 cursor = be300_nand_read_pos = transitions = 0; mode = 5;
 be300_nand_discard_stream(528); assert(transitions == 1);
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'check.c'
            source.write_text(code)
            binary = Path(tmp) / 'check'
            subprocess.run(['cc', '-std=gnu89', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
