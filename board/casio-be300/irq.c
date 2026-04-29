/*
 * arch/mips/vr41xx/casio-be300/irq.c
 *
 * Second-level interrupt demuxer for the BE-300.
 *
 * The VR4131 ICU (handled by mainline arch/mips/vr41xx/common/icu.c) reports
 * the GIU summary as SYSINT1 bit 8, which Linux exposes as GIU_IRQ(0..31)
 * (40..71). On the BE-300 every VRC4173 sub-source — touch, buttons, CF /
 * NE2000, PC Connect — rides on a single GPIO pin (GIU line 0). The actual
 * cascade source is the VRC4173 GIRQ0 status register at PA 0x0A000004.
 *
 *   SYSINT1.bit8 (GIU)
 *      └── GIU0  (GIU_IRQ(0) = 40)
 *             └── VRC4173 GIRQ0 word @ 0x0A000004:
 *                    bit 0 → CF / NE2000   (VRC4173_IRQ(0) = 72)
 *                    bit 1 → buttons       (VRC4173_IRQ(1) = 73)
 *                    bit 4 → CommMode      (VRC4173_IRQ(4) = 76, unused)
 *                    bit 9 → touch (PIU)   (VRC4173_IRQ(9) = 81)
 *
 * VRC4173_IRQ_BASE (72) is the existing mainline numbering convention — no
 * other 4.2.9 driver uses it, but reusing the namespace keeps the IRQ
 * numbering future-compatible with the upstream vrc4173_cardu PCMCIA driver
 * if we ever switch to that.
 *
 * GIRQ0 status / mask / ack are all write-1-to-clear in the emulator. There
 * is no separate hardware mask register at this layer; we keep a software
 * shadow mask and AND it with the live status during demux.
 *
 * Copyright (C) 2026 John Roark
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/irq.h>
#include <linux/irqchip/chained_irq.h>

#include <asm/vr41xx/irq.h>

#define BE300_GIRQ0_STATUS_PA	0x0a000004
#define BE300_GIRQ0_ACK_PA	0x0a000014
#define BE300_GIRQ0_CAUSE_PA	0x0a00a03c

#define BE300_GIUINTENL_PA	0x0f00014c

#define BE300_GIRQ0_NR_SOURCES	16

static void __iomem *be300_girq0_status_io;
static void __iomem *be300_girq0_ack_io;
static void __iomem *be300_girq0_cause_io;
static u32 be300_girq0_mask;

static void be300_girq0_irq_mask(struct irq_data *d)
{
	be300_girq0_mask &= ~(1u << (d->irq - VRC4173_IRQ_BASE));
}

static void be300_girq0_irq_unmask(struct irq_data *d)
{
	be300_girq0_mask |= 1u << (d->irq - VRC4173_IRQ_BASE);
}

static void be300_girq0_irq_ack(struct irq_data *d)
{
	writel(1u << (d->irq - VRC4173_IRQ_BASE), be300_girq0_ack_io);
}

static struct irq_chip be300_girq0_chip = {
	.name		= "BE300-GIRQ0",
	.irq_mask	= be300_girq0_irq_mask,
	.irq_unmask	= be300_girq0_irq_unmask,
	.irq_ack	= be300_girq0_irq_ack,
};

static void be300_girq0_demux(unsigned int irq, struct irq_desc *desc)
{
	struct irq_chip *chip = irq_desc_get_chip(desc);
	u32 pending;

	chained_irq_enter(chip, desc);

	pending = readl(be300_girq0_status_io);

	/*
	 * Bit 0 = CF / NE2000. The emulator keeps it asserted while
	 * cf_giu_source_bits() reports state_change_pending OR irq_pending
	 * OR an unmasked NE2000 ISR bit. state_change_pending is cleared
	 * only by a READ of the CF cause register at 0x0A00A03C — writes to
	 * the GIRQ0 ack register do nothing for that source.
	 */
	if (pending & 0x1)
		readl(be300_girq0_cause_io);

	/*
	 * W1C every observed pending bit. For bit 0 this routes through
	 * cf_clear_irq() in the emulator, dropping irq_pending. For other
	 * bits it just clears the GIRQ0 latch.
	 */
	writel(pending, be300_girq0_ack_io);

	pending &= be300_girq0_mask;
	while (pending) {
		int bit = __ffs(pending);
		generic_handle_irq(VRC4173_IRQ_BASE + bit);
		pending &= ~(1u << bit);
	}

	chained_irq_exit(chip, desc);
}

/*
 * arch_initcall: install the VRC4173 sub-IRQ chip and ioremap our MMIO
 * windows BEFORE device_initcall. Two reasons:
 *
 *  1) ne_drv_probe / pata_platform_probe call request_irq(VRC4173_IRQ(0))
 *     during device_initcall. __setup_irq returns -ENOSYS if the chip is
 *     still no_irq_chip, so without this the drivers print
 *     "unable to get IRQ 72 (errno=-89)" and bail.
 *
 *  2) be300_girq0_irq_ack writes to be300_girq0_ack_io. The ack path is
 *     only reached once the chained handler dispatches into
 *     handle_level_irq (late_initcall onward), so doing the ioremap here
 *     is safe.
 */
static int __init be300_irq_chip_init(void)
{
	int i;

	be300_girq0_status_io = ioremap(BE300_GIRQ0_STATUS_PA, 4);
	be300_girq0_ack_io = ioremap(BE300_GIRQ0_ACK_PA, 4);
	be300_girq0_cause_io = ioremap(BE300_GIRQ0_CAUSE_PA, 4);
	if (!be300_girq0_status_io || !be300_girq0_ack_io ||
	    !be300_girq0_cause_io)
		return -ENOMEM;

	for (i = 0; i < BE300_GIRQ0_NR_SOURCES; i++)
		irq_set_chip_and_handler(VRC4173_IRQ_BASE + i,
					 &be300_girq0_chip, handle_level_irq);

	return 0;
}
arch_initcall(be300_irq_chip_init);

/*
 * late_initcall: must run AFTER vr41xx_giu_add (device_initcall) and the
 * platform-bound giu_probe so that GIU_IRQ(0)'s irq_chip is set to the
 * GIU's chip rather than the no_irq_chip default. arch_initcall is too
 * early — it triggers a "irq_data->chip == &no_irq_chip" warning in
 * irq_set_chained_handler.
 */
static int __init be300_irq_cascade_init(void)
{
	irq_set_chained_handler(GIU_IRQ(0), be300_girq0_demux);

	/*
	 * irq_set_chained_handler is supposed to call irq_startup ->
	 * startup_giuint -> unmask_giuint_low and enable GIUINTENL bit 0,
	 * but the 4.2.9 / VR41xx-cascade flow on this board leaves it at 0,
	 * so giu_get_irq sees `pendl & maskl == 0` and prints
	 * "spurious GIU interrupt" instead of dispatching GIU pin 0 to our
	 * demux. Force GIUINTENL bit 0 = 1 directly so the cascade can
	 * dispatch.
	 */
	{
		void __iomem *inten = ioremap(BE300_GIUINTENL_PA, 4);
		if (inten) {
			writew(readw(inten) | 0x1, inten);
			iounmap(inten);
		}
	}
	return 0;
}
late_initcall(be300_irq_cascade_init);
