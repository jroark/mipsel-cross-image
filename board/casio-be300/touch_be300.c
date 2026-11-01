/* BE300 board hardware integration v1. */
#include <linux/be300_hardware.h>
/*
 * arch/mips/vr41xx/casio-be300/touch_be300.c
 *
 * VRC4173 PIU (Pen Interface Unit) touchscreen driver for the Casio BE-300.
 *
 * Startup is based on stock WinCE touch.dll 01A41274..01A41374 and
 * the VR4131/VRC4173 manuals; see docs/HARDWARE.md. The emulator is a
 * regression target, not a specification for electrical behavior.
 *
 *   PIU MMIO base: PA 0x0A000300, size 0x60
 *
 *   +0x00 PIUCNTREG  (16-bit, RW with masks)
 *      bits 9:0   writable control (mask 0x03FE on write; bit 0 self-clears
 *                 as the reset request)
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
 *      etc.). Initialization uses the recovered stock touch.dll values.
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
 *   Decode all four channels when present. The touch panel includes the
 *   320-line LCD plus a 40-ish line icon strip below it, so raw Y is first
 *   mapped to panel space and then clamped to the Linux framebuffer height.
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
#include <linux/timer.h>
#include <linux/spinlock.h>
#include <linux/jiffies.h>

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
#define PIUCNT_RESET		0x0001	/* reset request (self-clearing) */
#define PIUCNT_PADATSTART	0x0100
#define PIUCNT_PADATSTOP	0x0200
#define PIUCNT_PIUSEQEN		0x0004
#define PIUCNT_PIUPWR		0x0002
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
#define BE300_TOUCH_PANEL_HEIGHT	359

/*
 * A real BE-300 panel's samples jump by more than a tap's slop as the
 * contact settles and again at lift-off (the emulator's are exact), so an
 * unfiltered tap reads as a drag. As Glaze and tslib do: drop the first
 * sample after pen-down, hold the newest back so the lift-off sample is
 * never reported, average the last FILTER_N and ignore moves under MOVE_MIN.
 */
#define BE300_TOUCH_FILTER_N	3
#define BE300_TOUCH_MOVE_MIN	2

struct be300_touch {
	void __iomem *base;
	struct input_dev *input;
	int irq;
	bool pen_down;
	/* Stroke filter state (Glaze kernel/drivers/input.c). */
	int stroke_samples, first_x, first_y;
	int win_x[BE300_TOUCH_FILTER_N], win_y[BE300_TOUCH_FILTER_N], win_n;
	bool held;
	int held_x, held_y, pen_x, pen_y;
	spinlock_t lock;
	struct timer_list poll;
};

static struct be300_touch *be300_touch_dev;

static u16 piu_read(struct be300_touch *t, unsigned off)
{
	return readw(t->base + off);
}

static bool piu_adc_valid(u16 value, u16 min, u16 max)
{
	return value >= min && value <= max;
}

static int piu_adc_to_pos(u16 value, u16 min, u16 max, int span)
{
	if (value < min)
		value = min;
	if (value > max)
		value = max;

	return ((int)(value - min) * (span - 1)) / (max - min);
}

static int piu_adc_to_pos_inv(u16 value, u16 min, u16 max, int span)
{
	if (value < min)
		value = min;
	if (value > max)
		value = max;

	return ((int)(max - value) * (span - 1)) / (max - min);
}

static bool piu_decode_page(struct be300_touch *t, unsigned page_off,
			    int *out_x, int *out_y)
{
	u16 yp = piu_read(t, page_off + 0x00);
	u16 ym = piu_read(t, page_off + 0x04);
	u16 xm = piu_read(t, page_off + 0x08);
	u16 xp = piu_read(t, page_off + 0x0c);
	int x = 0, y = 0, n = 0;

	if (!(yp & ym & xm & xp & 0x8000))
		return false;

	if (piu_adc_valid(xp, PIU_ADC_X_MIN, PIU_ADC_X_MAX)) {
		x += piu_adc_to_pos(xp, PIU_ADC_X_MIN, PIU_ADC_X_MAX,
				    BE300_TOUCH_WIDTH);
		n++;
	}
	if (piu_adc_valid(xm, PIU_ADC_X_MIN, PIU_ADC_X_MAX)) {
		x += piu_adc_to_pos_inv(xm, PIU_ADC_X_MIN, PIU_ADC_X_MAX,
					BE300_TOUCH_WIDTH);
		n++;
	}
	x = n ? x / n : piu_adc_to_pos(xp, PIU_ADC_X_MIN, PIU_ADC_X_MAX,
				       BE300_TOUCH_WIDTH);

	n = 0;
	if (piu_adc_valid(yp, PIU_ADC_Y_MIN, PIU_ADC_Y_MAX)) {
		y += piu_adc_to_pos(yp, PIU_ADC_Y_MIN, PIU_ADC_Y_MAX,
				    BE300_TOUCH_PANEL_HEIGHT);
		n++;
	}
	if (piu_adc_valid(ym, PIU_ADC_Y_MIN, PIU_ADC_Y_MAX)) {
		y += piu_adc_to_pos_inv(ym, PIU_ADC_Y_MIN, PIU_ADC_Y_MAX,
					BE300_TOUCH_PANEL_HEIGHT);
		n++;
	}
	y = n ? y / n : piu_adc_to_pos(yp, PIU_ADC_Y_MIN, PIU_ADC_Y_MAX,
				       BE300_TOUCH_PANEL_HEIGHT);
	if (y >= BE300_TOUCH_HEIGHT)
		y = BE300_TOUCH_HEIGHT - 1;

	*out_x = x;
	*out_y = y;
	return true;
}

static void be300_touch_stroke_reset(struct be300_touch *t)
{
	t->stroke_samples = 0;
	t->win_n = 0;
	t->held = false;
}

static void be300_touch_report(struct be300_touch *t, int x, int y)
{
	if (t->pen_down) {
		int dx = x - t->pen_x, dy = y - t->pen_y;

		if (dx < BE300_TOUCH_MOVE_MIN && dx > -BE300_TOUCH_MOVE_MIN &&
		    dy < BE300_TOUCH_MOVE_MIN && dy > -BE300_TOUCH_MOVE_MIN)
			return;
	}
	input_report_abs(t->input, ABS_X, x);
	input_report_abs(t->input, ABS_Y, y);
	if (!t->pen_down) {
		input_report_abs(t->input, ABS_PRESSURE, 1);
		input_report_key(t->input, BTN_TOUCH, 1);
	}
	input_sync(t->input);
	t->pen_down = true;
	t->pen_x = x;
	t->pen_y = y;
}

static void be300_touch_sample(struct be300_touch *t, int x, int y)
{
	int i, k, n, sx = 0, sy = 0;

	if (t->stroke_samples++ == 0) {
		t->first_x = x;
		t->first_y = y;
		return;
	}
	i = t->win_n++ % BE300_TOUCH_FILTER_N;
	n = t->win_n < BE300_TOUCH_FILTER_N ? t->win_n : BE300_TOUCH_FILTER_N;
	t->win_x[i] = x;
	t->win_y[i] = y;
	for (k = 0; k < n; k++) {
		sx += t->win_x[k];
		sy += t->win_y[k];
	}
	if (t->held)
		be300_touch_report(t, t->held_x, t->held_y);
	t->held = true;
	t->held_x = sx / n;
	t->held_y = sy / n;
}

/* Pen-up drops the held lift-off sample, unless the tap was too short to
 * report anything; then it lands where it began. */
static void be300_touch_release(struct be300_touch *t)
{
	if (!t->pen_down && t->stroke_samples) {
		if (t->held)
			be300_touch_report(t, t->held_x, t->held_y);
		else
			be300_touch_report(t, t->first_x, t->first_y);
	}
	if (t->pen_down) {
		t->pen_down = false;
		input_report_key(t->input, BTN_TOUCH, 0);
		input_report_abs(t->input, ABS_PRESSURE, 0);
		input_sync(t->input);
	}
	be300_touch_stroke_reset(t);
}

static void be300_touch_report_page(struct be300_touch *t, unsigned page_off)
{
	int x, y;

	if (piu_decode_page(t, page_off, &x, &y))
		be300_touch_sample(t, x, y);
}

static irqreturn_t be300_touch_isr(int irq, void *dev)
{
	struct be300_touch *t = dev;
	unsigned long flags;
	u16 status, effective;

	spin_lock_irqsave(&t->lock, flags);
	status = piu_read(t, PIU_INTREG);
	effective = (status & 0xff) & (status >> 8);
	if (!effective) {
		spin_unlock_irqrestore(&t->lock, flags);
		return IRQ_NONE;
	}

	/* A new stroke starts clean; a coalesced short tap publishes its
	 * coordinates before its release. */
	if ((effective & PIUINT_PENCHGINTR) && !t->pen_down &&
	    (piu_read(t, PIU_CNTREG) & PIUCNT_PEN_DETECTED))
		be300_touch_stroke_reset(t);
	if (effective & PIUINT_PADPAGE0INTR)
		be300_touch_report_page(t, PIU_PB00);
	if (effective & PIUINT_PADPAGE1INTR)
		be300_touch_report_page(t, PIU_PB10);
	if ((effective & PIUINT_PENCHGINTR) &&
	    !(piu_read(t, PIU_CNTREG) & PIUCNT_PEN_DETECTED))
		be300_touch_release(t);
	be300_piu_ack(status);
	spin_unlock_irqrestore(&t->lock, flags);
	return IRQ_HANDLED;
}

/* Glaze and the legacy Linux drivers also service the PIU by polling.
 * Keep input usable when the companion IRQ cascade misses a transition. */
static void be300_touch_poll(unsigned long data)
{
	struct be300_touch *t = (struct be300_touch *)data;

	be300_touch_isr(t->irq, t);
	mod_timer(&t->poll, jiffies + msecs_to_jiffies(20));
}

static int __init be300_touch_init(void)
{
	struct be300_touch *t;
	int err;

	if (be300_piu_prepare())
		return -ETIMEDOUT;
	t = kzalloc(sizeof(*t), GFP_KERNEL);
	if (!t)
		return -ENOMEM;

	spin_lock_init(&t->lock);
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
	if (err) {
		pr_warn("BE-300 touch: IRQ unavailable, using PIU polling\n");
		t->irq = -1;
	}
	setup_timer(&t->poll, be300_touch_poll, (unsigned long)t);
	be300_piu_start();
	mod_timer(&t->poll, jiffies + msecs_to_jiffies(20));

	be300_touch_dev = t;
	return 0;

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
