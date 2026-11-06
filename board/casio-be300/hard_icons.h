/*
 * The BE-300's hard icons: the touch panel is taller than the 240x320 LCD
 * and covers a printed strip of seven icons below it. Windows CE's
 * touch.dll holds them as a table (glaze-os docs/os/HARD_ICONS.md); Casio's
 * developer specification has ICON1..ICON7 send VK_LWIN+F1..F7. Linux
 * sends KEY_F1..KEY_F7 from the "BE-300 Hard Icons" input device.
 *
 * Stroke rule, as Glaze's: a stroke whose first sample lands on the strip
 * (y >= 320 on a panel scaled to 360 rows) belongs to the icons and
 * reports no pointer events; it fires on release if the pen is still over
 * the same icon and no more than BE300_ICON_SLOP rows above the strip. A
 * stroke that starts on the LCD stays a pointer stroke, clamped to the
 * bottom row.
 *
 * No kernel API is used, so the host tests and all three kernels share it.
 */
#ifndef BE300_HARD_ICONS_H
#define BE300_HARD_ICONS_H

#define BE300_LCD_ROWS		320
#define BE300_PANEL_ROWS	360	/* LCD plus the icon strip */
#define BE300_ICON_COUNT	7
#define BE300_ICON_SLOP		8

/* Icon under column x: touch.dll's quarter-pixel table in columns. */
static inline int be300_icon_zone(int x)
{
	static const short last[BE300_ICON_COUNT] = {
		33, 68, 102, 136, 170, 205, 239
	};
	int n;

	for (n = 0; n < BE300_ICON_COUNT - 1; n++)
		if (x <= last[n])
			return n;
	return BE300_ICON_COUNT - 1;
}

/* strip is 0 for a pointer stroke, icon + 1 for a strip stroke, so a
 * zero-initialized state is a pointer stroke. */
struct be300_icon_stroke {
	int strip, x, y;
};

/* A stroke's first sample: returns nonzero if it belongs to the strip. */
static inline int be300_icon_begin(struct be300_icon_stroke *s, int x, int y)
{
	s->strip = y >= BE300_LCD_ROWS ? be300_icon_zone(x) + 1 : 0;
	s->x = x;
	s->y = y;
	return s->strip;
}

static inline void be300_icon_move(struct be300_icon_stroke *s, int x, int y)
{
	s->x = x;
	s->y = y;
}

/* Pen-up: the icon to fire (0..6), or -1. Ends the strip stroke. */
static inline int be300_icon_end(struct be300_icon_stroke *s)
{
	int icon = s->strip - 1;

	s->strip = 0;
	if (icon < 0 || s->y < BE300_LCD_ROWS - BE300_ICON_SLOP ||
	    be300_icon_zone(s->x) != icon)
		return -1;
	return icon;
}
#ifdef __KERNEL__
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 15)
#include <linux/workqueue.h>
/*
 * The buzzer and hard-icon devices register after the board's buttons,
 * touch panel and Stowaway keyboard so their /dev/input/event numbers
 * (0, 1, 2 on 4.2) do not move. Stowaway binds through serio's work on
 * system_long_wq, queued by an earlier late initcall: let it finish.
 */
static inline void be300_input_settle(void)
{
	flush_workqueue(system_long_wq);
}
#endif
#endif
#endif
