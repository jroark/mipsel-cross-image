/*
 * arch/mips/vr41xx/casio-be300/keys.c
 *
 * Polled button input driver for the Casio Cassiopeia BE-300.
 *
 * The BE-300 has 8 physical buttons read via two byte registers on the
 * companion chip:
 *   0xAA00A042 (set1): OK, ESC, UP, DOWN, RIGHT, LEFT
 *   0xAA00A043 (set2): Rocket (modifier), Power
 *
 * A bit value of 1 means the button is currently pressed.
 *
 * Based on scan_be300.c from the linux4.be project (2002):
 *   Marc <themaw@linux4.be>, John Roark <jroark@linux4.be>
 *
 * Ported to Linux 4.2.9 input_polled_dev API.
 * Copyright (C) 2026 John Roark
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */
#include <linux/init.h>
#include <linux/input.h>
#include <linux/input-polldev.h>
#include <asm/io.h>

#define BE300_KEYS_POLL_MS	200
#define BE300_REG_SET1		0xAA00A042
#define BE300_REG_SET2		0xAA00A043
#define BE300_NUM_BUTTONS	8

struct be300_button {
	unsigned long reg;
	unsigned char mask;
	unsigned short keycode;
};

static const struct be300_button be300_buttons[BE300_NUM_BUTTONS] = {
	{ BE300_REG_SET1, 0x04, KEY_ENTER },
	{ BE300_REG_SET1, 0x08, KEY_TAB },
	{ BE300_REG_SET1, 0x10, KEY_UP },
	{ BE300_REG_SET1, 0x20, KEY_DOWN },
	{ BE300_REG_SET1, 0x40, KEY_RIGHT },
	{ BE300_REG_SET1, 0x80, KEY_LEFT },
	{ BE300_REG_SET2, 0x10, KEY_LEFTSHIFT },
	{ BE300_REG_SET2, 0x80, KEY_POWER },
};

static u8 prev_state[BE300_NUM_BUTTONS];

static void be300_keys_poll(struct input_polled_dev *dev)
{
	struct input_dev *input = dev->input;
	u8 set1, set2, pressed;
	int i, changed = 0;

	set1 = readb((void __iomem *)BE300_REG_SET1);
	set2 = readb((void __iomem *)BE300_REG_SET2);

	for (i = 0; i < BE300_NUM_BUTTONS; i++) {
		if (be300_buttons[i].reg == BE300_REG_SET1)
			pressed = !!(set1 & be300_buttons[i].mask);
		else
			pressed = !!(set2 & be300_buttons[i].mask);

		if (pressed != prev_state[i]) {
			input_report_key(input, be300_buttons[i].keycode,
					 pressed);
			prev_state[i] = pressed;
			changed = 1;
		}
	}

	if (changed)
		input_sync(input);
}

static int __init be300_keys_init(void)
{
	struct input_polled_dev *poll_dev;
	struct input_dev *input;
	int i, err;

	poll_dev = input_allocate_polled_device();
	if (!poll_dev)
		return -ENOMEM;

	poll_dev->poll = be300_keys_poll;
	poll_dev->poll_interval = BE300_KEYS_POLL_MS;

	input = poll_dev->input;
	input->name = "BE-300 Buttons";
	input->phys = "be300/input0";
	input->id.bustype = BUS_HOST;

	__set_bit(EV_KEY, input->evbit);
	for (i = 0; i < BE300_NUM_BUTTONS; i++)
		__set_bit(be300_buttons[i].keycode, input->keybit);

	err = input_register_polled_device(poll_dev);
	if (err) {
		input_free_polled_device(poll_dev);
		return err;
	}

	pr_info("BE-300 Buttons: 8 buttons, polling at %dms\n",
		BE300_KEYS_POLL_MS);
	return 0;
}

late_initcall(be300_keys_init);
