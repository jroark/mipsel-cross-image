#!/usr/bin/env python3
"""Install shared BE-300 hardware support after the versioned patch series.

Only board drivers are adapted. Refuse unknown source layouts and preserve
repeatability on already patched build trees; canonical code stays in board/.
"""
import argparse
import os
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HEADER = '#include <linux/be300_hardware.h>\n'
MARKER = '/* BE300 board hardware integration v1. */\n'

def function_body(text, name, change):
    match = re.search(r'\b' + re.escape(name) + r'\([^;{}()]*\)\s*\{', text)
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
    match = re.match(r'\s*(?:(?:(?:static|const|volatile)\s+)*(?:(?:unsigned|signed)(?:\s+(?:int|long|short|char))?|struct\s+\w+|int|long|short|char|u[0-9]+|bool)(?:\s|\*)[^;{}\n]*;\s*)*', body)
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

def touch_scan_upgrade(path, version):
    if version == '4.2':
        return
    text = path.read_text()
    if 'BE300 PIU hardware scan v2' in text:
        return
    text, count = re.subn(r'\*PIU_CNTREG = PIUCNT_PIUPWR \| PIUCNT_PIUSEQEN \|\s*PIUCNT_PADATSTART;',
                          'be300_piu_start();', text)
    if not count:
        raise RuntimeError('legacy PIU startup needs review')
    text, count = re.subn(r'\*PIU_INTREG = \(mask << 8\) \| eff;',
                          'be300_piu_ack(status);', text)
    if not count:
        raise RuntimeError('legacy PIU acknowledgement needs review')
    path.write_text('/* BE300 PIU hardware scan v2. */\n' + text)

def touch_filter_upgrade(path, version):
    """Route the legacy PIU drivers' samples through touch_filter.h."""
    if version == '4.2':
        return
    text = path.read_text()
    if 'BE300 touch filter v1' in text:
        return
    pages = {}
    if version == '2.6':
        old = (
            '\tif (eff & PIUINT_PADPAGE0INTR) {\n'
            '\t\tdecode_page(PIU_PB00, &x, &y);\n'
            '\t\tbe300_ts_report(x, y, 1);\n'
            '\t}\n'
            '\tif (eff & PIUINT_PADPAGE1INTR) {\n'
            '\t\tdecode_page(PIU_PB10, &x, &y);\n'
            '\t\tbe300_ts_report(x, y, 1);\n'
            '\t}\n'
            '\tif (eff & PIUINT_PENCHGINTR)\n'
            '\t\tbe300_ts_report(x, y, !!(*PIU_CNTREG & PIUCNT_PEN_DETECTED));\n')
        new = (
            '\tif ((eff & PIUINT_PENCHGINTR) && (*PIU_CNTREG & PIUCNT_PEN_DETECTED))\n'
            '\t\tbe300_stroke_pen_change(&be300_stroke, 1, be300_ts_report);\n'
            '\tif ((eff & PIUINT_PADPAGE0INTR) && be300_page_valid(PIU_PB00)) {\n'
            '\t\tdecode_page(PIU_PB00, &x, &y);\n'
            '\t\tbe300_stroke_sample(&be300_stroke, x, y, be300_ts_report);\n'
            '\t}\n'
            '\tif ((eff & PIUINT_PADPAGE1INTR) && be300_page_valid(PIU_PB10)) {\n'
            '\t\tdecode_page(PIU_PB10, &x, &y);\n'
            '\t\tbe300_stroke_sample(&be300_stroke, x, y, be300_ts_report);\n'
            '\t}\n'
            '\tif ((eff & PIUINT_PENCHGINTR) && !(*PIU_CNTREG & PIUCNT_PEN_DETECTED))\n'
            '\t\tbe300_stroke_pen_change(&be300_stroke, 0, be300_ts_report);\n')
        anchor = 'static void be300_ts_poll(unsigned long data)'
        glue = 'static struct be300_stroke be300_stroke;\n\n'
    else:
        old = (
            '\tif (eff & PIUINT_PADPAGE0INTR) {\n'
            '\t\tdecode_page(PIU_PB00, &x, &y);\n'
            '\t\tpush_event(x, y, 1);\n'
            '\t\tbe300_ts_report(x, y, 1);\n'
            '\t}\n'
            '\tif (eff & PIUINT_PADPAGE1INTR) {\n'
            '\t\tdecode_page(PIU_PB10, &x, &y);\n'
            '\t\tpush_event(x, y, 1);\n'
            '\t\tbe300_ts_report(x, y, 1);\n'
            '\t}\n'
            '\tif (eff & PIUINT_PENCHGINTR) {\n'
            '\t\tcnt = *PIU_CNTREG;\n'
            '\t\tpen = !!(cnt & PIUCNT_PEN_DETECTED);\n'
            '\t\ttp.pen_down = pen;\n'
            '\t\tpush_event(x, y, pen);\n'
            '\t\tbe300_ts_report(x, y, pen);\n'
            '\t}\n')
        new = (
            '\tcnt = *PIU_CNTREG;\n'
            '\tpen = !!(cnt & PIUCNT_PEN_DETECTED);\n'
            '\tif ((eff & PIUINT_PENCHGINTR) && pen)\n'
            '\t\tbe300_stroke_pen_change(&be300_stroke, 1, be300_ts_out);\n'
            '\tif ((eff & PIUINT_PADPAGE0INTR) && be300_page_valid(PIU_PB00)) {\n'
            '\t\tdecode_page(PIU_PB00, &x, &y);\n'
            '\t\tbe300_stroke_sample(&be300_stroke, x, y, be300_ts_out);\n'
            '\t}\n'
            '\tif ((eff & PIUINT_PADPAGE1INTR) && be300_page_valid(PIU_PB10)) {\n'
            '\t\tdecode_page(PIU_PB10, &x, &y);\n'
            '\t\tbe300_stroke_sample(&be300_stroke, x, y, be300_ts_out);\n'
            '\t}\n'
            '\tif ((eff & PIUINT_PENCHGINTR) && !pen)\n'
            '\t\tbe300_stroke_pen_change(&be300_stroke, 0, be300_ts_out);\n')
        anchor = 'static void be300_touch_poll_tick(unsigned long _data)'
        glue = ('static struct be300_stroke be300_stroke;\n\n'
                '/* Filtered strokes feed both the misc queue and evdev. */\n'
                'static void be300_ts_out(int x, int y, int down)\n{\n'
                '\ttp.pen_down = down;\n'
                '\tpush_event(x, y, down);\n'
                '\tbe300_ts_report(x, y, down);\n}\n\n')
    if text.count(old) != 1 or text.count(anchor) != 1 or text.count('static int adc_valid(') != 1:
        raise RuntimeError(f'legacy {version} PIU report path needs review')
    text = text.replace(old, new)
    text = text.replace(anchor, glue + anchor)
    text = text.replace('static int adc_valid(', '#include "touch_filter.h"\n\nstatic int adc_valid(', 1)
    path.write_text('/* BE300 touch filter v1. */\n' + text)

def touch_icons_upgrade(path, version):
    """Scale the legacy PIU drivers to the 360-row panel so strokes that
    start on the hard-icon strip reach touch_filter.h, which turns them
    into be300_hard_icon() calls instead of pointer events."""
    if version == '4.2':
        return
    text = path.read_text()
    if 'BE300 hard icons v1' in text:
        return
    text, count = re.subn(r'#define BE300_TOUCH_PANEL_HEIGHT\s+359\b',
                          '#define BE300_TOUCH_PANEL_HEIGHT\t360', text)
    if count != 1:
        raise RuntimeError(f'legacy {version} touch panel height needs review')
    # touch_filter.h clamps pointer strokes to the LCD; strip rows must pass.
    text, count = re.subn(r'\n\tif \(y >= BE300_TOUCH_HEIGHT\)\n\t\ty = BE300_TOUCH_HEIGHT - 1;',
                          '', text)
    if count != 1:
        raise RuntimeError(f'legacy {version} touch clamp needs review')
    old = 'static struct be300_stroke be300_stroke;\n'
    if text.count(old) != 1:
        raise RuntimeError(f'legacy {version} touch stroke state needs review')
    text = text.replace(old, 'static struct be300_stroke be300_stroke = {\n'
                        '\t.icon_out = be300_hard_icon,\n};\n')
    path.write_text('/* BE300 hard icons v1. */\n' + text)

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

def nand_drain(text):
    # Drain all 16 spare bytes as the ROM (9FC01A98-1AAE) does: after the
    # ROM's NAND boot a MODE-5 burst ends at 520 bytes and a further read
    # hangs a real BE-300 for good; MODE 4 streams the last 8.
    drain = ('/* Drain all 16 spare bytes as the ROM does: 8 in MODE 5, the last 8\n'
             '\t * in MODE 4 (a 9th MODE-5 word hangs the bus), then release. */\n'
             '\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;\n\t*XFER_MODE = 0x04;\n'
             '\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;\n\t*XFER_MODE = 0;\n\t*XFER_CMD = 0;')
    text = text.replace('/* Drain the 8-byte OOB region (we ignore content). */\n\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;', drain)
    # Trees an earlier install drained in MODE 5 alone.
    text = text.replace('/* Drain all 16 spare bytes and release the transfer. */\n\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;\n\t(void)*STREAM_PORT;\n\t*XFER_MODE = 0;\n\t*XFER_CMD = 0;', drain)
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
        text = nand_drain(text)
    return text

def console(text, names):
    # A power-on leaves the companion SIU's clock gate off, and touching a
    # gated unit stalls the bus for good: power its units on before the
    # first console access (hardware.c be300_console_ready).
    found = False
    for name in names:
        if re.search(r'\b' + re.escape(name) + r'\([^;{}()]*\)\s*\{', text):
            text = function_body(text, name,
                lambda b: inject(b, '\n\tbe300_console_ready();\n'))
            found = True
    if not found:
        raise RuntimeError('early console layout needs review: ' + ', '.join(names))
    return text

# Objects that must really link on 2.4. audio.o and wifi.o are appended
# after the include too and so have never been built there: audio.c needs
# <asm/cacheflush.h>, which 2.4 lacks, and neither has been ported.
RULES_MAKE_OBJECTS = ('buzzer.o', 'hard_icons.o')

def rules_make_order(text):
    """Linux 2.4's Rules.make reads obj-y when it is included: objects
    appended after `include $(TOPDIR)/Rules.make` are silently never built.
    Move the RULES_MAKE_OBJECTS lines in front of the include."""
    include = 'include $(TOPDIR)/Rules.make'
    if include not in text:
        return text
    head, tail = text.split(include, 1)
    moved = [l for l in tail.splitlines() if re.match(r'obj-\S*\s*[:+]?=', l)
             and any(o in l for o in RULES_MAKE_OBJECTS)]
    if not moved:
        return text
    rest = [l for l in tail.splitlines() if l not in moved]
    return (head.rstrip('\n') + '\n\n' + '\n'.join(moved) + '\n\n' + include +
            '\n'.join(rest).rstrip('\n') + '\n')

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
    for name in ['hardware.c', 'hardware.h', 'hardware-regs.h', 'audio.c', 'audio-regs.h', 'wifi.c', 'wifi-proto.h', 'wifi-wext.h', 'card.h', 'buzzer.c', 'hard_icons.c', 'hard_icons.h']:
        copy_changed(source / name, board / name)
    if version in ('2.4', '2.6'):
        physical = os.environ.get('BE300_PHYSICAL_NAND', '0') == '1'
        target = board / ('nand_be300.c' if version == '2.4' else 'nand.c')
        saved = board / 'nand_emulator.c'
        if physical:
            if 'be300_physical_init' not in target.read_text():
                copy_changed(target, saved)
            copy_changed(source / 'nand_legacy_physical.c', target)
            if version == '2.6':
                # Upstream MTD fixed this after 2.6.8: offset zero is a
                # valid free area; length zero means there is no space.
                wbuf = tree / 'fs/jffs2/wbuf.c'
                text = wbuf.read_text()
                text = text.replace('if (!oinfo->oobfree[0][0])', 'if (!oinfo->oobfree[0][1])')
                wbuf.write_text(text)
            for name in ('nand_controller.h', 'nand_ecc.c', 'nand_ecc.h'):
                copy_changed(source / name, board / name)
        elif 'be300_physical_init' in target.read_text():
            if not saved.exists():
                raise RuntimeError('restage the legacy NAND driver before an emulator build')
            copy_changed(saved, target)
    if version == '4.2':
        # 2.6 and 2.4 bring their own 520-byte page readers in their patch
        # series; 4.2's driver is this file, kept current here.
        copy_changed(source / 'nand.c', board / 'nand.c')
        for name in ('nand_controller.h', 'nand_physical.h', 'nand_ecc.c', 'nand_ecc.h', 'nand_boot.c', 'nand_boot.h', 'pata_be300.c'):
            copy_changed(source / name, board / name)
    copy_changed(source / 'hardware.h', tree / 'include/linux/be300_hardware.h')
    copy_changed(source / 'card.h', tree / 'include/linux/be300_card.h')
    makefile = board / 'Makefile'
    text = makefile.read_text()
    if version in ('4.2', '2.6') and 'CFLAGS_nand.o' not in text:
        text += '\nCFLAGS_nand.o += -std=gnu99\n'
        makefile.write_text(text)
    if version == '2.4' and os.environ.get('BE300_PHYSICAL_NAND') == '1' and 'CFLAGS += -std=gnu99' not in text:
        text += '\nCFLAGS += -std=gnu99\n'
        makefile.write_text(text)
    if 'hardware.o' not in text:
        text, count = re.subn(r'(obj-y\s*[:+]?=\s*)', r'\1hardware.o ', text, count=1)
        if not count:
            raise RuntimeError('board obj-y not found')
        makefile.write_text(text)
    text = makefile.read_text()
    if 'audio.o' not in text:
        makefile.write_text(text + '\nobj-$(CONFIG_BE300_AUDIO) += audio.o\n')
    if version != '2.4':
        config = tree / 'arch/mips/Kconfig'
        text = config.read_text()
        if 'config BE300_AUDIO' not in text:
            text += ('\nconfig BE300_AUDIO\n\tbool "BE-300 Casio wave output"\n'
                     '\tdepends on CASIO_BE300\n\tdefault y\n\tselect SOUND\n')
            if version == '4.2':
                text += '\tselect SOUND_OSS_CORE\n'
            config.write_text(text)
    text = makefile.read_text()
    if 'buzzer.o' not in text:
        # Piezo as an EV_SND input device (bltinbuz.dll registers), and the
        # printed icons below the LCD as F1-F7.
        makefile.write_text(text + '\nobj-$(CONFIG_INPUT) += buzzer.o hard_icons.o\n')
    text = makefile.read_text()
    if version == '4.2' and 'pata_be300.o' not in text:
        # Byte-wide CF ATA (glaze-os cf.c); replaces pata_platform.
        makefile.write_text(text + '\nobj-$(CONFIG_ATA_SFF) += pata_be300.o\n')
    text = makefile.read_text()
    if 'wifi.o' not in text:
        makefile.write_text(text + '\nobj-$(CONFIG_BE300_WIFI) += wifi.o\n')
    if version != '2.4':
        config = tree / 'arch/mips/Kconfig'
        text = config.read_text()
        if 'config BE300_WIFI' not in text:
            text += ('\nconfig BE300_WIFI\n\tbool "BE-300 CF wireless stations"\n'
                     '\tdepends on CASIO_BE300 && NET && INET\n\tdefault y\n\tselect NETDEVICES\n')
            text += ('\tselect WIRELESS\n\tselect WIRELESS_EXT\n\tselect WEXT_CORE\n\tselect WEXT_PROC\n' if version == '4.2' else '\tselect NET_RADIO\n')
            config.write_text(text)
    if version == '2.4':
        text = makefile.read_text()
        ordered = rules_make_order(text)
        if ordered != text:
            makefile.write_text(ordered)
    ne = tree / ('drivers/net/ethernet/8390/ne.c' if version == '4.2' else 'drivers/net/ne.c')
    # Generic ISA probing must never issue DP8390 commands to a wireless card.
    if ne.exists() and 'be300_wired_card()' not in ne.read_text():
        text = ne.read_text()
        text = text.replace('#include <linux/module.h>', '#include <linux/module.h>\n#ifdef CONFIG_CASIO_BE300\n#include <linux/be300_card.h>\n#endif', 1)
        text = function_body(text, 'ne_probe1', lambda b: inject(b, '#ifdef CONFIG_CASIO_BE300\n\tif (!be300_wired_card())\n\t\treturn -ENODEV;\n#endif\n'))
        ne.write_text(text)
    if version == '2.4':
        config = tree / 'arch/mips/config.in'
        text = config.read_text()
        if 'CONFIG_BE300_AUDIO' not in text:
            config.write_text(text + '\nif [ "$CONFIG_CASIO_BE300" = "y" ]; then\n'
                '  if [ "$CONFIG_SOUND" = "y" ]; then\n'
                '    define_bool CONFIG_BE300_AUDIO y\n  fi\n'
                '  if [ "$CONFIG_NET" = "y" -a "$CONFIG_INET" = "y" ]; then\n'
                '    define_bool CONFIG_BE300_WIFI y\n    define_bool CONFIG_NET_RADIO y\n  fi\nfi\n')
        cf = board / 'cf_be300.c'
        text = cf.read_text()
        # Only storage (FUNCID 4) gets an IDE channel: polled ATA waits on
        # a network, serial or empty socket only time out.
        gate = '\tif (be300_card_function() != 4)\n\t\treturn 0;\n'
        if 'be300_card_function() != 4' not in text:
            old_gate = '\tif (be300_wireless_card())\n\t\treturn 0;\n'
            if old_gate in text:
                text = text.replace(old_gate, gate, 1)
            else:
                text = '#include <linux/be300_card.h>\n' + text
                text = function_body(text, 'be300_ide_default_io_base', lambda b: inject(b, gate))
            cf.write_text(text)
    setup = board / 'setup.c'
    text = setup.read_text()
    # 0A000014 is source 1's control word, not a W1C latch: all-ones would
    # enable the button source with junk mode bits (2.4 patch 0013 form).
    for old in ('*(volatile u32 *)KSEG1ADDR(BE300_GIRQ0_ACK_PA) = 0xffffffffu;',
                '*(volatile unsigned long *) KSEG1ADDR(0x0a000014) = 0xffffffffu;'):
        if old in text:
            if 'linux/be300_hardware.h' not in text:
                text = '#include <linux/be300_hardware.h>\n' + text
            text = text.replace(old, 'be300_girq0_source_mask(1);')
            setup.write_text(text)
    if version == '2.4':
        adapt(tree / 'drivers/char/serial_be300.c',
              lambda t: console(t, ['be300_console_init', 'be300_serial_init']))
        # Linux4BE's printk bypasses the serial driver before console_init.
        early = tree / 'kernel/printk.c'
        text = early.read_text()
        if 'be300_console_ready();' not in text:
            updated = console(text, ['Uart16550Init', 'Uart16550GetPoll',
                                     'Uart16550Put'])
            early.write_text(HEADER + updated)
    else:
        adapt(setup, lambda t: console(t, ['prom_putchar']))
    fb = board / 'sfb.c' if version == '4.2' else tree / 'drivers/video/sfb.c'
    adapt(fb, lambda s: framebuffer(s, version))
    if version == '2.4':
        text = fb.read_text()
        if 'be300_framebuffer_ready();' not in text:
            fb.write_text(function_body(text, 'sfb_init', lambda b:
                inject(b, '\tbe300_framebuffer_ready();\n')))
    touch_path = board / ('touch.c' if version == '2.6' else 'touch_be300.c')
    if version == '4.2':
        copy_changed(source / 'touch_be300.c', touch_path)
    adapt(touch_path, touch)
    touch_scan_upgrade(touch_path, version)
    if version != '4.2':
        copy_changed(source / 'touch_filter.h', touch_path.parent / 'touch_filter.h')
    touch_filter_upgrade(touch_path, version)
    touch_icons_upgrade(touch_path, version)
    adapt(board / ('irq_be300.c' if version == '2.4' else 'irq.c'),
          lambda s: irq(s, version))
    adapt(board / ('nand_be300.c' if version == '2.4' else 'nand.c'), nand)
    if version != '4.2' and not (version in ('2.4','2.6') and os.environ.get('BE300_PHYSICAL_NAND') == '1'):
        # Adapted trees are skipped above; this rewrite is idempotent.
        path = board / ('nand_be300.c' if version == '2.4' else 'nand.c')
        path.write_text(nand_drain(path.read_text()))
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
