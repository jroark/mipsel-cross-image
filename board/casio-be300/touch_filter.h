/*
 * Touch stroke filter for the BE-300 resistive panel, shared by the
 * Linux 2.4 and 2.6 PIU drivers (install_board_hardware.py wires it in).
 * The 4.2 driver carries the same logic inline in touch_be300.c.
 *
 * A real panel's samples jump by more than a tap's slop as the contact
 * settles and again at lift-off (the emulator's are exact), so an
 * unfiltered tap reads as a drag. As Glaze (kernel/drivers/input.c) and
 * tslib do: drop pages without the ADC valid bit, drop the first sample
 * after pen-down, hold the newest back so the lift-off sample is never
 * reported, average the last BE300_STROKE_N and ignore moves under
 * BE300_STROKE_MOVE_MIN pixels. Verified on hardware with 4.2 (2026-11-01).
 *
 * No kernel API is used: output goes through a (x, y, down) callback.
 */
#ifndef BE300_TOUCH_FILTER_H
#define BE300_TOUCH_FILTER_H

#define BE300_STROKE_N		3
#define BE300_STROKE_MOVE_MIN	2
#define BE300_ADC_VALID		0x8000

typedef void (*be300_stroke_out)(int x, int y, int down);

struct be300_stroke {
	int samples, first_x, first_y;
	int win_x[BE300_STROKE_N], win_y[BE300_STROKE_N], win_n;
	int held, held_x, held_y;
	int pen_down, pen_x, pen_y;
};

/* All four plates (y+, y-, x-, x+) must carry the valid flag. */
static inline int be300_page_valid(volatile unsigned short *pb0)
{
	return (pb0[0] & pb0[2] & pb0[4] & pb0[6] & BE300_ADC_VALID) != 0;
}

static inline void be300_stroke_reset(struct be300_stroke *s)
{
	s->samples = 0;
	s->win_n = 0;
	s->held = 0;
}

static inline void be300_stroke_emit(struct be300_stroke *s, int x, int y,
				     be300_stroke_out out)
{
	if (s->pen_down) {
		int dx = x - s->pen_x, dy = y - s->pen_y;

		if (dx < BE300_STROKE_MOVE_MIN && dx > -BE300_STROKE_MOVE_MIN &&
		    dy < BE300_STROKE_MOVE_MIN && dy > -BE300_STROKE_MOVE_MIN)
			return;
	}
	out(x, y, 1);
	s->pen_down = 1;
	s->pen_x = x;
	s->pen_y = y;
}

static inline void be300_stroke_sample(struct be300_stroke *s, int x, int y,
				       be300_stroke_out out)
{
	int i, k, n, sx = 0, sy = 0;

	if (s->samples++ == 0) {
		s->first_x = x;
		s->first_y = y;
		return;
	}
	i = s->win_n++ % BE300_STROKE_N;
	n = s->win_n < BE300_STROKE_N ? s->win_n : BE300_STROKE_N;
	s->win_x[i] = x;
	s->win_y[i] = y;
	for (k = 0; k < n; k++) {
		sx += s->win_x[k];
		sy += s->win_y[k];
	}
	if (s->held)
		be300_stroke_emit(s, s->held_x, s->held_y, out);
	s->held = 1;
	s->held_x = sx / n;
	s->held_y = sy / n;
}

/* Pen-up drops the held lift-off sample, unless the tap was too short to
 * report anything; then it lands where it began. */
static inline void be300_stroke_release(struct be300_stroke *s,
					be300_stroke_out out)
{
	if (!s->pen_down && s->samples)
		be300_stroke_emit(s, s->held ? s->held_x : s->first_x,
				  s->held ? s->held_y : s->first_y, out);
	if (s->pen_down) {
		s->pen_down = 0;
		out(s->pen_x, s->pen_y, 0);
	}
	be300_stroke_reset(s);
}

/* A pen-change interrupt: a new stroke starts clean; a lift ends it. */
static inline void be300_stroke_pen_change(struct be300_stroke *s, int down,
					   be300_stroke_out out)
{
	if (down) {
		if (!s->pen_down)
			be300_stroke_reset(s);
	} else {
		be300_stroke_release(s, out);
	}
}
#endif
