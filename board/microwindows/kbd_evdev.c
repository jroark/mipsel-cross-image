/*
 * Linux evdev keyboard driver for Microwindows / Nano-X.
 *
 * Opens /dev/input/event0 (the BE-300 buttons / Stowaway keyboard registered
 * by board/casio-be300/keys.c and stowaway_serio.c) and translates evdev
 * KEY_* codes to MWKEY_* codes.
 *
 * Copyright (C) 2026 John Roark
 */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <linux/input.h>
#include "device.h"

#ifndef EVDEV_KEYBOARD_DEV
#define EVDEV_KEYBOARD_DEV	"/dev/input/event0"
#endif

static int  EVDEV_Open(KBDDEVICE *pkd);
static void EVDEV_Close(void);
static void EVDEV_GetModifierInfo(MWKEYMOD *modifiers, MWKEYMOD *curmodifiers);
static int  EVDEV_Read(MWKEY *kbuf, MWKEYMOD *modifiers, MWSCANCODE *scancode);

KBDDEVICE kbddev = {
	EVDEV_Open,
	EVDEV_Close,
	EVDEV_GetModifierInfo,
	EVDEV_Read,
	NULL,
};

static int		fd = -1;
static MWKEYMOD		mod_state;

static MWKEY
evdev_to_mwkey(unsigned code)
{
	switch (code) {
	case KEY_ENTER:		return MWKEY_ENTER;
	case KEY_ESC:		return MWKEY_ESCAPE;
	case KEY_BACKSPACE:	return MWKEY_BACKSPACE;
	case KEY_TAB:		return MWKEY_TAB;
	case KEY_SPACE:		return ' ';
	case KEY_UP:		return MWKEY_UP;
	case KEY_DOWN:		return MWKEY_DOWN;
	case KEY_LEFT:		return MWKEY_LEFT;
	case KEY_RIGHT:		return MWKEY_RIGHT;
	case KEY_HOME:		return MWKEY_HOME;
	case KEY_END:		return MWKEY_END;
	case KEY_PAGEUP:	return MWKEY_PAGEUP;
	case KEY_PAGEDOWN:	return MWKEY_PAGEDOWN;
	case KEY_INSERT:	return MWKEY_INSERT;
	case KEY_DELETE:	return MWKEY_DELETE;
	case KEY_F1:		return MWKEY_F1;
	case KEY_F2:		return MWKEY_F2;
	case KEY_F3:		return MWKEY_F3;
	case KEY_F4:		return MWKEY_F4;
	case KEY_F5:		return MWKEY_F5;
	case KEY_F6:		return MWKEY_F6;
	case KEY_F7:		return MWKEY_F7;
	case KEY_F8:		return MWKEY_F8;
	case KEY_F9:		return MWKEY_F9;
	case KEY_F10:		return MWKEY_F10;
	case KEY_F11:		return MWKEY_F11;
	case KEY_F12:		return MWKEY_F12;
	case KEY_LEFTSHIFT:	return MWKEY_LSHIFT;
	case KEY_RIGHTSHIFT:	return MWKEY_RSHIFT;
	case KEY_LEFTCTRL:	return MWKEY_LCTRL;
	case KEY_RIGHTCTRL:	return MWKEY_RCTRL;
	case KEY_LEFTALT:	return MWKEY_LALT;
	case KEY_RIGHTALT:	return MWKEY_RALT;
	case KEY_CAPSLOCK:	return MWKEY_CAPSLOCK;
	case KEY_POWER:		return MWKEY_QUIT;	/* BE-300 power button */
	case KEY_A: return 'a'; case KEY_B: return 'b'; case KEY_C: return 'c';
	case KEY_D: return 'd'; case KEY_E: return 'e'; case KEY_F: return 'f';
	case KEY_G: return 'g'; case KEY_H: return 'h'; case KEY_I: return 'i';
	case KEY_J: return 'j'; case KEY_K: return 'k'; case KEY_L: return 'l';
	case KEY_M: return 'm'; case KEY_N: return 'n'; case KEY_O: return 'o';
	case KEY_P: return 'p'; case KEY_Q: return 'q'; case KEY_R: return 'r';
	case KEY_S: return 's'; case KEY_T: return 't'; case KEY_U: return 'u';
	case KEY_V: return 'v'; case KEY_W: return 'w'; case KEY_X: return 'x';
	case KEY_Y: return 'y'; case KEY_Z: return 'z';
	case KEY_0: return '0'; case KEY_1: return '1'; case KEY_2: return '2';
	case KEY_3: return '3'; case KEY_4: return '4'; case KEY_5: return '5';
	case KEY_6: return '6'; case KEY_7: return '7'; case KEY_8: return '8';
	case KEY_9: return '9';
	case KEY_MINUS:		return '-';
	case KEY_EQUAL:		return '=';
	case KEY_LEFTBRACE:	return '[';
	case KEY_RIGHTBRACE:	return ']';
	case KEY_SEMICOLON:	return ';';
	case KEY_APOSTROPHE:	return '\'';
	case KEY_GRAVE:		return '`';
	case KEY_BACKSLASH:	return '\\';
	case KEY_COMMA:		return ',';
	case KEY_DOT:		return '.';
	case KEY_SLASH:		return '/';
	default:		return 0;
	}
}

static int
EVDEV_Open(KBDDEVICE *pkd)
{
	const char *dev = getenv("MWKBD") ? getenv("MWKBD") : EVDEV_KEYBOARD_DEV;

	fd = open(dev, O_RDONLY | O_NONBLOCK);
	if (fd < 0)
		return DRIVER_FAIL;
	mod_state = 0;
	return DRIVER_OKFILEDESC(fd);
}

static void
EVDEV_Close(void)
{
	if (fd >= 0) {
		close(fd);
		fd = -1;
	}
}

static void
EVDEV_GetModifierInfo(MWKEYMOD *modifiers, MWKEYMOD *curmodifiers)
{
	if (modifiers)
		*modifiers = MWKMOD_LSHIFT | MWKMOD_RSHIFT |
			     MWKMOD_LCTRL  | MWKMOD_RCTRL  |
			     MWKMOD_LALT   | MWKMOD_RALT;
	if (curmodifiers)
		*curmodifiers = mod_state;
}

static MWKEYMOD
mod_bit_for(MWKEY mw)
{
	switch (mw) {
	case MWKEY_LSHIFT:	return MWKMOD_LSHIFT;
	case MWKEY_RSHIFT:	return MWKMOD_RSHIFT;
	case MWKEY_LCTRL:	return MWKMOD_LCTRL;
	case MWKEY_RCTRL:	return MWKMOD_RCTRL;
	case MWKEY_LALT:	return MWKMOD_LALT;
	case MWKEY_RALT:	return MWKMOD_RALT;
	default:		return 0;
	}
}

static int
EVDEV_Read(MWKEY *kbuf, MWKEYMOD *modifiers, MWSCANCODE *scancode)
{
	struct input_event ev;
	ssize_t n;

	for (;;) {
		n = read(fd, &ev, sizeof(ev));
		if (n < 0) {
			if (errno == EAGAIN || errno == EINTR)
				return KBD_NODATA;
			return KBD_FAIL;
		}
		if (n != sizeof(ev))
			return KBD_NODATA;

		if (ev.type != EV_KEY)
			continue;

		/* ev.value: 0=release, 1=press, 2=autorepeat */
		MWKEY mw = evdev_to_mwkey(ev.code);
		if (mw == 0)
			continue;

		MWKEYMOD bit = mod_bit_for(mw);
		if (bit) {
			if (ev.value)
				mod_state |= bit;
			else
				mod_state &= ~bit;
		}

		*kbuf = mw;
		*modifiers = mod_state;
		*scancode = ev.code;
		if (ev.value)
			return KBD_KEYPRESS;
		else
			return KBD_KEYRELEASE;
	}
}
