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
 * Key scheme (matches the linux4.be scan_be300.c typing scheme):
 *
 *   plain                rocket + key
 *   -----                ------------
 *   OK    = Enter        Rocket+OK    = Space
 *   ESC   = Tab          Rocket+ESC   = Backspace
 *   UP    = Up           Rocket+UP    = next char in alphabet cycle
 *   DOWN  = Down         Rocket+DOWN  = previous char in alphabet cycle
 *   RIGHT = Right        Rocket+RIGHT = commit char and advance
 *   LEFT  = Left         Rocket+LEFT  = backspace (overwrite previous char)
 *   PWR   = Power        Rocket+PWR   = Ctrl+C
 *
 * The rocket+up/down "cycle" scheme works by emitting
 *   <BACKSPACE> <new char> <LEFT>
 * so the character under the cursor is replaced each tick and the cursor
 * stays on top of the new char. Rocket+right moves the cursor past it to
 * commit.
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

#define BE300_KEYS_POLL_MS	50
#define BE300_REG_SET1		0xAA00A042
#define BE300_REG_SET2		0xAA00A043

/* Set 1 bit masks */
#define BE300_BTN_OK		0x04
#define BE300_BTN_ESC		0x08
#define BE300_BTN_UP		0x10
#define BE300_BTN_DOWN		0x20
#define BE300_BTN_RIGHT		0x40
#define BE300_BTN_LEFT		0x80

/* Set 2 bit masks */
#define BE300_BTN_ROCKET	0x10
#define BE300_BTN_POWER		0x80

/*
 * Character cycle for rocket+up/down. Matches the original 48-entry
 * scheme: a-z, space, 0-9, and punctuation. Each entry is a KEY_* code.
 * A held rocket+up cycles through these; rocket+down goes backward.
 */
static const unsigned short char_keys[] = {
	KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, KEY_H, KEY_I, KEY_J,
	KEY_K, KEY_L, KEY_M, KEY_N, KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T,
	KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z,
	KEY_SPACE,
	KEY_0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9,
	KEY_GRAVE, KEY_MINUS, KEY_EQUAL, KEY_LEFTBRACE, KEY_RIGHTBRACE,
	KEY_SEMICOLON, KEY_APOSTROPHE, KEY_BACKSLASH,
	KEY_COMMA, KEY_DOT, KEY_SLASH,
};
#define NUM_CHAR_KEYS ARRAY_SIZE(char_keys)

struct be300_key_state {
	u8 prev_set1;
	u8 prev_set2;
	int char_pos;
	bool pending_edit;
};

static struct be300_key_state be300_state;

static void be300_tap(struct input_dev *input, unsigned short key)
{
	input_report_key(input, key, 1);
	input_sync(input);
	input_report_key(input, key, 0);
	input_sync(input);
}

/*
 * Emit Ctrl+C as a held-down modifier sequence:
 *   press Ctrl, press C, release C, release Ctrl
 */
static void be300_ctrl_c(struct input_dev *input)
{
	input_report_key(input, KEY_LEFTCTRL, 1);
	input_sync(input);
	input_report_key(input, KEY_C, 1);
	input_sync(input);
	input_report_key(input, KEY_C, 0);
	input_sync(input);
	input_report_key(input, KEY_LEFTCTRL, 0);
	input_sync(input);
}

static void be300_keys_poll(struct input_polled_dev *dev)
{
	struct input_dev *input = dev->input;
	u8 set1 = readb((void __iomem *)BE300_REG_SET1);
	u8 set2 = readb((void __iomem *)BE300_REG_SET2);
	u8 changed1 = set1 ^ be300_state.prev_set1;
	u8 changed2 = set2 ^ be300_state.prev_set2;
	int rocket = !!(set2 & BE300_BTN_ROCKET);

	/*
	 * Detect rising edges on the main buttons. Rocket itself is treated
	 * as a modifier and never produces an event of its own.
	 */
	if ((changed1 & BE300_BTN_OK) && (set1 & BE300_BTN_OK)) {
		be300_state.pending_edit = false;
		if (rocket)
			be300_tap(input, KEY_SPACE);
		else
			be300_tap(input, KEY_ENTER);
	}

	if ((changed1 & BE300_BTN_ESC) && (set1 & BE300_BTN_ESC)) {
		be300_state.pending_edit = false;
		if (rocket)
			be300_tap(input, KEY_BACKSPACE);
		else
			be300_tap(input, KEY_TAB);
	}

	if ((changed1 & BE300_BTN_UP) && (set1 & BE300_BTN_UP)) {
		if (rocket) {
			if (be300_state.pending_edit) {
				be300_state.char_pos =
				    (be300_state.char_pos + 1) % NUM_CHAR_KEYS;
				be300_tap(input, KEY_BACKSPACE);
			} else {
				be300_state.char_pos = 0;
				be300_state.pending_edit = true;
			}
			be300_tap(input, char_keys[be300_state.char_pos]);
		} else {
			be300_tap(input, KEY_UP);
		}
	}

	if ((changed1 & BE300_BTN_DOWN) && (set1 & BE300_BTN_DOWN)) {
		if (rocket) {
			if (be300_state.pending_edit) {
				be300_state.char_pos =
				    (be300_state.char_pos + NUM_CHAR_KEYS - 1) %
				    NUM_CHAR_KEYS;
				be300_tap(input, KEY_BACKSPACE);
			} else {
				be300_state.char_pos = NUM_CHAR_KEYS - 1;
				be300_state.pending_edit = true;
			}
			be300_tap(input, char_keys[be300_state.char_pos]);
		} else {
			be300_tap(input, KEY_DOWN);
		}
	}

	if ((changed1 & BE300_BTN_RIGHT) && (set1 & BE300_BTN_RIGHT)) {
		be300_state.pending_edit = false;
		be300_tap(input, KEY_RIGHT);
	}

	if ((changed1 & BE300_BTN_LEFT) && (set1 & BE300_BTN_LEFT)) {
		if (rocket) {
			be300_state.pending_edit = false;
			be300_tap(input, KEY_BACKSPACE);
		} else {
			be300_tap(input, KEY_LEFT);
		}
	}

	if ((changed2 & BE300_BTN_POWER) && (set2 & BE300_BTN_POWER)) {
		be300_state.pending_edit = false;
		if (rocket)
			be300_ctrl_c(input);
		else
			be300_tap(input, KEY_POWER);
	}

	/* Rocket released: commit any pending edit. */
	if ((changed2 & BE300_BTN_ROCKET) && !(set2 & BE300_BTN_ROCKET))
		be300_state.pending_edit = false;

	be300_state.prev_set1 = set1;
	be300_state.prev_set2 = set2;
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
	__set_bit(KEY_ENTER, input->keybit);
	__set_bit(KEY_TAB, input->keybit);
	__set_bit(KEY_UP, input->keybit);
	__set_bit(KEY_DOWN, input->keybit);
	__set_bit(KEY_LEFT, input->keybit);
	__set_bit(KEY_RIGHT, input->keybit);
	__set_bit(KEY_POWER, input->keybit);
	__set_bit(KEY_SPACE, input->keybit);
	__set_bit(KEY_BACKSPACE, input->keybit);
	__set_bit(KEY_LEFTCTRL, input->keybit);
	for (i = 0; i < NUM_CHAR_KEYS; i++)
		__set_bit(char_keys[i], input->keybit);

	err = input_register_polled_device(poll_dev);
	if (err) {
		input_free_polled_device(poll_dev);
		return err;
	}

	pr_info("BE-300 Buttons: polling at %dms (rocket-modifier text input)\n",
		BE300_KEYS_POLL_MS);
	return 0;
}

late_initcall(be300_keys_init);
