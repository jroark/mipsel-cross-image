/* SPDX-License-Identifier: GPL-2.0-only
 * Casio wave-output transactions; register evidence: docs/HARDWARE.md.
 * This is not the VRC4173 AIU. Ends are inclusive KSEG1 DMA addresses.
 */
#ifndef BE300_AUDIO_REGS_H
#define BE300_AUDIO_REGS_H
#ifndef AUDIO_R
#define AUDIO_R(off) readl((void __iomem *)(0xaa000000UL + (off)))
#define AUDIO_W(off, v) writel((v), (void __iomem *)(0xaa000000UL + (off)))
#define AUDIO_R16(off) readw((void __iomem *)(0xaa000000UL + (off)))
#define AUDIO_W16(off, v) writew((v), (void __iomem *)(0xaa000000UL + (off)))
#define AUDIO_DELAY(us) udelay(us)
#endif
static int audio_codec(unsigned int command)
{
	unsigned int i;
	for (i = 0; i < 10000 && !AUDIO_R(0x3c4); i++)
		AUDIO_DELAY(1);
	if (i == 10000)
		return -ETIMEDOUT;
	AUDIO_W(0x3c0, command);
	for (i = 0; i < 10000 && !AUDIO_R(0x3c4); i++)
		AUDIO_DELAY(1);
	return i == 10000 ? -ETIMEDOUT : 0;
}
static void audio_ack(void)
{
	AUDIO_W16(0x8c8, 0x11);
	AUDIO_W16(0x8cc, 0x11);
}
static void audio_disable(void)
{
	AUDIO_W(0x30, AUDIO_R(0x30) & ~8U);
	AUDIO_W(0x8a0, 0);
	AUDIO_W16(0x880, AUDIO_R16(0x880) & ~8U);
	AUDIO_W16(0x884, AUDIO_R16(0x884) | 1);
	AUDIO_W(0x898, AUDIO_R(0x898) & ~1U);
	AUDIO_W(0x890, AUDIO_R(0x890) & ~2U);
}
static unsigned int audio_rate(unsigned int requested, unsigned int *code,
			       unsigned int *double_rate)
{
	static const unsigned int rates[] = {8000,  11025, 16000,
					     22050, 32000, 44100};
	static const unsigned int codes[] = {0x40, 0x10, 0x30, 0, 0x30, 0};
	unsigned int i, best = 0, delta, distance = ~0U;
	for (i = 0; i < 6; i++) {
		delta = requested > rates[i] ? requested - rates[i]
					     : rates[i] - requested;
		if (delta < distance) {
			best = i;
			distance = delta;
		}
	}
	*code = codes[best];
	*double_rate = best >= 4;
	return rates[best];
}
static int audio_prepare(unsigned int rate, unsigned int channels)
{
	unsigned int code, x2;
	int ret;
	audio_rate(rate, &code, &x2);
	AUDIO_W16(0x888, (AUDIO_R16(0x888) & ~2U) | (channels == 1 ? 2 : 0));
	AUDIO_W(0x890, AUDIO_R(0x890) | 2);
	audio_ack();
	AUDIO_W16(0x884, AUDIO_R16(0x884) | 1);
	AUDIO_W16(0x880, AUDIO_R16(0x880) | 8);
	if (!(AUDIO_R16(0x884) & 4)) {
		AUDIO_W16(0x8a0, 0);
		AUDIO_DELAY(1000);
	}
	AUDIO_W(0x1104, 1);
	AUDIO_W(0x8c4, 1);
	AUDIO_W16(0x8cc, 0x11);
	AUDIO_W(0x8c8, AUDIO_R16(0x8cc));
	AUDIO_W(0x880, (AUDIO_R16(0x880) & ~0x70U) | code);
	AUDIO_W(0x888, AUDIO_R(0x888) & ~4U);
	ret = audio_codec(0x5000);
	if (!ret)
		ret = audio_codec((AUDIO_R(0x3f4) & 0x80) | 0xd007);
	if (!ret)
		ret = audio_codec(0xd007 | (x2 << 7));
	if (!ret) {
		AUDIO_W(0x884, AUDIO_R(0x884) | 2);
		AUDIO_W(0x880, AUDIO_R(0x880) | 4);
		ret = audio_codec(0xd001 | (x2 << 7));
	}
	if (ret) {
		audio_disable();
		return ret;
	}
	/* Use short delays on all three MIPS delay implementations. */
	for (code = 0; code < 5; code++)
		AUDIO_DELAY(1000);
	return 0;
}
#endif
