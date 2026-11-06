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
#define BE300_R8(pa) readb((void __iomem *)(0xa0000000UL | (pa)))
#define BE300_W8(pa, v) writeb((v), (void __iomem *)(0xa0000000UL | (pa)))
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

/*
 * Piezo on the second BLG PWM channel, from the stock bltinbuz.dll
 * (glaze-os kernel/drivers/buzzer.c, docs/hardware/BUZZER.md; beeps heard
 * on a real BE-300): stop 09A0, shared clock gate 1128 bit 0, OR 0202 into
 * the shared configuration 0984, period 09A4 = 1411200/Hz - 1, duty 09A8 =
 * period*(100-pulse)/100 - 1, start 09A0. Never touches the backlight's
 * own 0980/0988/098C. hz 0 only stops the channel.
 */
#define BE300_BUZZER_CLOCK 1411200U

static void be300_regs_buzzer(unsigned int hz, unsigned int pulse)
{
	unsigned int period;

	BE300_W32(BE300_BLG(0x20), 0);
	if (!hz)
		return;
	period = BE300_BUZZER_CLOCK / hz - 1;
	if (period > 0xffff)
		period = 0xffff;
	BE300_W32(BE300_CMM, BE300_R32(BE300_CMM) | 1);
	BE300_W32(BE300_BLG(4), BE300_R32(BE300_BLG(4)) | 0x0202);
	BE300_W32(BE300_BLG(0x24), period);
	BE300_W32(BE300_BLG(0x28), period * (100 - pulse) / 100 - 1);
	BE300_W32(BE300_BLG(0x20), 1);
}

/*
 * Backlight off/on as stock ddi.dll 0x01A55900 does, keeping what the
 * buzzer shares: BLG control 0980 to zero, then only the backlight's mode
 * nibble of 0984 and, unless a tone is sounding, gate 1128 bit 0 cleared
 * (glaze-os display.c). saved[] holds control, config and gate.
 */
static void be300_regs_backlight_off(u32 *saved, int buzzer)
{
	saved[0] = BE300_R32(BE300_BLG(0));
	saved[1] = BE300_R32(BE300_BLG(4));
	saved[2] = BE300_R32(BE300_CMM) & 1;
	BE300_W32(BE300_BLG(0), 0);
	if (buzzer) {
		BE300_W32(BE300_BLG(4), BE300_R32(BE300_BLG(4)) | 0x0202);
	} else {
		BE300_W32(BE300_BLG(4), BE300_R32(BE300_BLG(4)) & ~0xfU);
		BE300_W32(BE300_CMM, BE300_R32(BE300_CMM) & ~1U);
	}
}

static void be300_regs_backlight_on(const u32 *saved, int buzzer)
{
	BE300_W32(BE300_CMM, (BE300_R32(BE300_CMM) & ~1U) | saved[2] |
		  (buzzer ? 1 : 0));
	BE300_W32(BE300_BLG(4), (BE300_R32(BE300_BLG(4)) & ~0xfU) |
		  (saved[1] & 0xf));
	BE300_W32(BE300_BLG(0), saved[0]);
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

/* Hardware-verified Glaze/NEC scan mode: start AND stop requests, and
 * restart after acknowledging a page or an overrun (VRC4173 UM 9.7). */
static void be300_regs_piu_start(void)
{
	BE300_W32(0x0a0003c8, 3);
	BE300_W16(0x0a000308, 0x05dc);
	BE300_W16(0x0a00030c, 0x00c8);
	BE300_W16(0x0a000304, 0xdd00);
	BE300_W16(0x0a000300, 0x0306);
}

static void be300_regs_piu_ack(unsigned int status)
{
	unsigned int pending = (status & 0xff) & (status >> 8);

	if (!pending)
		return;
	if (pending & 0x04)
		pending |= 0x18; /* both full pages must clear after DATALOST */
	BE300_W16(0x0a000304, (status & 0xff00) | pending);
	BE300_W16(0x0a000300, 0x0306);
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

/*
 * Companion state Windows CE always leaves set and a power-on does not.
 * Measured on a real BE-300 booted from a battery pull (glaze-os
 * docs/NAND_BOOT_AUDIT.md, "Power-on findings"): only gate 111C is on at
 * entry, and an access to a gated unit stalls the bus for good. The
 * companion SIU stalled until 1108/112C/1138/113C were on, and USB
 * enumerated only with GPIO4 low and GPIO6 high as outputs and 1B2C set.
 * 1120 is followed by 1B24 = 0, 1B20 = 1 and 1104 by A0DC = FF, as the ROM
 * itself does. Which gate clocks which unit is not known yet.
 */
static void be300_regs_power_on(void)
{
	static const unsigned short gates[] = {
		0x1104, 0x1108, 0x1120, 0x112c, 0x1138, 0x113c
	};
	unsigned int n;

	for (n = 0; n < sizeof(gates) / sizeof(gates[0]); n++)
		BE300_W32(0x0a000000UL + gates[n], 1);
	BE300_W32(0x0a001b24, 0);
	BE300_W32(0x0a001b20, 1);
	BE300_W32(0x0a001b2c, 1);
	BE300_W32(0x0a00a0dc, 0xff);
	/* VR4131 GIU (UM ch. 15): GIUPIODL first, then GIUIOSELL. */
	BE300_W16(0x0f000144, (BE300_R16(0x0f000144) & ~0x10U) | 0x40);
	BE300_W16(0x0f000140, BE300_R16(0x0f000140) | 0x50);
	BE300_DELAY(10);
}

/* Whether the companion SIU can be touched without stalling the bus. */
static int be300_regs_siu_clocked(void)
{
	return (BE300_R32(0x0a001108) | BE300_R32(0x0a00112c) |
		BE300_R32(0x0a001138) | BE300_R32(0x0a00113c)) & 1;
}

/* Card-detect inputs, active low (A008 bits 1-2). 0A001000 reads 4 only
 * after Windows CE has set a card up: 0 with a card after a power-on. */
static int be300_regs_card_present(void)
{
	return (BE300_R32(0x0a00a008) & 6) == 0;
}

/* Millisecond waits as 1 ms steps: some kernels limit constant udelay(). */
static void be300_regs_delay_ms(unsigned int ms)
{
	while (ms--)
		BE300_DELAY(1000);
}

/*
 * Stock SPL 80F03248/80F03290: companion socket clock, bus timings and
 * GPIO5 (socket power) as a driven-high output. CE may gate the socket
 * while no card is present, so glaze-os (kernel/drivers/cf.c
 * socket_bus_init) restores this before every power-up; on a real BE-300
 * hot insertion only worked with it (glaze-os docs/hardware/PHYSICAL_NAND.md).
 * GIUPIODL first, then GIUIOSELL, so the pin never drives a stale level.
 */
static void be300_regs_socket_bus_init(void)
{
	BE300_W32(0x0a00111c, 1);
	BE300_W32(0x0a00a010, 0x1073);
	BE300_W32(0x0a00a014, 0x1061);
	BE300_W32(0x0a00a018, 0x10b1);
	BE300_W16(0x0f000144, BE300_R16(0x0f000144) | 0x20);
	BE300_W16(0x0f000140, BE300_R16(0x0f000140) | 0x20);
}

/*
 * Map the card's configuration registers (pcmcia.dll before atadisk.dll's
 * first command, 0x0198A468): A034 bit 2, A024 bits 2-3 clear, A020 bit 3.
 * Attribute address N is then the byte at PA 0x0A00D000 + N.
 */
static void be300_regs_card_config_window(void)
{
	BE300_W32(0x0a00a034, (BE300_R32(0x0a00a034) | 4) & ~0x30U);
	BE300_W32(0x0a00a024, BE300_R32(0x0a00a024) & ~0x0cU);
	BE300_W32(0x0a00a020, (BE300_R32(0x0a00a020) & ~4U) | 8);
}

/* An I/O card's COR: its CONFIG base, entry index plus level IRQs (0x40).
 * A real WL54-CF read back 0x41 at 0x200 and then associated. */
static void be300_regs_card_cor(unsigned int attr, unsigned int cor)
{
	be300_regs_card_config_window();
	BE300_W8(0x0a00d000UL + attr, cor);
	be300_regs_delay_ms(10);
}

/*
 * ATA: CCSR, COR, CCSR at attribute 0x202/0x200, read back because a card
 * still settling drops the write (glaze-os cf.c configure). COR 0x43 is
 * the secondary IDE ports (the taskfile at C170) with level interrupts,
 * CF spec 4.3.2. Zero, the unconfigured memory mode, disables ATA.
 */
static int be300_regs_ata_cor(unsigned int cor)
{
	unsigned int n;

	be300_regs_card_config_window();
	for (n = 0; n < 5; n++) {
		BE300_W8(0x0a00d202, 0xfd);
		BE300_W8(0x0a00d200, cor);
		BE300_W8(0x0a00d202, 0x01);
		be300_regs_delay_ms(10);
		if ((unsigned int)BE300_R8(0x0a00d200) == cor)
			return 0;
		be300_regs_delay_ms(100);
	}
	return -1;
}

/*
 * Stop and start the power MCU's watchdog as Windows CE does around sleep
 * (cedmbltin.dll CDM_PowerDown 0x019F1430 / StopWDT 0x019F1A6C, start loop
 * 0x019F1990; glaze-os kernel/drivers/cmcu.c). Without a stop a halted or
 * powered-off BE-300 resets about 150 s after the last reload.
 */
static int be300_regs_cmcu_stop(void)
{
	unsigned int n;

	for (n = 0; n < 1000; n++) {
		BE300_W32(0x0a007804, 0x35);
		BE300_W32(0x0a007800, 0x5c);
		if (!(BE300_R32(0x0a007834) & 7))
			return 0;
	}
	return -1;
}

static void __attribute__((unused)) be300_regs_cmcu_start(void)
{
	unsigned int n;

	BE300_W32(0x0a007814, 0x96);
	for (n = 0; n < 1000; n++) {
		BE300_W32(0x0a00780c, 0x53);
		BE300_W32(0x0a007808, 0x3a);
		if ((BE300_R32(0x0a007834) & 7) == 3)
			break;
	}
}

/*
 * Keep the elapsed-time alarm from waking a powered-off BE-300 out of
 * HIBERNATE: mainline rtc-vr41xx leaves ECMP at 0 when /dev/rtc closes,
 * and the emulator treats any ETIME >= ECMP as the alarm. Move ECMP out
 * of reach and clear a latched ELAPSEDTIME interrupt (RTCINTREG, W1C).
 * VR4131 UM ch. 13.
 */
static void be300_regs_rtc_alarm_off(void)
{
	BE300_W16(0x0f00010c, 0xffff);	/* high word first: no transient match */
	BE300_W16(0x0f00010a, 0xffff);
	BE300_W16(0x0f000108, 0xffff);
	BE300_W16(0x0f00013e, 1);
}

static void be300_regs_giu0(void)
{
	/* NK 800A5F60/6C/78/80: change only the pin owned by this cascade. */
	BE300_W16(0x0f000140, BE300_R16(0x0f000140) & ~1U);
	BE300_W16(0x0f000150, BE300_R16(0x0f000150) & ~1U);
	BE300_W16(0x0f000154, BE300_R16(0x0f000154) | 1);
	BE300_W16(0x0f000158, BE300_R16(0x0f000158) | 1);
	/*
	 * Only GIU line 0 is the board's. After a RAM boot from Windows CE
	 * other lines stay enabled (its serial driver's), and one firing held
	 * SYSINT1's GIU bit with nothing to clear it: an interrupt storm on a
	 * real BE-300 (glaze-os kernel/drivers/irq.c). Disable them and clear
	 * what is pending; the cascade enables line 0 afterwards.
	 */
	BE300_W16(0x0f00014c, 0);
	BE300_W16(0x0f00014e, 0);
	BE300_W16(0x0f000148, 0xffff);
	BE300_W16(0x0f00014a, 0xffff);
}
#endif
