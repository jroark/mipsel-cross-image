/*
 * Linux evdev touchscreen mouse driver for Microwindows / Nano-X.
 *
 * Opens the BE-300 PIU touchscreen evdev node and translates ABS_X / ABS_Y /
 * BTN_TOUCH events into MOUSE_ABSPOS reports.
 *
 * Copyright (C) 2026 John Roark
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include "device.h"

#ifndef EVDEV_TOUCH_DEV
#define EVDEV_TOUCH_DEV		NULL
#endif

#define	EVDEV_TOUCH_NAME	"BE-300 PIU touchscreen"
#define	EVDEV_EVENT_FMT		"/dev/input/event%d"
#define	EVDEV_MAX_EVENTS	8

#define	SCALE			3
#define	THRESH			5

static int	EVDEV_Open(MOUSEDEVICE *pmd);
static void	EVDEV_Close(void);
static int	EVDEV_GetButtonInfo(void);
static void	EVDEV_GetDefaultAccel(int *pscale, int *pthresh);
static int	EVDEV_Read(MWCOORD *dx, MWCOORD *dy, MWCOORD *dz, int *bp);

extern SCREENDEVICE scrdev;

MOUSEDEVICE mousedev = {
	EVDEV_Open,
	EVDEV_Close,
	EVDEV_GetButtonInfo,
	EVDEV_GetDefaultAccel,
	EVDEV_Read,
	NULL,
	MOUSE_RAW,
};

static int		fd = -1;
static MWCOORD		last_x;
static MWCOORD		last_y;
static int		buttons;	/* MWBUTTON_L bit set when pen down */
static int		have_pos;	/* true after first touchscreen sample */

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

static int
open_evdev_by_name(const char *override, const char *want_name)
{
	char path[sizeof(EVDEV_EVENT_FMT) + 3];
	char name[80];
	int i, tfd;

	if (override && override[0])
		return open(override, O_RDONLY | O_NONBLOCK);

	for (i = 0; i < EVDEV_MAX_EVENTS; i++) {
		snprintf(path, sizeof(path), EVDEV_EVENT_FMT, i);
		tfd = open(path, O_RDONLY | O_NONBLOCK);
		if (tfd < 0)
			continue;

		memset(name, 0, sizeof(name));
		if (ioctl(tfd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
		    strcmp(name, want_name) == 0)
			return tfd;

		close(tfd);
	}

	return -1;
}

static int
EVDEV_Open(MOUSEDEVICE *pmd)
{
	const char *dev = getenv("MWMOUSE") ? getenv("MWMOUSE") : EVDEV_TOUCH_DEV;

	fd = open_evdev_by_name(dev, EVDEV_TOUCH_NAME);
	if (fd < 0)
		return DRIVER_FAIL;
	ioctl(fd, EVIOCGRAB, 1);
	last_x = last_y = 0;
	buttons = 0;
	have_pos = 0;
	GdHideCursor(&scrdev);
	return DRIVER_OKFILEDESC(fd);
}

static void
EVDEV_Close(void)
{
	if (fd >= 0) {
		ioctl(fd, EVIOCGRAB, 0);
		close(fd);
		fd = -1;
	}
}

static int
EVDEV_GetButtonInfo(void)
{
	return MWBUTTON_L;
}

static void
EVDEV_GetDefaultAccel(int *pscale, int *pthresh)
{
	*pscale = SCALE;
	*pthresh = THRESH;
}

/*
 * The BE-300 touch driver emits BTN_TOUCH in a PENCHG packet, followed by
 * ABS_X/ABS_Y/ABS_PRESSURE in a page packet. Do not report the first
 * button-only packet as a click at (0,0); retain the button state and wait
 * until a packet with position/pressure data arrives.
 */
static int
EVDEV_Read(MWCOORD *dx, MWCOORD *dy, MWCOORD *dz, int *bp)
{
	struct evdev_wire_event ev;
	ssize_t n;
	int packet_changed = 0;
	int packet_has_sample = 0;

	for (;;) {
		n = read(fd, &ev, sizeof(ev));
		if (n < 0) {
			if (errno == EAGAIN || errno == EINTR)
				break;
			return MOUSE_FAIL;
		}
		if (n != sizeof(ev))
			break;

		if (ev.type == EV_ABS) {
			if (ev.code == ABS_X) {
				last_x = (MWCOORD)ev.value;
				have_pos = 1;
				packet_changed = 1;
				packet_has_sample = 1;
			} else if (ev.code == ABS_Y) {
				last_y = (MWCOORD)ev.value;
				have_pos = 1;
				packet_changed = 1;
				packet_has_sample = 1;
			} else if (ev.code == ABS_PRESSURE) {
				if (ev.value)
					buttons |= MWBUTTON_L;
				else
					buttons &= ~MWBUTTON_L;
				packet_changed = 1;
				if (have_pos)
					packet_has_sample = 1;
			}
		} else if (ev.type == EV_KEY) {
			if (ev.code == BTN_TOUCH) {
				if (ev.value)
					buttons |= MWBUTTON_L;
				else
					buttons &= ~MWBUTTON_L;
				packet_changed = 1;
			}
		} else if (ev.type == EV_SYN) {
			if (ev.code == SYN_DROPPED) {
				packet_changed = 0;
				packet_has_sample = 0;
				continue;
			}
			if (packet_changed && packet_has_sample && have_pos)
				break;
			packet_changed = 0;
			packet_has_sample = 0;
		}
	}

	if (!packet_changed || !packet_has_sample || !have_pos)
		return MOUSE_NODATA;

	*dx = last_x;
	*dy = last_y;
	*dz = 0;
	*bp = buttons;
	return MOUSE_ABSPOS;
}
