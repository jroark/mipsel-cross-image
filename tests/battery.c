/* battery.h against Windows CE's gwes.exe arithmetic (glaze-os
 * glaze/battery.h): calibration decode, averaging, bands and levels.
 * cc -std=gnu89 -Wall -Wextra -Werror tests/battery.c */
#include <assert.h>
#include <stdio.h>
#include "../board/casio-be300/battery.h"

int main(void)
{
	struct be300_batt_cal c;
	unsigned short s[BE300_BATT_SAMPLES] = {0};
	int i;

	/* Erased EEPROM (FF FF): CE's 4.2 V / 3.7 V defaults. */
	assert(!be300_batt_cal_decode(0xff, 0xff, &c));
	assert(c.max == 0xd96 && c.min == 0xbf8);
	assert(c.t75 == 0xd96 - 414 * 2 / 5 && c.t50 == 0xd96 - 414 * 4 / 5);
	assert(c.t25 == 0xbf8 && c.t10 == 0xbf8 - 41 && c.t0 == 0xbf8 - 248);
	/* A programmed part: b1 < b0, two counts per bit plus CE's 0xC02. */
	assert(be300_batt_cal_decode(0x65, 0x00, &c));
	assert(c.max == ((0x65 << 2) | 0xc02) && c.min == 0xc02);
	assert(be300_batt_cal_decode(0x90, 0x80, &c) && c.min == ((0x80 << 2) | 0x802));
	be300_batt_cal_decode(0xff, 0xff, &c);
	/* Bands and the piecewise level agree when rounded up. */
	assert(be300_batt_band(c.max, &c) == 100 && be300_batt_level(c.max, &c) == 100);
	assert(be300_batt_band(c.t25, &c) == 25 && be300_batt_level(c.t25, &c) == 25);
	assert(be300_batt_band(3300, &c) == 75 && be300_batt_level(3300, &c) == 73);
	assert(be300_batt_band(c.t10, &c) == 10 && be300_batt_level(c.t0, &c) == 0);
	assert(be300_batt_level(0xfff, &c) == 100 && be300_batt_level(100, &c) == 0);
	for (i = 0; i < 4096; i += 7) {
		unsigned int l = be300_batt_level(i, &c), b = be300_batt_band(i, &c);
		assert(l <= b && (b == 10 || l >= (b == 100 ? 75U : b == 75 ? 50U : b == 50 ? 25U : 10U)));
	}
	/* Averaging: zeros skipped; a full window drops its largest sample. */
	assert(be300_batt_average(s, BE300_BATT_SAMPLES) == 0);
	s[0] = 3000; s[1] = 3100;
	assert(be300_batt_average(s, BE300_BATT_SAMPLES) == 3050);
	for (i = 0; i < BE300_BATT_SAMPLES; i++)
		s[i] = 3000;
	s[9] = 4000;
	assert(be300_batt_average(s, BE300_BATT_SAMPLES) == 3000);
	puts("battery calibration, averaging, bands and levels passed");
	return 0;
}
