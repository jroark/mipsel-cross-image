/* Recovered BE-300 board transactions, shared by Linux 2.4/2.6/4.2.
 * WinCE SPL 80F034A0/80F038DC; NK 80076D94; ddi 01A56A5C.
 * The host trace test supplies MMIO/delay primitives. See docs/HARDWARE.md.
 */
#ifndef BE300_HARDWARE_REGS_H
#define BE300_HARDWARE_REGS_H

#ifndef BE300_R32
#define BE300_R32(pa) readl((void __iomem *)(0xa0000000UL | (pa)))
#define BE300_W32(pa, v) writel((v), (void __iomem *)(0xa0000000UL | (pa)))
#define BE300_R16(pa) readw((void __iomem *)(0xa0000000UL | (pa)))
#define BE300_W16(pa, v) writew((v), (void __iomem *)(0xa0000000UL | (pa)))
#define BE300_DELAY(us) udelay(us)
#endif

#define BE300_LCD(off) (0x0a000c00UL + (off))
#define BE300_BLG(off) (0x0a000980UL + (off))
#define BE300_CMM 0x0a001128UL

static void be300_regs_contrast(unsigned int level)
{
	unsigned int command = 208 - level * 3;
	u32 pins = BE300_R32(BE300_LCD(0x4c)) & ~7U;
	int bit;

	for (bit = 7; bit >= 0; bit--) {
		BE300_W32(BE300_LCD(0x4c), pins);
		BE300_W32(BE300_LCD(0x4c), pins | (((command >> bit) & 1) << 2));
		BE300_DELAY(5);
		BE300_W32(BE300_LCD(0x4c), pins | (((command >> bit) & 1) << 2) | 2);
		BE300_DELAY(5);
	}
	BE300_W32(BE300_LCD(0x4c), pins);
	BE300_DELAY(5);
	BE300_W32(BE300_LCD(0x4c), pins | 1);
	BE300_DELAY(5);
	BE300_W32(BE300_LCD(0x4c), pins);
	BE300_DELAY(5);
}

static void be300_regs_brightness(unsigned int level)
{
	static const unsigned int duty[] = {3339, 3339, 2553, 1964, 981, 0};

	BE300_W32(BE300_BLG(0x0c), duty[level]);
}

static void be300_regs_lcd_init(void)
{
	BE300_W32(BE300_CMM, BE300_R32(BE300_CMM) | 1);
	BE300_W32(0x0a001100, BE300_R32(0x0a001100) | 1);
	BE300_W32(0x0a00110c, BE300_R32(0x0a00110c) | 1);
	BE300_W32(BE300_BLG(0), 0);
	BE300_W32(BE300_BLG(4), (BE300_R32(BE300_BLG(4)) & ~15U) | 2);
	BE300_W32(BE300_BLG(8), 0x0f70);
	be300_regs_brightness(5);
	BE300_W32(BE300_BLG(0), 1);
	BE300_W32(BE300_LCD(0), 0x20);
	BE300_W32(BE300_LCD(4), 2);
	BE300_W32(BE300_LCD(8), 0x50);
	BE300_W32(BE300_LCD(0x0c), 0xf1);
	BE300_W32(BE300_LCD(0x10), 2);
	BE300_W32(BE300_LCD(0x14), 0);
	BE300_W32(BE300_LCD(0x1c), 0);
	BE300_W32(BE300_LCD(0x24), 0x14);
	BE300_W32(BE300_LCD(0x48), 0);
	BE300_W32(BE300_LCD(0x48), 1);
	BE300_DELAY(1000);
	BE300_W32(BE300_LCD(0x48), 0x101);
	BE300_W32(BE300_LCD(0x2c), 1);
	be300_regs_contrast(5);
	BE300_W32(BE300_LCD(0x48), 0x103);
	BE300_DELAY(1000);
	BE300_W32(BE300_LCD(0x48), 0x10f);
	/* Avoid architecture-specific limits on a constant udelay(20000). */
	{
		unsigned int n;
		for (n = 0; n < 20; n++)
			BE300_DELAY(1000);
	}
	BE300_W32(BE300_LCD(0x48), 0x30f);
}

static int be300_regs_piu_prepare(void)
{
	unsigned int n;

	BE300_W32(0x0a001118, BE300_R32(0x0a001118) | 1);
	BE300_W32(0x0a0003c8, BE300_R32(0x0a0003c8) | 3);
	BE300_W16(0x0a000304, 0); /* keep masked until the input driver is ready */
	BE300_W16(0x0a000300, BE300_R16(0x0a000300) | 1);
	for (n = 0; n < 10000; n++) {
		if (!(BE300_R16(0x0a000300) & 1))
			break;
		BE300_DELAY(1);
	}
	if (n == 10000)
		return -1;
	BE300_W16(0x0a000308, 0x05dc);
	BE300_W16(0x0a00030c, 0x00c8);
	BE300_W16(0x0a000310, 0x0032);
	BE300_W16(0x0a000318, 1);
	BE300_W16(0x0a000304, 0x00ff); /* W1C pending, source still masked */
	return 0;
}

static void be300_regs_watchdog_reload(void)
{
	(void)BE300_R32(0x0a007834);
	BE300_W32(0x0a007814, 0x96);
}

static void be300_regs_watchdog_poll(void)
{
	/* cedmbltin.dll 019F19C4/019F1A00/019F1A0C. STATUS may be 3 on
	 * hardware; reading it is not a requirement that it become zero. */
	(void)BE300_R32(0x0a007834);
	BE300_W32(0x0a00780c, 0x53);
	BE300_W32(0x0a007808, 0x3a);
}

static void be300_regs_giu0(void)
{
	/* NK 800A5F60/6C/78/80: change only the pin owned by this cascade. */
	BE300_W16(0x0f000140, BE300_R16(0x0f000140) & ~1U);
	BE300_W16(0x0f000150, BE300_R16(0x0f000150) & ~1U);
	BE300_W16(0x0f000154, BE300_R16(0x0f000154) | 1);
	BE300_W16(0x0f000158, BE300_R16(0x0f000158) | 1);
}
#endif
