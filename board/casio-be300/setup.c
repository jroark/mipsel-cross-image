/*
 * arch/mips/vr41xx/casio-be300/setup.c
 *
 * Setup for the Casio Cassiopeia BE-300.
 *
 * The BE-300 uses a NEC VR4131 CPU with a VRC4173 companion chip.
 * Peripherals (serial, touchscreen, CF) are on the companion chip
 * at 0xAA000000+, NOT on the VR4131's built-in controllers.
 *
 * Hardware references:
 *   - NEC VR4131 User's Manual (uPD30131)
 *   - NEC VRC4173 User's Manual (uPD31173)
 *   - linux4.be project source overlays and hardware notes
 *
 * Copyright (C) 2002 Paul Mundt <lethal@chaoticdreams.org>
 * Copyright (C) 2004 Linux4.BE
 * Copyright (C) 2026 John Roark
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */
#include <linux/init.h>
#include <linux/ioport.h>
#include <linux/platform_device.h>
#include <linux/serial_8250.h>
#ifdef CONFIG_ATA
#include <linux/ata_platform.h>
#endif

#include <asm/io.h>
#include <asm/idle.h>
#include <asm/vr41xx/irq.h>

/*
 * The companion chip I/O region starts at physical 0x0A00C000.
 * KSEG1ADDR maps it to the uncached virtual address 0xAA00C000.
 */
#define BE300_ISA_IO_BASE	0x0a00c000
#define BE300_ISA_IO_SIZE	0x05ff4000
#define BE300_ISA_IO_START	0
#define BE300_ISA_IO_END	(BE300_ISA_IO_SIZE - 1)
#define BE300_IO_PORT_BASE	KSEG1ADDR(BE300_ISA_IO_BASE)

/*
 * Companion chip UART at physical 0x0A008680 (virtual 0xAA008680).
 * Register spacing is 4 bytes. This is a NEC D89041F1001, not an 8250.
 * Used only for early printk output via prom_putchar().
 */
#define BE300_UART_BASE		0x0a008680
#define BE300_UART_OFS_THR	0x00
#define BE300_UART_OFS_LSR	0x14
#define BE300_UART_LSR_THRE	0x20

#define BE300_PCMCIA_BRIDGE_PA	0x0a00a01c
#define BE300_PCMCIA_BRIDGE_EN	0x04

static void casio_be300_wait(void)
{
	local_irq_enable();
}

static int __init casio_be300_setup(void)
{
	set_io_port_base(BE300_IO_PORT_BASE);
	ioport_resource.start = BE300_ISA_IO_START;
	ioport_resource.end = BE300_ISA_IO_END;

	/*
	 * Enable the VRC4173 PCMCIA bridge windows. NAND uses the XFER engine
	 * at PA 0x0A00A4xx / 0x0A00B000, so the bridge may own the C000/D000
	 * card windows needed by CF and NE2000 without stealing NAND I/O.
	 */
	{
		void __iomem *bridge = ioremap(BE300_PCMCIA_BRIDGE_PA, 4);
		if (bridge) {
			writel(readl(bridge) | BE300_PCMCIA_BRIDGE_EN, bridge);
			iounmap(bridge);
		}
	}

	/*
	 * Drain the VRC4173 GIRQ0 cascade source before IRQs come up.
	 * cf_attach (--cf or --ne2000) sets state_change_pending and
	 * irq_pending in the emulator, which would drive GIU pin 0 high
	 * the moment local_irq_enable runs. Reading 0x0A00A03C clears
	 * state_change_pending; writing to 0x0A000014 W1Cs the latch
	 * and routes through cf_clear_irq() to drop irq_pending.
	 */
	{
		void __iomem *cause = ioremap(0x0a00a03c, 4);
		void __iomem *ack = ioremap(0x0a000014, 4);
		if (cause)
			(void)readl(cause);
		if (ack)
			writel(0xffffffffu, ack);
		if (cause)
			iounmap(cause);
		if (ack)
			iounmap(ack);
	}

	return 0;
}

arch_initcall(casio_be300_setup);

/*
 * The VR41xx PMU driver (subsys_initcall) sets cpu_wait to
 * vr41xx_cpu_wait() which uses the VR41xx "standby" instruction.
 * The BE-300 emulator doesn't wake from standby on interrupt,
 * so override with a simple enable-and-return idle function.
 * Must run after the PMU's subsys_initcall.
 */
static int __init casio_be300_idle_setup(void)
{
	cpu_wait = casio_be300_wait;
	return 0;
}

device_initcall(casio_be300_idle_setup);

/*
 * Early console output via the companion chip UART.
 * Called by the MIPS early_printk infrastructure when CONFIG_EARLY_PRINTK
 * is enabled and "earlyprintk" is on the kernel command line.
 */
void prom_putchar(char c)
{
	volatile u8 *uart = (volatile u8 *)KSEG1ADDR(BE300_UART_BASE);
	int timeout = 10000;

	while ((uart[BE300_UART_OFS_LSR] & BE300_UART_LSR_THRE) == 0)
		if (--timeout == 0)
			return; /* bail if no serial cable connected */
	uart[BE300_UART_OFS_THR] = c;
}

/*
 * CompactFlash via pata_platform. The emulator exposes the CF taskfile
 * registers at PA 0x0A00C170-7 with alternate-status at 0x0A00C376. The
 * companion chip is hardwired so the data port is 8-bit and there is no
 * register-shift; pata_platform's ioport_shift = 0 leaves the layout as
 * cmd_addr + N for register N. Interrupt routes through GIRQ0 bit 0 ->
 * GIU line 0 -> VRIP 8, demuxed by board/casio-be300/irq.c into
 * VRC4173_IRQ(0). Probe will fail cleanly when the emulator is invoked
 * without --cf (or with --ne2000, which steals the same window).
 */
#ifdef CONFIG_ATA
#define BE300_CF_CMD_PA		0x0a00c170
#define BE300_CF_CMD_LEN	8
#define BE300_CF_CTL_PA		0x0a00c376
#define BE300_CF_CTL_LEN	2

/*
 * No IORESOURCE_IRQ here on purpose — see casio_be300_register_devices
 * comment. CF runs in polled mode so NE2000 can own VRC4173_IRQ(0).
 */
static struct resource be300_cf_resources[] = {
	{
		.start	= BE300_CF_CMD_PA,
		.end	= BE300_CF_CMD_PA + BE300_CF_CMD_LEN - 1,
		.flags	= IORESOURCE_MEM,
	},
	{
		.start	= BE300_CF_CTL_PA,
		.end	= BE300_CF_CTL_PA + BE300_CF_CTL_LEN - 1,
		.flags	= IORESOURCE_MEM,
	},
};

static struct pata_platform_info be300_cf_pdata = {
	.ioport_shift	= 0,
};

static struct platform_device be300_cf_device = {
	.name		= "pata_platform",
	.id		= -1,
	.num_resources	= ARRAY_SIZE(be300_cf_resources),
	.resource	= be300_cf_resources,
	.dev = {
		.platform_data = &be300_cf_pdata,
	},
};
#endif

/*
 * NE2000 (NS8390) shares the VRC4173 PCMCIA window with CF; the emulator
 * makes them mutually exclusive. The register file lands at port 0x300
 * (MMIO 0xAA00C300) — the emulator routes 0xAA00C300..0xAA00C31F through
 * ne2000_window_read/write(offset & 0x1F). We deliberately use port 0x300
 * (and not 0x000) because do_ne_probe in drivers/net/ethernet/8390/ne.c
 * rejects any base <= 0x1ff with -ENXIO and falls into a legacy ISA
 * autoprobe at 0x300/0x280/0x320/0x340. With base > 0x1ff it takes the
 * single-location fast path straight into ne_probe1.
 */
#define BE300_NE2000_IO_BASE	0x300
#define BE300_NE2000_IO_LEN	0x20

static struct resource be300_ne2000_resources[] = {
	{
		.start	= BE300_NE2000_IO_BASE,
		.end	= BE300_NE2000_IO_BASE + BE300_NE2000_IO_LEN - 1,
		.flags	= IORESOURCE_IO,
	},
	{
		.start	= VRC4173_IRQ(0),
		.end	= VRC4173_IRQ(0),
		.flags	= IORESOURCE_IRQ,
	},
};

static struct platform_device be300_ne2000_device = {
	.name		= "ne",
	.id		= -1,
	.num_resources	= ARRAY_SIZE(be300_ne2000_resources),
	.resource	= be300_ne2000_resources,
};

/*
 * VRC4173 companion dock UART at PA 0x0A008680 exposed as ttyS0 via the
 * generic 8250 driver. The emulator models it as an ns16550 with
 * addr_mult=4, so the register stride is 4 bytes -> regshift = 2.
 *
 * irq = 0: run polled, exactly like the 2.4 serial_be300 driver and like
 * CF on this board. The VRC4173 SIU IRQ multiplexes onto GIU pin 0, which
 * CF/NE2000 already own (see casio_be300_register_devices below); polled
 * mode keeps this UART off that contended cascade. uartclk is nominal —
 * the emulated ns16550 does not rate-limit on the divisor.
 * UPF_FIXED_TYPE|UPF_SKIP_TEST skips the loopback autoconfig probe that
 * an emulated UART can fail.
 *
 * This UART is also written by prom_putchar() (earlyprintk, TX-only,
 * stops once a real console is up) and, when CONFIG_KEYBOARD_STOWAWAY is
 * active, polled by stowaway_serio.c. stowaway_serio uses bare ioremap()
 * with no request_mem_region(), so there is no resource conflict; the
 * only real conflict is passing --serial1-bridge together with
 * --stowaway-keyboard, which is already an unsupported combination (see
 * the stowaway_serio.c header). This is NOT a kernel console
 * (console=tty0); inittab runs an askfirst shell on ttyS0.
 */
static struct plat_serial8250_port be300_serial8250_ports[] = {
	{
		.mapbase	= 0x0a008680,
		.membase	= (void __iomem *)KSEG1ADDR(0x0a008680),
		.irq		= 0,
		.uartclk	= 1843200,
		.regshift	= 2,
		.iotype		= UPIO_MEM,
		.flags		= UPF_BOOT_AUTOCONF | UPF_SKIP_TEST |
				  UPF_FIXED_TYPE,
		.type		= PORT_16550A,
	},
	{ .flags = 0 },
};

static struct platform_device be300_serial8250_device = {
	.name	= "serial8250",
	.id	= PLAT8250_DEV_PLATFORM,
	.dev	= {
		.platform_data = be300_serial8250_ports,
	},
};

/*
 * CF and NE2000 share VRC4173_IRQ(0); the emulator makes them mutually
 * exclusive (--cf vs --ne2000). Register both pdevs unconditionally,
 * but only NE2000 carries IORESOURCE_IRQ — pata_platform's resource
 * list intentionally omits the IRQ so ata_host_activate goes through
 * the polled-mode path (irq=0) and doesn't call request_irq(). That
 * leaves IRQ 72 free for ne_probe1's exclusive request_irq() call.
 *
 * Trade-off: in --cf mode CF transfers are polled rather than
 * interrupt-driven. pata_platform handles this fine (libata's
 * ata_polling_mode kicks in when host->irq == 0).
 */
static struct platform_device *be300_devices[] __initdata = {
	&be300_ne2000_device,
	&be300_serial8250_device,
#ifdef CONFIG_ATA
	&be300_cf_device,
#endif
};

static int __init casio_be300_register_devices(void)
{
	return platform_add_devices(be300_devices, ARRAY_SIZE(be300_devices));
}
device_initcall(casio_be300_register_devices);
