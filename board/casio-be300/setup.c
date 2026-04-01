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

#include <asm/io.h>
#include <asm/idle.h>

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

static void casio_be300_wait(void)
{
	local_irq_enable();
}

static int __init casio_be300_setup(void)
{
	set_io_port_base(BE300_IO_PORT_BASE);
	ioport_resource.start = BE300_ISA_IO_START;
	ioport_resource.end = BE300_ISA_IO_END;

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
