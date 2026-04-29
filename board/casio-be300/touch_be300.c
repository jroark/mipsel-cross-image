/*
 * arch/mips/vr41xx/casio-be300/touch_be300.c
 *
 * VRC4173 PIU (Pen Interface Unit) touchscreen driver for the Casio BE-300.
 *
 * Register protocol verified against the BE-300 emulator at
 * ../be300-framebuffer/src/be300_devices.c (the DEVICE_ACCESS(be300_touch)
 * dispatcher around line 3537 and the supporting state machine
 * piu_update_state() / piu_latch_sample() / piu_store_page_sample()).
 * The emulator is the authoritative protocol reference because the VRC4173
 * UM leaves several edge cases under-specified (W1C-on-low-byte status,
 * coordinate page valid latching, scan-restart on data-lost ack).
 *
 *   PIU MMIO base: PA 0x0A000300, size 0x60
 *
 *   +0x00 PIUCNTREG  (16-bit, RW with masks)
 *      bits 9:0   writable control (mask 0x03FE on write; bit 0 self-clears
 *                 as the scan-start command kick)
 *      bits 12:10 PADSTATE (RO, scan sequencer state — see VRC4173 UM §9.2)
 *      bit  13    pendown status (RO, reflects host pen-down OR latched
 *                 PENSTC while PENCHGINTR is set)
 *
 *   +0x04 PIUINTREG  (16-bit)
 *      bits 7:0   pending status (set by HW, W1C by driver)
 *         bit 0  PENCHGINTR  — pen up/down change
 *         bit 2  PADDLOSTINTR — coordinate buffer overrun
 *         bit 3  PADPAGE0INTR — page 0 buffer ready
 *         bit 4  PADPAGE1INTR — page 1 buffer ready
 *      bits 15:8  interrupt mask (RW; 1 = unmasked)
 *
 *   +0x08..+0x18 PIU configuration registers (scan interval, stable count
 *      etc.). We program them with VRC4173 UM defaults — the emulator
 *      tolerates anything here, real hardware needs the documented values.
 *
 *   +0x20..+0x2C  page-0 ADC sample buffers (y+, y-, x-, x+, each u16)
 *   +0x50..+0x5C  page-1 ADC sample buffers (same layout)
 *
 * IRQ cascade:
 *   SYSINT1 bit 8 (GIU)                              [arch/mips/vr41xx/common/icu]
 *      -> GIU pin 0 (GIU_IRQ(0))                     [arch/mips/vr41xx/common/giu]
 *           -> VRC4173 GIRQ0 status @ PA 0x0A000004 bit 9   [board/casio-be300/irq.c]
 *                -> VRC4173_IRQ_BASE + 9 = VRC4173_IRQ(9)
 *
 * Coordinate decoding:
 *   The emulator maps host (x, y) into a fixed ADC range per channel:
 *     y+ in [0x81E1, 0x8E30]  linear with y in [0, 358]
 *     x+ in [0x8300, 0x8D1B]  linear with x in [0, 239]
 *   We invert that here using y+ and x+ alone (channels 0 and 3); the
 *   redundant y- / x- channels (1, 2) are ignored. On real hardware the
 *   four-channel form would be y = (y+ - y-)/2-ish, but VRC4173 already
 *   averages internally — taking one channel matches what the emulator
 *   produces and what the touchscreen panel layout encodes.
 *
 * Copyright (C) 2026 John Roark
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */
#include <linux/init.h>
#include <linux/io.h>
#include <linux/input.h>
#include <linux/interrupt.h>
#include <linux/slab.h>

#include <asm/vr41xx/irq.h>

#define BE300_PIU_BASE_PA	0x0a000300
#define BE300_PIU_SIZE		0x60

#define PIU_CNTREG		0x00
#define PIU_INTREG		0x04
#define PIU_SIVL		0x08	/* scan interval */
#define PIU_STBL		0x0c	/* stable count */
#define PIU_CMD			0x10	/* sample command */
#define PIU_ASCN		0x14
#define PIU_CIVL		0x18	/* conversion interval */
#define PIU_PB00		0x20	/* page 0 ADC: y+ */
#define PIU_PB01		0x24	/* page 0 ADC: y- */
#define PIU_PB02		0x28	/* page 0 ADC: x- */
#define PIU_PB03		0x2c	/* page 0 ADC: x+ */
#define PIU_PB10		0x50	/* page 1 ADC: y+ */
#define PIU_PB11		0x54
#define PIU_PB12		0x58
#define PIU_PB13		0x5c

/* PIUCNTREG control bits (VRC4173 UM §9.7). */
#define PIUCNT_PIUSEN		0x0001	/* scan-start kick (self-clearing) */
#define PIUCNT_PIUPWR		0x0002	/* power on */
#define PIUCNT_PADATSTART	0x0004	/* enable data scan */
#define PIUCNT_PADATSTOP	0x0008
#define PIUCNT_PADWAITPEN	0x0010	/* wait-for-pen-touch state enable */
#define PIUCNT_PEN_DETECTED	0x2000

/* PIUINTREG pending bits (low byte). */
#define PIUINT_PENCHGINTR	0x0001
#define PIUINT_PADDLOSTINTR	0x0004
#define PIUINT_PADPAGE0INTR	0x0008
#define PIUINT_PADPAGE1INTR	0x0010
#define PIUINT_TOUCH_DATA	(PIUINT_PADPAGE0INTR | PIUINT_PADPAGE1INTR)
#define PIUINT_PENDING_ALL	(PIUINT_PENCHGINTR | PIUINT_PADDLOSTINTR | \
				 PIUINT_TOUCH_DATA)

/* ADC linear ranges from be300-framebuffer/src/be300_devices.c:3192. */
#define PIU_ADC_Y_MIN		0x81E1u
#define PIU_ADC_Y_MAX		0x8E30u
#define PIU_ADC_X_MIN		0x8300u
#define PIU_ADC_X_MAX		0x8D1Bu

#define BE300_TOUCH_WIDTH	240
#define BE300_TOUCH_HEIGHT	320

struct be300_touch {
	void __iomem *base;
	struct input_dev *input;
	int irq;
	bool pen_down;
};

static struct be300_touch *be300_touch_dev;

static u16 piu_read(struct be300_touch *t, unsigned off)
{
	return readw(t->base + off);
}

static void piu_write(struct be300_touch *t, unsigned off, u16 val)
{
	writew(val, t->base + off);
}

static void piu_decode_page(struct be300_touch *t, unsigned page_off,
			    int *out_x, int *out_y)
{
	u16 yp = piu_read(t, page_off + 0x00);
	u16 xp = piu_read(t, page_off + 0x0c);
	int x, y;

	if (yp < PIU_ADC_Y_MIN)
		yp = PIU_ADC_Y_MIN;
	if (yp > PIU_ADC_Y_MAX)
		yp = PIU_ADC_Y_MAX;
	if (xp < PIU_ADC_X_MIN)
		xp = PIU_ADC_X_MIN;
	if (xp > PIU_ADC_X_MAX)
		xp = PIU_ADC_X_MAX;

	y = ((int)(yp - PIU_ADC_Y_MIN) * (BE300_TOUCH_HEIGHT - 1))
		/ (PIU_ADC_Y_MAX - PIU_ADC_Y_MIN);
	x = ((int)(xp - PIU_ADC_X_MIN) * (BE300_TOUCH_WIDTH - 1))
		/ (PIU_ADC_X_MAX - PIU_ADC_X_MIN);

	if (x < 0)
		x = 0;
	if (x >= BE300_TOUCH_WIDTH)
		x = BE300_TOUCH_WIDTH - 1;
	if (y < 0)
		y = 0;
	if (y >= BE300_TOUCH_HEIGHT)
		y = BE300_TOUCH_HEIGHT - 1;

	*out_x = x;
	*out_y = y;
}

static irqreturn_t be300_touch_isr(int irq, void *dev)
{
	struct be300_touch *t = dev;
	u16 status = piu_read(t, PIU_INTREG);
	u16 pending = status & 0xff;
	u16 mask = status >> 8;
	u16 effective = pending & mask;
	u16 ack = 0;
	int x, y;

	if (!effective)
		return IRQ_NONE;

	if (effective & PIUINT_PENCHGINTR) {
		bool down = !!(piu_read(t, PIU_CNTREG) & PIUCNT_PEN_DETECTED);
		t->pen_down = down;
		input_report_key(t->input, BTN_TOUCH, down ? 1 : 0);
		if (!down) {
			input_report_abs(t->input, ABS_PRESSURE, 0);
		}
		input_sync(t->input);
		ack |= PIUINT_PENCHGINTR;
	}

	if (effective & PIUINT_PADPAGE0INTR) {
		piu_decode_page(t, PIU_PB00, &x, &y);
		input_report_abs(t->input, ABS_X, x);
		input_report_abs(t->input, ABS_Y, y);
		input_report_abs(t->input, ABS_PRESSURE, t->pen_down ? 1 : 0);
		input_sync(t->input);
		ack |= PIUINT_PADPAGE0INTR;
	}

	if (effective & PIUINT_PADPAGE1INTR) {
		piu_decode_page(t, PIU_PB10, &x, &y);
		input_report_abs(t->input, ABS_X, x);
		input_report_abs(t->input, ABS_Y, y);
		input_report_abs(t->input, ABS_PRESSURE, t->pen_down ? 1 : 0);
		input_sync(t->input);
		ack |= PIUINT_PADPAGE1INTR;
	}

	if (effective & PIUINT_PADDLOSTINTR) {
		/* coordinate buffer overrun — ack and let the scan re-arm */
		ack |= PIUINT_PADDLOSTINTR;
	}

	/* W1C the bits we serviced; preserve the high-byte mask. */
	if (ack)
		piu_write(t, PIU_INTREG, (mask << 8) | ack);

	return IRQ_HANDLED;
}

static int __init be300_touch_init(void)
{
	struct be300_touch *t;
	int err;

	t = kzalloc(sizeof(*t), GFP_KERNEL);
	if (!t)
		return -ENOMEM;

	t->base = ioremap_nocache(BE300_PIU_BASE_PA, BE300_PIU_SIZE);
	if (!t->base) {
		err = -ENOMEM;
		goto fail_free;
	}

	t->input = input_allocate_device();
	if (!t->input) {
		err = -ENOMEM;
		goto fail_unmap;
	}

	t->input->name = "BE-300 PIU touchscreen";
	t->input->phys = "vrc4173-piu/input0";
	t->input->id.bustype = BUS_HOST;
	t->input->id.vendor = 0x1033;	/* NEC */
	t->input->id.product = 0x4173;
	t->input->id.version = 0x0001;

	__set_bit(EV_KEY, t->input->evbit);
	__set_bit(EV_ABS, t->input->evbit);
	__set_bit(BTN_TOUCH, t->input->keybit);
	input_set_abs_params(t->input, ABS_X, 0, BE300_TOUCH_WIDTH - 1, 0, 0);
	input_set_abs_params(t->input, ABS_Y, 0, BE300_TOUCH_HEIGHT - 1, 0, 0);
	input_set_abs_params(t->input, ABS_PRESSURE, 0, 1, 0, 0);

	err = input_register_device(t->input);
	if (err)
		goto fail_input_free;

	t->irq = VRC4173_IRQ_BASE + 9;
	err = request_irq(t->irq, be300_touch_isr, 0, "be300-touch", t);
	if (err)
		goto fail_unregister;

	/*
	 * Configure PIU defaults from VRC4173 UM §9 idle dump
	 * (docs/hardware/hw_dump_vrc4173.txt:983) and enable PENCHG +
	 * page 0/1 + datalost interrupts. PIUSEN (bit 0) is the scan-start
	 * kick — hardware self-clears it.
	 */
	piu_write(t, PIU_SIVL, 0x05DC);
	piu_write(t, PIU_STBL, 0x00C8);
	piu_write(t, PIU_INTREG, (PIUINT_PENDING_ALL << 8) | 0);
	piu_write(t, PIU_CNTREG,
		  PIUCNT_PIUSEN | PIUCNT_PIUPWR |
		  PIUCNT_PADATSTART | PIUCNT_PADWAITPEN);

	be300_touch_dev = t;
	pr_info("be300-touch: registered, irq=%d, base=%pa\n",
		t->irq, &t->base);
	return 0;

fail_unregister:
	input_unregister_device(t->input);
	t->input = NULL;
fail_input_free:
	if (t->input)
		input_free_device(t->input);
fail_unmap:
	iounmap(t->base);
fail_free:
	kfree(t);
	return err;
}
late_initcall(be300_touch_init);
