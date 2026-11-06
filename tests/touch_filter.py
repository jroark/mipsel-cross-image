#!/usr/bin/env python3
"""Host test for board/casio-be300/touch_filter.h (legacy 2.4/2.6 PIU drivers)."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#include <assert.h>
#include "touch_filter.h"
static struct { int x, y, down; } ev[64]; static int n;
static void out(int x, int y, int down) { ev[n].x = x; ev[n].y = y; ev[n].down = down; n++; }
static int icon = -1;
static void fire(int i) { icon = i; }
int main(void) {
    struct be300_stroke s = {0};
    /* Still tap: settling and lift-off samples jump, steady ones jitter. */
    static const int xs[] = {60, 100, 101, 99, 100, 150};
    be300_stroke_pen_change(&s, 1, out);
    for (int i = 0; i < 6; i++) be300_stroke_sample(&s, xs[i], 200, out);
    be300_stroke_pen_change(&s, 0, out);
    assert(n == 2 && ev[0].down == 1 && ev[1].down == 0);
    assert(ev[0].x >= 99 && ev[0].x <= 101 && ev[0].y == 200);
    /* A tap with one page still lands where it began. */
    n = 0; be300_stroke_pen_change(&s, 1, out);
    be300_stroke_sample(&s, 30, 40, out); be300_stroke_pen_change(&s, 0, out);
    assert(n == 2 && ev[0].x == 30 && ev[0].y == 40 && ev[0].down && !ev[1].down);
    /* A real drag moves, and the press never lands at a stale (0,0). */
    n = 0; be300_stroke_pen_change(&s, 1, out);
    for (int i = 0; i < 10; i++) be300_stroke_sample(&s, 10 + i * 10, 50, out);
    be300_stroke_pen_change(&s, 0, out);
    assert(n > 3 && ev[0].x > 0 && ev[n - 2].x > ev[0].x + 40 && !ev[n - 1].down);
    /* Hard icons: a strip tap fires its icon and reports no pointer. */
    struct be300_stroke t = {0};
    t.icon_out = fire;
    n = 0; be300_stroke_pen_change(&t, 1, out);
    for (int i = 0; i < 4; i++) be300_stroke_sample(&t, 220, 345, out);
    be300_stroke_pen_change(&t, 0, out);
    assert(n == 0 && icon == 6);
    /* Released above the strip's slop: nothing fires. */
    icon = -1; be300_stroke_pen_change(&t, 1, out);
    be300_stroke_sample(&t, 10, 330, out); be300_stroke_sample(&t, 10, 300, out);
    be300_stroke_pen_change(&t, 0, out);
    assert(n == 0 && icon == -1);
    /* An LCD stroke sliding onto the strip stays clamped to row 319. */
    n = 0; be300_stroke_pen_change(&t, 1, out);
    for (int i = 0; i < 8; i++) be300_stroke_sample(&t, 50, 280 + i * 10, out);
    be300_stroke_pen_change(&t, 0, out);
    assert(n > 2 && icon == -1 && ev[n - 2].y == 319 && !ev[n - 1].down);
    for (int i = 0; i < n; i++) assert(ev[i].y < 320);
    /* touch.dll's zones. */
    assert(be300_icon_zone(0) == 0 && be300_icon_zone(33) == 0 && be300_icon_zone(34) == 1);
    assert(be300_icon_zone(170) == 4 && be300_icon_zone(171) == 5 && be300_icon_zone(239) == 6);
    /* The ADC valid flag gates whole pages. */
    unsigned short page[8] = {0x8001, 0, 0x8001, 0, 0x8001, 0, 0x8001, 0};
    assert(be300_page_valid(page));
    page[4] = 0x0001; assert(!be300_page_valid(page));
    return 0;
}
'''

class TouchFilterTests(unittest.TestCase):
    def test_filter(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / 't.c'; src.write_text(SOURCE)
            subprocess.run(['cc', '-std=gnu99', '-Wall', '-Wextra', '-Werror',
                            '-I' + str(ROOT / 'board/casio-be300'), str(src),
                            '-o', str(Path(tmp) / 't')], check=True)
            subprocess.run([str(Path(tmp) / 't')], check=True)

if __name__ == '__main__':
    unittest.main()
