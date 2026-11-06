/*
 * BE-300 battery level arithmetic, shared by battery.c on Linux 2.4/2.6/4.2
 * and tests/battery.c. It follows Windows CE's battery driver in gwes.exe
 * (VA = file offset + 0x10000), as glaze-os glaze/battery.h does:
 *   calibration  0xB0AF0-0xB0D30, from E2pRead(0x4A) bytes 0 (max), 1 (min)
 *   averaging    0xB05B0-0xB069C, ten samples, the largest dropped
 *   bands        0xB06A0-0xB06FC, plus the min - 3 * span / 5 edge (3.4 V)
 *   critical     0xB0778-0xB07EC, two 10 % readings since the adapter
 * No kernel API is used.
 */
#ifndef BE300_BATTERY_H
#define BE300_BATTERY_H

#define BE300_BATT_CAL_MAX	0x0d96U	/* 4.2 V (gwes 0xB0C08) */
#define BE300_BATT_CAL_MIN	0x0bf8U	/* 3.7 V (gwes 0xB0C04) */
#define BE300_BATT_SAMPLES	10	/* gwes 0xB0624 */

struct be300_batt_cal {
	unsigned int min, max;
	unsigned int t75, t50, t25, t10;	/* at or below tN is N % */
	unsigned int t0;			/* 3.4 V: empty */
};

/* EEPROM bytes b0 (max), b1 (min) to A/D counts; 0 when unusable and CE's
 * defaults were taken. The 0x802 case is CE's, odd as it looks. */
static inline int be300_batt_cal_decode(unsigned int b0, unsigned int b1,
					struct be300_batt_cal *c)
{
	int eeprom = b1 < b0, span, t0;

	if (eeprom) {
		c->max = (b0 << 2) | 0xc02U;
		c->min = (b1 << 2) | (b1 < 0x7f ? 0xc02U : 0x802U);
	} else {
		c->max = BE300_BATT_CAL_MAX;
		c->min = BE300_BATT_CAL_MIN;
	}
	span = (int)c->max - (int)c->min;
	c->t75 = c->max - span * 2 / 5;
	c->t50 = c->max - span * 4 / 5;
	c->t25 = c->min;
	c->t10 = c->min - span / 10;
	t0 = (int)c->min - span * 3 / 5;
	c->t0 = t0 > 0 ? t0 : 0;
	return eeprom;
}

/* Mean of the non-zero samples; of all ten, without the largest. */
static inline unsigned int be300_batt_average(const unsigned short *samples,
					      int n)
{
	unsigned int sum = 0, count = 0, max = 0;
	int i;

	for (i = 0; i < n; i++) {
		if (!samples[i])
			continue;
		sum += samples[i];
		count++;
		if (samples[i] > max)
			max = samples[i];
	}
	if (count == BE300_BATT_SAMPLES)
		return (sum - max) / (count - 1);
	return count ? sum / count : 0;
}

/* CE's reported percentage band. */
static inline unsigned int be300_batt_band(unsigned int avg,
					   const struct be300_batt_cal *c)
{
	if (avg <= c->t10)
		return 10;
	if (avg <= c->t25)
		return 25;
	if (avg <= c->t50)
		return 50;
	if (avg <= c->t75)
		return 75;
	return 100;
}

/* Piecewise linear through CE's band edges: 0 % at 3.4 V, then 10, 25,
 * 50, 75 and 100 %. Rounded up to a band it equals be300_batt_band(). */
static inline unsigned int be300_batt_level(unsigned int avg,
					    const struct be300_batt_cal *c)
{
	unsigned int at[6];
	static const unsigned char pct[6] = { 0, 10, 25, 50, 75, 100 };
	int i;

	at[0] = c->t0; at[1] = c->t10; at[2] = c->t25;
	at[3] = c->t50; at[4] = c->t75; at[5] = c->max;
	if (avg <= at[0])
		return 0;
	for (i = 1; i < 6; i++) {
		if (avg > at[i])
			continue;
		if (at[i] <= at[i - 1])
			return pct[i];
		return pct[i - 1] + (avg - at[i - 1]) * (pct[i] - pct[i - 1]) /
			(at[i] - at[i - 1]);
	}
	return 100;
}
#endif
