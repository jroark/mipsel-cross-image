#!/usr/bin/env python3
"""Install shared BE-300 hardware support after the versioned patch series.

Only board drivers are adapted. Refuse unknown source layouts and preserve
repeatability on already patched build trees; canonical code stays in board/.
"""
import argparse
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HEADER = '#include <linux/be300_hardware.h>\n'
MARKER = '/* BE300 board hardware integration v1. */\n'

def function_body(text, name, change):
    match = re.search(r'\b' + re.escape(name) + r'\([^;{}]*\)\s*\{', text)
    if not match:
        raise RuntimeError('function not found: ' + name)
    start = match.end()
    depth, end = 1, start
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[:start] + change(text[start:end - 1]) + text[end - 1:]

def inject(body, code):
    """Keep declarations first for the legacy kernel's GNU89 C style."""
    match = re.match(r'\s*(?:(?:(?:static|const|volatile|unsigned|signed)\s+)*(?:struct\s+\w+|int|long|short|char|u[0-9]+|bool)(?:\s|\*)[^;{}\n]*;\s*)*', body)
    at = match.end()
    prefix = body[:at].rstrip()
    return (prefix + '\n\n' if prefix else '\n') + code.strip('\n').rstrip() + '\n\t' + body[at:].lstrip(' \t')

def adapt(path, transform):
    if not path.is_file():
        raise RuntimeError('required source missing: ' + str(path))
    text = path.read_text()
    if MARKER in text:
        return
    if 'BE300 board hardware integration' in text:
        raise RuntimeError('old hardware adaptation; restage a clean kernel tree: ' + str(path))
    updated = transform(text)
    path.write_text(MARKER + ('' if HEADER in updated else HEADER) + updated)

def framebuffer(text, version="4.2"):
    marker = re.search(r'static\s+struct\s+fb_ops\s+\w+\s*=', text)
    if not marker:
        raise RuntimeError('framebuffer operations not found')
    has_blank = bool(re.search(r'\.fb_blank\s*=|\bfb_blank\s*:', text))
    callback = ('static int be300_sfb_blank(int blank, struct fb_info *info)\n'
                '{\n\treturn be300_lcd_blank(blank);\n}\n\n')
    if version == '2.4':
        callback = ('static void be300_sfb_blank(int blank, struct fb_info *info)\n'
                    '{\n\tbe300_lcd_blank(blank);\n}\n\n')
    at = marker.start()
    text = text[:at] + callback + text[at:]
    if version == '2.4':
        # 2.4 has fb_info.blank (void), not fb_ops.fb_blank (int).
        match = re.search(r'(?m)^([ \t]*)([^\n]*register_framebuffer\(&([A-Za-z_][A-Za-z_0-9.]*?)\))', text)
        if not match:
            raise RuntimeError('2.4 framebuffer registration layout needs review')
        line = match[1] + match[3] + '.blank = be300_sfb_blank;\n'
        return text[:match.start()] + line + text[match.start():]
    if has_blank:
        return re.sub(r'(\.fb_blank\s*=\s*|\bfb_blank\s*:\s*)[A-Za-z_][A-Za-z_0-9]*', r'\1be300_sfb_blank', text, count=1)
    return re.sub(r'(static\s+struct\s+fb_ops\s+\w+\s*=\s*\{)',
                  r'\1\n\t.fb_blank = be300_sfb_blank,', text, count=1)

def touch(text):
    # The historical ports swapped the PIU power/sequencer/start bit names.
    values = {'PIUCNT_PIUPWR':'0x0002', 'PIUCNT_PIUSEQEN':'0x0004',
              'PIUCNT_PADATSTART':'0x0100', 'PIUCNT_PADATSTOP':'0x0200'}
    for name, value in values.items():
        text = re.sub(r'(#define\s+' + name + r'\s+)0x[0-9a-fA-F]+[^\n]*',
                      r'\g<1>' + value, text)
    def prepare(body):
        # Reset before allocating/registering input or enabling conversion.
        return inject(body, '\n\tif (be300_piu_prepare())\n\t\treturn -ETIMEDOUT;\n')
    return function_body(text, 'be300_touch_init', prepare)

def irq(text, version):
    init = 'be300_irq_chip_init' if version == '4.2' else 'be300_irq_cascade_init'
    text = function_body(text, init,
        lambda b: inject(b, '\n\tbe300_girq0_init();\n'))
    cascade = 'be300_irq_cascade_init'
    text = function_body(text, cascade,
        lambda b: inject(b, '\n\tbe300_giu0_prepare();\n'))
    if version == '4.2':
        for suffix, helper in [('mask', 'mask'), ('unmask', 'unmask')]:
            text = function_body(text, 'be300_girq0_irq_' + suffix,
                lambda b, h=helper: b + '\n\tbe300_girq0_source_' + h + '(d->irq - VRC4173_IRQ_BASE);\n')
        text = function_body(text, 'be300_girq0_irq_ack',
            lambda b: '\n\tbe300_girq0_source_mask(d->irq - VRC4173_IRQ_BASE);\n')
        text = text.replace('writel(pending, be300_girq0_ack_io);',
                            'be300_girq0_pending_ack(pending);')
    else:
        for suffix, helper in [('startup','unmask'), ('enable','unmask'),
                               ('shutdown','mask'), ('disable','mask')]:
            def add(body, h=helper):
                call = '\n\tbe300_girq0_source_' + h + '(irq - VRC4173_IRQ_BASE);\n'
                if 'return 0;' in body:
                    return body.replace('\treturn 0;', call + '\treturn 0;')
                return body + call
            text = function_body(text, 'be300_girq0_' + suffix, add)
        text = function_body(text, 'girq0_write_ack',
            lambda b: '\n\tbe300_girq0_pending_ack(bits);\n')
    # Preserve context in older port comments, but make the new rule explicit.
    text = ('/* Source controls are per-source words at 0010+4*n; bit 3\n'
            ' * masks/enables. The earlier bitmap-W1C comments below are\n'
            ' * historical emulator assumptions, superseded by hardware.c. */\n' + text)
    return text

def nand(text):
    # Select once per NAND command, not on every transfer-register write.
    modern = 'be300_nand_send_command' in text
    name = 'be300_nand_send_command' if modern else 'nand_send_cmd'
    code = ('\t/* NK/SPL 80F0A654: select the unit explicitly. */\n'
            '\twritel(1, (void *)0xaa001134UL);\n'
            '\twritel(1, (void *)0xaa00a400UL);\n'
            '\twritel(1, (void *)0xaa00a408UL);\n'
            '\twritel(1, (void *)0xaa00a40cUL);\n'
            '\twritel(1, (void *)0xaa00a410UL);\n')
    text = function_body(text, name, lambda b: inject(b, code))
    if modern:
        text = text.replace('be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x03);',
                            'be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x02);\n\tbe300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x03);')
        text = text.replace('be300_nand_xfer_write(BE300_NAND_XFER_ACK, 0);',
                            '(void)be300_nand_xfer_read(BE300_NAND_XFER_ACK);\n\tbe300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x02);')
    else:
        text = text.replace('*XFER_CMD = 0x03;', '*XFER_CMD = 0x02;\n\t*XFER_CMD = 0x03;')
        text = text.replace('*XFER_ACK = 0;', '(void)*XFER_ACK;\n\t*XFER_CMD = 0x02;')
        text = function_body(text, 'nand_send_addr', lambda b: b + '\n\txfer_wait_ready();\n')
        text = text.replace('/* Drain the 8-byte OOB region (we ignore content). */\n\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;',
                            '/* Drain all 16 spare bytes and release the transfer. */\n\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;\n\t*XFER_MODE = 0;\n\t*XFER_CMD = 0;')
    return text

def copy_changed(source, target):
    data = source.read_bytes()
    if not target.exists() or target.read_bytes() != data:
        target.write_bytes(data)

def install(tree, version):
    board = tree / ('arch/mips/vr41xx/vr4131/casio-be300' if version == '2.4'
                    else 'arch/mips/vr41xx/casio-be300')
    if not board.is_dir():
        raise RuntimeError('BE-300 board patch series must be applied first')
    source = REPO / 'board/casio-be300'
    for name in ['hardware.c', 'hardware.h', 'hardware-regs.h']:
        copy_changed(source / name, board / name)
    copy_changed(source / 'hardware.h', tree / 'include/linux/be300_hardware.h')
    makefile = board / 'Makefile'
    text = makefile.read_text()
    if 'hardware.o' not in text:
        text, count = re.subn(r'(obj-y\s*[:+]?=\s*)', r'\1hardware.o ', text, count=1)
        if not count:
            raise RuntimeError('board obj-y not found')
        makefile.write_text(text)
    fb = board / 'sfb.c' if version == '4.2' else tree / 'drivers/video/sfb.c'
    adapt(fb, lambda s: framebuffer(s, version))
    adapt(board / ('touch.c' if version == '2.6' else 'touch_be300.c'), touch)
    adapt(board / ('irq_be300.c' if version == '2.4' else 'irq.c'),
          lambda s: irq(s, version))
    adapt(board / ('nand_be300.c' if version == '2.4' else 'nand.c'), nand)
    print('BE-300 hardware support staged for Linux ' + version)

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('tree', type=Path)
    p.add_argument('--kernel', choices=['2.4','2.6','4.2'], required=True)
    a = p.parse_args()
    try:
        install(a.tree.resolve(), a.kernel)
    except (OSError, RuntimeError) as e:
        p.exit(1, 'hardware staging failed: ' + str(e) + '\n')
