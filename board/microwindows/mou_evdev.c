/*
 * Linux evdev touchscreen mouse driver for Microwindows / Nano-X.
 *
 * Opens /dev/input/event1 (the BE-300 PIU touchscreen registered by
 * board/casio-be300/touch_be300.c) and translates ABS_X / ABS_Y / BTN_TOUCH
 * events into MOUSE_ABSPOS reports.
 *
 * Copyright (C) 2026 John Roark
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <linux/input.h>
#include "device.h"

#ifndef EVDEV_TOUCH_DEV
#define EVDEV_TOUCH_DEV		"/dev/input/event1"
#endif

#define	SCALE			3
#define	THRESH			5

static int	EVDEV_Open(MOUSEDEVICE *pmd);
static void	EVDEV_Close(void);
static int	EVDEV_GetButtonInfo(void);
static void	EVDEV_GetDefaultAccel(int *pscale, int *pthresh);
static int	EVDEV_Read(MWCOORD *dx, MWCOORD *dy, MWCOORD *dz, int *bp);
static int	EVDEV_Poll(void);

MOUSEDEVICE mousedev = {
	EVDEV_Open,
	EVDEV_Close,
	EVDEV_GetButtonInfo,
	EVDEV_GetDefaultAccel,
	EVDEV_Read,
	EVDEV_Poll,
};

static int		fd = -1;
static MWCOORD		last_x;
static MWCOORD		last_y;
static int		buttons;	/* MWBUTTON_L bit set when pen down */
static int		have_sample;	/* true after first ABS report seen */

static int
EVDEV_Open(MOUSEDEVICE *pmd)
{
	const char *dev = getenv("MWMOUSE") ? getenv("MWMOUSE") : EVDEV_TOUCH_DEV;

	fd = open(dev, O_RDONLY | O_NONBLOCK);
	if (fd < 0)
		return DRIVER_FAIL;
	last_x = last_y = 0;
	buttons = 0;
	have_sample = 0;
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
 * Drain pending evdev events up to the next EV_SYN. Returns:
 *   MOUSE_ABSPOS — a complete (x,y,buttons) sample is available
 *   MOUSE_NODATA — no syn yet, or no events pending
 *   MOUSE_FAIL   — read error
 */
static int
EVDEV_Read(MWCOORD *dx, MWCOORD *dy, MWCOORD *dz, int *bp)
{
	struct input_event ev;
	ssize_t n;
	int got_syn = 0;

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
			if (ev.code == ABS_X)
				last_x = (MWCOORD)ev.value;
			else if (ev.code == ABS_Y)
				last_y = (MWCOORD)ev.value;
			have_sample = 1;
		} else if (ev.type == EV_KEY) {
			if (ev.code == BTN_TOUCH) {
				if (ev.value)
					buttons |= MWBUTTON_L;
				else
					buttons &= ~MWBUTTON_L;
				have_sample = 1;
			}
		} else if (ev.type == EV_SYN) {
			got_syn = 1;
			break;
		}
	}

	if (!got_syn || !have_sample)
		return MOUSE_NODATA;

	*dx = last_x;
	*dy = last_y;
	*dz = 0;
	*bp = buttons;
	return MOUSE_ABSPOS;
}

static int
EVDEV_Poll(void)
{
	return 1;
}
