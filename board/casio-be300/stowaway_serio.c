/*
 * arch/mips/vr41xx/casio-be300/stowaway_serio.c
 *
 * Polled serio port driver for the BE-300 emulator's --stowaway-keyboard
 * Targus Stowaway keyboard emulation. Bridges the VRC4173 SIU at PA
 * 0x0A008680 (16550-compatible, 4-byte register stride) to the serio bus,
 * so the in-tree drivers/input/keyboard/stowaway.c serio_driver can decode
 * keystrokes into input events.
 *
 * Wire protocol (see be300-framebuffer src/stowaway.c):
 *   1. LCR write with bit 7 (DLAB) set      -> emulator resets state.
 *   2. IER write with bit 3 (MSI enable)    -> emulator marks modem-wait.
 *   3. MCR DTR=1 asserted                   -> emulator's poll loop bumps
 *                                              modem_events_delivered.
 *   4. MCR RTS rising edge while DTR=1 and
 *      modem_events_delivered > 0           -> emulator queues 0xFA, 0xFD.
 *   5. Driver consumes both bytes in order  -> emulator sets connected=true.
 *   6. Keystrokes arrive as 8-bit scancodes; bit 7 = release.
 *
 * Polling cadence is 20 ms; the in-tree stowaway driver's serio_interrupt
 * handles each scancode byte. This module owns no IRQs to keep it isolated
 * from the VRC4173 IRQ cascade in board/casio-be300/irq.c.
 *
 * The same UART is used by prom_putchar in setup.c, but only for TX writes
 * to THR. With --stowaway-keyboard the emulator's stowaway shim hijacks
 * both directions of this port, so early-printk output is silently consumed
 * while the keyboard is enabled. That is a deliberate trade-off; users who
 * need serial debug should run without --stowaway-keyboard.
 *
 * Copyright (C) 2026 John Roark
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */
#include <linux/init.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/serio.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#define BE300_STOW_BASE		0x0a008680
#define BE300_STOW_LEN		0x20	/* 8 regs * 4-byte stride */

/* 16550 register offsets, scaled for 4-byte register stride. */
#define STOW_OFS_RBR		0x00
#define STOW_OFS_THR		0x00
#define STOW_OFS_IER		0x04
#define STOW_OFS_LCR		0x0c
#define STOW_OFS_MCR		0x10
#define STOW_OFS_LSR		0x14
#define STOW_OFS_MSR		0x18

#define STOW_LCR_8N1		0x03
#define STOW_LCR_DLAB		0x80
#define STOW_IER_MSI		0x08
#define STOW_MCR_DTR		0x01
#define STOW_MCR_RTS		0x02
#define STOW_LSR_DR		0x01

#define STOW_PROBE_ACK_0	0xfa
#define STOW_PROBE_ACK_1	0xfd

#define STOW_POLL_MS		20
#define STOW_PROBE_GIVEUP	100	/* ticks ~ 2 s before giving up */

enum stow_state {
	STOW_INIT,
	STOW_RTS_LOW,
	STOW_RTS_HIGH,
	STOW_AWAIT_ACK0,
	STOW_AWAIT_ACK1,
	STOW_CONNECTED,
	STOW_GIVE_UP,
};

static void __iomem *stow_io;
static struct serio *stow_serio;
static struct delayed_work stow_work;
static enum stow_state stow_state;
static unsigned int stow_ticks;

static u8 stow_readb(unsigned int ofs)
{
	return readb(stow_io + ofs);
}

static void stow_writeb(unsigned int ofs, u8 val)
{
	writeb(val, stow_io + ofs);
}

static void stow_drain_rx(void)
{
	while (stow_readb(STOW_OFS_LSR) & STOW_LSR_DR)
		(void)stow_readb(STOW_OFS_RBR);
}

static void stow_reset_port(void)
{
	/*
	 * DLAB=1 LCR write triggers stowaway_uart_note_port_config in the
	 * emulator (clears connected, modem_events_delivered, RX queue).
	 */
	stow_writeb(STOW_OFS_LCR, STOW_LCR_8N1 | STOW_LCR_DLAB);
	stow_writeb(STOW_OFS_LCR, STOW_LCR_8N1);
	stow_writeb(STOW_OFS_IER, STOW_IER_MSI);
	stow_writeb(STOW_OFS_MCR, STOW_MCR_DTR);
	stow_drain_rx();
}

static void stow_step(struct work_struct *w)
{
	u8 byte;
	bool requeue = true;

	switch (stow_state) {
	case STOW_INIT:
		stow_reset_port();
		stow_state = STOW_RTS_LOW;
		stow_ticks = 0;
		break;

	case STOW_RTS_LOW:
		stow_writeb(STOW_OFS_MCR, STOW_MCR_DTR);
		stow_state = STOW_RTS_HIGH;
		break;

	case STOW_RTS_HIGH:
		stow_writeb(STOW_OFS_MCR, STOW_MCR_DTR | STOW_MCR_RTS);
		stow_state = STOW_AWAIT_ACK0;
		break;

	case STOW_AWAIT_ACK0:
		if (stow_readb(STOW_OFS_LSR) & STOW_LSR_DR) {
			byte = stow_readb(STOW_OFS_RBR);
			if (byte == STOW_PROBE_ACK_0) {
				stow_state = STOW_AWAIT_ACK1;
			} else {
				/* Out-of-sequence byte: try toggling again. */
				stow_state = STOW_RTS_LOW;
			}
			break;
		}
		if (++stow_ticks >= STOW_PROBE_GIVEUP) {
			pr_info("BE-300 Stowaway: no keyboard detected (run emulator with --stowaway-keyboard to enable)\n");
			stow_state = STOW_GIVE_UP;
			requeue = false;
			break;
		}
		/* Re-toggle RTS until modem_events_delivered catches up. */
		stow_state = STOW_RTS_LOW;
		break;

	case STOW_AWAIT_ACK1:
		if (stow_readb(STOW_OFS_LSR) & STOW_LSR_DR) {
			byte = stow_readb(STOW_OFS_RBR);
			if (byte == STOW_PROBE_ACK_1) {
				pr_info("BE-300 Stowaway: keyboard connected\n");
				stow_state = STOW_CONNECTED;
				stow_ticks = 0;
			} else {
				stow_state = STOW_RTS_LOW;
			}
			break;
		}
		if (++stow_ticks >= STOW_PROBE_GIVEUP) {
			stow_state = STOW_RTS_LOW;
			stow_ticks = 0;
		}
		break;

	case STOW_CONNECTED:
		while (stow_readb(STOW_OFS_LSR) & STOW_LSR_DR) {
			byte = stow_readb(STOW_OFS_RBR);
			serio_interrupt(stow_serio, byte, 0);
		}
		break;

	case STOW_GIVE_UP:
		requeue = false;
		break;
	}

	if (requeue)
		schedule_delayed_work(&stow_work,
				      msecs_to_jiffies(STOW_POLL_MS));
}

static int __init be300_stowaway_init(void)
{
	struct serio *s;

	stow_io = ioremap(BE300_STOW_BASE, BE300_STOW_LEN);
	if (!stow_io) {
		pr_err("BE-300 Stowaway: ioremap %#x failed\n",
		       BE300_STOW_BASE);
		return -ENOMEM;
	}

	s = kzalloc(sizeof(*s), GFP_KERNEL);
	if (!s) {
		iounmap(stow_io);
		stow_io = NULL;
		return -ENOMEM;
	}

	s->id.type  = SERIO_RS232;
	s->id.proto = SERIO_STOWAWAY;
	s->id.id    = SERIO_ANY;
	s->id.extra = SERIO_ANY;
	strlcpy(s->name, "BE-300 Stowaway port", sizeof(s->name));
	strlcpy(s->phys, "vrc4173/siu0", sizeof(s->phys));

	stow_serio = s;
	stow_state = STOW_INIT;
	stow_ticks = 0;

	serio_register_port(s);

	INIT_DELAYED_WORK(&stow_work, stow_step);
	schedule_delayed_work(&stow_work, msecs_to_jiffies(STOW_POLL_MS));

	pr_info("BE-300 Stowaway: probing SIU at %#x for keyboard\n",
		BE300_STOW_BASE);
	return 0;
}
late_initcall(be300_stowaway_init);
