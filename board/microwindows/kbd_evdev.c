/*
 * Linux evdev keyboard driver for Microwindows / Nano-X.
 *
 * Opens the BE-300 buttons or optional Stowaway keyboard evdev node and
 * translates evdev KEY_* codes to MWKEY_* codes.
 *
 * Copyright (C) 2026 John Roark
 */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include "device.h"

#ifndef EVDEV_KEYBOARD_DEV
#define EVDEV_KEYBOARD_DEV	NULL
#endif

#define	EVDEV_EVENT_FMT		"/dev/input/event%d"
#define	EVDEV_MAX_EVENTS	8
#define	EVDEV_TRACE_LIMIT	96
#define	EVDEV_NAME_STOWAWAY	"Stowaway Keyboard"
#define	EVDEV_NAME_BUTTONS	"BE-300 Buttons"

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

struct evdev_kbd {
	int		fd;
	char		path[32];
	char		name[80];
};

static struct evdev_kbd	kbd[EVDEV_MAX_EVENTS];
static int		nkbd;
static int		wake_fd = -1;
static int		next_kbd;
static MWKEYMOD		mod_state;
static int		caps_lock;
static int		log_fd = -1;
static int		event_traces;

/*
 * Linux 4.2 on 32-bit MIPS returns the original 16-byte evdev record.
 * Modern musl headers use a 64-bit time_t, making struct input_event larger;
 * reading sizeof(struct input_event) would see every kernel packet as short
 * and drop it.
 */
struct evdev_wire_event {
	int32_t		tv_sec;
	int32_t		tv_usec;
	uint16_t	type;
	uint16_t	code;
	int32_t		value;
};

static void
evdev_log(const char *fmt, ...)
{
	char msg[192];
	char body[160];
	va_list ap;
	int n;

	va_start(ap, fmt);
	vsnprintf(body, sizeof(body), fmt, ap);
	va_end(ap);

	n = snprintf(msg, sizeof(msg), "kbd_evdev: %s\n", body);
	if (n <= 0)
		return;
	if (n > (int)sizeof(msg))
		n = sizeof(msg);

	if (log_fd < 0)
		log_fd = open("/dev/kmsg", O_WRONLY | O_NONBLOCK);
	if (log_fd >= 0)
		write(log_fd, msg, (size_t)n);
	fprintf(stderr, "%s", msg);
}

static int
add_keyboard_fd(int tfd, const char *path, const char *name)
{
	if (nkbd >= EVDEV_MAX_EVENTS) {
		close(tfd);
		return -1;
	}

	kbd[nkbd].fd = tfd;
	snprintf(kbd[nkbd].path, sizeof(kbd[nkbd].path), "%s", path);
	snprintf(kbd[nkbd].name, sizeof(kbd[nkbd].name), "%s", name);
	evdev_log("opened %s name=\"%s\"", kbd[nkbd].path, kbd[nkbd].name);
	nkbd++;
	return 0;
}

static int
open_evdev_keyboards(const char *override)
{
	static const char * const preferred_names[] = {
		EVDEV_NAME_STOWAWAY,
		EVDEV_NAME_BUTTONS,
		NULL,
	};
	char path[sizeof(EVDEV_EVENT_FMT) + 3];
	char name[80];
	int want, i, tfd;

	nkbd = 0;
	next_kbd = 0;

	if (override && override[0]) {
		tfd = open(override, O_RDONLY | O_NONBLOCK);
		if (tfd >= 0)
			add_keyboard_fd(tfd, override, "override");
		return tfd;
	}

	for (want = 0; preferred_names[want]; want++) {
		for (i = 0; i < EVDEV_MAX_EVENTS; i++) {
			snprintf(path, sizeof(path), EVDEV_EVENT_FMT, i);
			tfd = open(path, O_RDONLY | O_NONBLOCK);
			if (tfd < 0)
				continue;

			memset(name, 0, sizeof(name));
			if (ioctl(tfd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
			    strcmp(name, preferred_names[want]) == 0) {
				add_keyboard_fd(tfd, path, name);
				continue;
			}

			close(tfd);
		}
	}

	if (nkbd == 0)
		return -1;

	/*
	 * Return the buttons fd to Nano-X when present, since the Stowaway input
	 * device is registered even when the emulator dock is not connected. The
	 * BE-300 Nano-X loop also polls periodically, so all open fds are drained
	 * even if select() wakes on only this descriptor.
	 */
	for (i = nkbd - 1; i >= 0; i--) {
		if (strcmp(kbd[i].name, EVDEV_NAME_BUTTONS) == 0)
			return kbd[i].fd;
	}

	return kbd[0].fd;
}

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

static MWKEY
apply_printable_modifiers(unsigned code, MWKEY mw)
{
	int shift = (mod_state & (MWKMOD_LSHIFT | MWKMOD_RSHIFT)) != 0;
	int ctrl = (mod_state & (MWKMOD_LCTRL | MWKMOD_RCTRL)) != 0;

	if (mw >= 'a' && mw <= 'z') {
		if (ctrl)
			return (MWKEY)(mw - 'a' + 1);
		if (shift ^ caps_lock)
			return (MWKEY)(mw - 'a' + 'A');
		return mw;
	}

	if (!shift)
		return mw;

	switch (code) {
	case KEY_1: return '!';
	case KEY_2: return '@';
	case KEY_3: return '#';
	case KEY_4: return '$';
	case KEY_5: return '%';
	case KEY_6: return '^';
	case KEY_7: return '&';
	case KEY_8: return '*';
	case KEY_9: return '(';
	case KEY_0: return ')';
	case KEY_MINUS: return '_';
	case KEY_EQUAL: return '+';
	case KEY_LEFTBRACE: return '{';
	case KEY_RIGHTBRACE: return '}';
	case KEY_SEMICOLON: return ':';
	case KEY_APOSTROPHE: return '"';
	case KEY_GRAVE: return '~';
	case KEY_BACKSLASH: return '|';
	case KEY_COMMA: return '<';
	case KEY_DOT: return '>';
	case KEY_SLASH: return '?';
	default: return mw;
	}
}

static int
EVDEV_Open(KBDDEVICE *pkd)
{
	const char *dev = getenv("MWKBD") ? getenv("MWKBD") : EVDEV_KEYBOARD_DEV;
	int i;

	wake_fd = open_evdev_keyboards(dev);
	if (wake_fd < 0) {
		evdev_log("open failed for BE-300 keyboard devices");
		return DRIVER_FAIL;
	}
	for (i = 0; i < nkbd; i++)
		evdev_log("EVIOCGRAB %s rc=%d", kbd[i].path,
			  ioctl(kbd[i].fd, EVIOCGRAB, 1));
	mod_state = 0;
	caps_lock = 0;
	return DRIVER_OKFILEDESC(wake_fd);
}

static void
EVDEV_Close(void)
{
	int i;

	for (i = 0; i < nkbd; i++) {
		if (kbd[i].fd >= 0) {
			ioctl(kbd[i].fd, EVIOCGRAB, 0);
			close(kbd[i].fd);
			kbd[i].fd = -1;
		}
	}
	nkbd = 0;
	wake_fd = -1;
	if (log_fd >= 0) {
		close(log_fd);
		log_fd = -1;
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
	struct evdev_wire_event ev;
	ssize_t n;
	int checked = 0;
	int idx;

	while (checked < nkbd) {
		idx = next_kbd;
		next_kbd = (next_kbd + 1) % nkbd;
		checked++;

		n = read(kbd[idx].fd, &ev, sizeof(ev));
		if (n < 0) {
			if (errno == EAGAIN || errno == EINTR)
				continue;
			return KBD_FAIL;
		}
		if (n != sizeof(ev))
			continue;

		checked = 0;
		if (event_traces++ < EVDEV_TRACE_LIMIT)
			evdev_log("%s event type=%u code=%u value=%d",
				  kbd[idx].name, ev.type, ev.code, ev.value);

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
		} else if (mw == MWKEY_CAPSLOCK && ev.value == 1) {
			caps_lock = !caps_lock;
		}

		if (!bit)
			mw = apply_printable_modifiers(ev.code, mw);

		*kbuf = mw;
		*modifiers = mod_state;
		*scancode = ev.code;
		if (ev.value)
			return KBD_KEYPRESS;
		else
			return KBD_KEYRELEASE;
	}

	return KBD_NODATA;
}
