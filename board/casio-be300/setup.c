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
#include <linux/be300_hardware.h>
#include <linux/be300_card.h>
#include <linux/ioport.h>
#include <linux/platform_device.h>
#include <linux/serial_8250.h>
#include <linux/workqueue.h>
#include <linux/delay.h>
#include <linux/err.h>

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
			be300_girq0_source_mask(1);
		if (cause)
			iounmap(cause);
		if (ack)
			iounmap(ack);
	}

	return 0;
}

arch_initcall(casio_be300_setup);

/*
 * Idle is the VR41xx PMU driver's vr41xx_cpu_wait(): STANDBY, which sets
 * Status.IE as it executes (VR4131 UM ch. 12). The emulator models that
 * since be300 commit 972f89a0, and glaze-os idles the same way, so the
 * former busy "enable and return" override is gone.
 */

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
 * CompactFlash via pata_be300 (board/casio-be300/pata_be300.c): taskfile
 * at PA 0x0A00C170-7, alternate status at 0x0A00C376, register N at
 * cmd_addr + N, data moved a byte at a time in the card's 8-bit mode as on
 * real hardware (glaze-os cf.c). Interrupt routes through GIRQ0 bit 0 ->
 * GIU line 0 -> VRIP 8, demuxed by board/casio-be300/irq.c into
 * VRC4173_IRQ(0). Probe will fail cleanly when the emulator is invoked
 * without --cf (or with --ne2000, which steals the same window).
 */
#ifdef CONFIG_ATA_SFF
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
 * A CF serial card (FUNCID 2: the RC56LD modem, the Brainboxes BL-565
 * Bluetooth card) as ttyS1: a 16550 at I/O 0x3F8 in the card window, once
 * hardware.c has written the COR of the CIS entry that decodes 3F8h.
 * Polled (irq 0) like ttyS0, since VRC4173_IRQ(0) belongs to the NE2000.
 * glaze-os btuart.c drives the BL-565 the same way.
 */
static struct plat_serial8250_port be300_card_uart_ports[] = {
	{
		.mapbase	= 0x0a00c3f8,
		.membase	= (void __iomem *)KSEG1ADDR(0x0a00c3f8),
		.irq		= 0,
		.uartclk	= 1843200,
		.regshift	= 0,
		.iotype		= UPIO_MEM,
		.flags		= UPF_BOOT_AUTOCONF | UPF_SKIP_TEST,
	},
	{ .flags = 0 },
};


/*
 * CF and NE2000 share VRC4173_IRQ(0); the emulator makes them mutually
 * exclusive (--cf vs --ne2000), and socket 0's CIS picks which one is
 * registered. Only NE2000 carries IORESOURCE_IRQ — pata_be300's resource
 * list intentionally omits the IRQ so ata_host_activate goes through
 * the polled-mode path (irq=0) and doesn't call request_irq(). That
 * leaves IRQ 72 free for ne_probe1's exclusive request_irq() call.
 *
 * Trade-off: in --cf mode CF transfers are polled rather than
 * interrupt-driven. libata handles this fine (libata's
 * ata_polling_mode kicks in when host->irq == 0).
 */

/*
 * Socket 0's card device, created for the card in the socket and removed
 * with it. Only an NE2000-compatible card gets ne.c's register probe, only
 * storage (FUNCID 4) gets ATA, whose polled waits on a modem or NIC card
 * would only time out, and a serial card (FUNCID 2) gets ttyS1. Wi-Fi
 * cards are wifi.c's.
 */
static struct platform_device *be300_card_dev;

static void be300_card_attach(void)
{
	struct platform_device *dev = NULL;
	int function = be300_card_function();

	if (be300_wired_card())
		dev = platform_device_register_simple("ne", -1,
			be300_ne2000_resources, ARRAY_SIZE(be300_ne2000_resources));
#ifdef CONFIG_ATA_SFF
	else if (function == 4)
		dev = platform_device_register_simple("pata_be300", -1,
			be300_cf_resources, ARRAY_SIZE(be300_cf_resources));
#endif
	else if (function == 2)
		dev = platform_device_register_data(NULL, "serial8250",
			PLAT8250_DEV_PLATFORM1, be300_card_uart_ports,
			sizeof(be300_card_uart_ports));
	be300_card_dev = IS_ERR(dev) ? NULL : dev;
}

static void be300_card_detach(void)
{
	if (be300_card_dev)
		platform_device_unregister(be300_card_dev);
	be300_card_dev = NULL;
}

/*
 * Hot plug, polled as glaze-os pcmcia_poll() does (card-detect inputs at
 * A008). An inserted card is powered with the socket baseline and given
 * its COR; its CIS can take a moment to answer after reset (a real
 * WL54-CF did), so it is read for up to a second. glaze-os cf.c insert().
 */
static bool be300_card_present_now;
static void be300_card_poll(struct work_struct *work);
static DECLARE_DELAYED_WORK(be300_card_work, be300_card_poll);

static void be300_card_poll(struct work_struct *work)
{
	bool present = !(readl((void __iomem *)KSEG1ADDR(0x0a00a008)) & 6);
	int n;

	if (present != be300_card_present_now) {
		be300_card_present_now = present;
		be300_card_detach();
		if (present) {
			be300_socket_power_up();
			for (n = 0; n < 100; n++) {
				u8 first = readb((void __iomem *)KSEG1ADDR(0x0a00d000));

				if (first != 0x00 && first != 0xff)
					break;
				msleep(10);
			}
			be300_card_configure();
			printk(KERN_INFO "BE-300: card inserted (FUNCID %d)\n",
			       be300_card_function());
			be300_card_attach();
		} else {
			printk(KERN_INFO "BE-300: card removed\n");
		}
	}
	schedule_delayed_work(&be300_card_work, msecs_to_jiffies(500));
}

static int __init casio_be300_register_devices(void)
{
	int ret;

	ret = platform_device_register(&be300_serial8250_device);
	if (ret)
		return ret;
	be300_card_present_now = !(readl((void __iomem *)KSEG1ADDR(0x0a00a008)) & 6);
	if (be300_card_present_now)
		be300_card_attach();	/* hardware.c configured it at boot */
	schedule_delayed_work(&be300_card_work, msecs_to_jiffies(500));
	return 0;
}
device_initcall(casio_be300_register_devices);
