/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * BE-300 USB function controller as a serial line, /dev/ttyBEU0 (Linux 4.2).
 *
 * The BE-300 is a USB 1.1 device (VID 07CF, PID 2002, vendor class): the
 * companion's controller at 0x0A001300-0x0A00161F answers enumeration from
 * a descriptor table in its own RAM, so Linux only moves bulk data:
 * EP2 OUT to the tty, the tty to EP1 IN. Polled every tick with the GIRQ0
 * source (7) masked, as glaze-os kernel/drivers/usb.c does on hardware
 * (enumeration, its debugger and USB networking work there); register
 * evidence in be300 docs/BE300_USB_FUNCTION.md (usb.dll). RX uses PIO, TX
 * DMA from an uncached page of our own.
 *
 * Host side: a generic USB serial driver, e.g. Linux
 * `modprobe usbserial vendor=0x07cf product=0x2002`; data flows once the
 * host sets DTR (CDC SET_CONTROL_LINE_STATE, which the device accepts).
 * Run a getty on ttyBEU0 for a USB shell, or pppd for networking.
 */
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/timer.h>
#include <linux/spinlock.h>
#include <linux/kfifo.h>
#include <linux/gfp.h>
#include <linux/delay.h>
#include <linux/tty.h>
#include <linux/tty_driver.h>
#include <linux/tty_flip.h>
#include <linux/io.h>

#define R(off)		readl((void __iomem *)KSEG1ADDR(0x0a000000 + (off)))
#define W(off, v)	writel((v), (void __iomem *)KSEG1ADDR(0x0a000000 + (off)))
#define TX_FIFO		4096

static struct tty_driver *usb_tty;
static struct tty_port usb_port;
static struct timer_list usb_timer;
static DEFINE_SPINLOCK(usb_lock);
static DEFINE_KFIFO(tx_fifo, unsigned char, TX_FIFO);
static u8 *dma;			/* KSEG1 alias of the TX page */
static unsigned long dma_phys;
static unsigned int dma_len;
static bool configured, tx_busy, short_pending, zlp, status_pending;
static u8 lines, pending_lines;

/* usb.dll / glaze-os hw_init: clock 1114, enable and reset, descriptors,
 * endpoint and interrupt setup. */
static void usb_hw_init(void)
{
	static const u8 descriptors[] = {
		18, 1, 0, 1, 255, 255, 255, 16, 0xcf, 7, 2, 0x20, 0, 1, 0, 0, 0, 1,
		9, 2, 39, 0, 1, 1, 0, 0x40, 1,
		9, 4, 0, 0, 3, 255, 255, 255, 0,
		7, 5, 0x81, 2, 64, 0, 0, 7, 5, 2, 2, 64, 0, 0, 7, 5, 0x83, 3, 8, 0, 1
	};
	unsigned int i;

	W(0x002c, R(0x002c) & ~8U);	/* GIRQ0 source 7 stays masked */
	W(0x1114, 1);
	mdelay(10);
	W(0x1300, 1); W(0x130c, 0x10); W(0x132c, 0); W(0x1488, 0);
	W(0x1300, 1); W(0x1308, 0);
	W(0x1338, 1); W(0x1338, 0); W(0x1444, 1);
	W(0x1494, 1); W(0x1494, ~1U);
	for (i = 0; i < sizeof(descriptors); i++)
		W(0x153c + i * 4, descriptors[i]);
	W(0x1500, 1); W(0x1510, 0); W(0x1518, 0); W(0x1520, 0); W(0x1528, 0);
	W(0x148c, 0x3f); W(0x1470, 0x7d); W(0x1474, 0x38); W(0x1478, 9);
	W(0x14c0, 0x22); W(0x1308, 1); W(0x132c, 0x1f); W(0x1444, 0);
}

/* Bus reset or deconfiguration: the host's session is gone. */
static void usb_clear_session(void)
{
	kfifo_reset(&tx_fifo);
	tx_busy = short_pending = zlp = status_pending = false;
	configured = false;
	lines = 0;
	W(0x130c, 0x10); W(0x1328, 3); W(0x148c, 0x3f);
}

static bool usb_online(void)
{
	return configured && (lines & 1);	/* DTR */
}

/* Control requests: only SET_CONTROL_LINE_STATE (21 22) is accepted, the
 * rest are stalled; the status stage reports the lines on EP3. */
static void usb_setup(void)
{
	u8 b[8];
	unsigned int i;

	for (i = 0; i < 8; i++) {
		W(0x1480, ~0x10U);
		b[i] = R(0x14cc);
	}
	if (R(0x1468) & 0x10)
		return;			/* overwritten: reread next poll */
	if (b[0] == 0x21 && b[1] == 0x22 && !b[3] && !b[4] && !b[5] && !b[6] &&
	    !b[7]) {
		pending_lines = b[2] & 3;
		status_pending = true;
	} else {
		W(0x1460, R(0x1460) | 8);
		W(0x148c, 1);
	}
	W(0x1480, ~1U);
}

static void usb_status_stage(void)
{
	W(0x148c, 2); W(0x1490, 1);
	W(0x147c, ~0x20U); W(0x1480, ~0x20U);
	if (lines && !pending_lines) {
		bool saved = configured;

		usb_clear_session();
		configured = saved;
	}
	lines = pending_lines;
	status_pending = false;
	if (!(R(0x1454) & 0x10)) {
		W(0x14e0, (lines & 1 ? 0xa0 : 0) | (lines & 2 ? 0x10 : 0));
		W(0x14e0, 0);
		W(0x1490, 4);
	}
}

static void usb_rx(void)
{
	unsigned char buf[64];
	unsigned int k, i, n;

	/* At most four packets per tick, as glaze. */
	for (k = 0; k < 4 && (R(0x1454) & 8); k++) {
		n = R(0x14d8);
		if (n > 64 || tty_buffer_space_avail(&usb_port) < n)
			break;
		if (!n) {	/* a zero-length OUT packet: a zero DMA consumes it */
			if (tx_busy)
				break;
			W(0x1310, 0); W(0x1318, 0); W(0x131c, 0);
			W(0x1320, dma_phys | 0xa0000000UL);
			W(0x130c, 1); W(0x1328, 1);
			break;
		}
		for (i = 0; i < n; i++)
			buf[i] = R(0x14d4);
		tty_insert_flip_string(&usb_port, buf, n);
	}
	if (k)
		tty_flip_buffer_push(&usb_port);
}

/* Returns true when TX space was freed. */
static bool usb_tx(void)
{
	bool freed = false;

	if (tx_busy && (R(0x1324) & 2)) {
		W(0x1328, 2);
		tx_busy = false;
		freed = true;
		if (dma_len < 64) {
			W(0x1490, 2);
			short_pending = true;
		} else if (kfifo_is_empty(&tx_fifo)) {
			zlp = true;
		}
	}
	if (short_pending) {
		if (!(R(0x1464) & 4))
			return freed;
		short_pending = false;
	}
	if (tx_busy || !(R(0x1464) & 4))
		return freed;
	if (kfifo_is_empty(&tx_fifo)) {
		W(0x1488, 0);
		if (zlp) {
			W(0x148c, 4); W(0x1490, 2);
			zlp = false;
			short_pending = true;
		}
		return freed;
	}
	zlp = false;
	dma_len = kfifo_out(&tx_fifo, dma, 64);
	wmb();
	W(0x1488, 0x85);
	W(0x1310, 1); W(0x1318, 0); W(0x131c, dma_len);
	W(0x1320, dma_phys | 0xa0000000UL);
	W(0x1490, 0x10); W(0x130c, 1);
	tx_busy = true;
	return freed;
}

static void usb_poll(unsigned long unused)
{
	unsigned long flags;
	u32 s1, s2;
	bool wake = false, hangup = false;

	spin_lock_irqsave(&usb_lock, flags);
	s1 = R(0x1468);
	s2 = R(0x146c);
	if (s2 & 2) {
		hangup = usb_online();
		usb_clear_session();
		W(0x1484, ~2U);
	}
	if (s2 & 4) {
		bool now = (R(0x1450) & 0x80) != 0;

		if (!now) {
			hangup |= usb_online();
			usb_clear_session();
		}
		configured = now;
		W(0x1484, ~4U);
	}
	if (s1 & 1)
		usb_setup();
	if (status_pending && (R(0x1468) & 0x20)) {
		bool was = usb_online();

		usb_status_stage();
		hangup |= was && !usb_online();
	}
	if (R(0x146c) & 8)
		W(0x1484, ~8U);
	if (configured) {
		usb_rx();
		wake = usb_tx();
	}
	spin_unlock_irqrestore(&usb_lock, flags);
	if (wake)
		tty_port_tty_wakeup(&usb_port);
	if (hangup)
		tty_port_tty_hangup(&usb_port, false);
	mod_timer(&usb_timer, jiffies + 1);
}

static int usb_tty_open(struct tty_struct *tty, struct file *filp)
{
	return tty_port_open(&usb_port, tty, filp);
}

static void usb_tty_close(struct tty_struct *tty, struct file *filp)
{
	tty_port_close(&usb_port, tty, filp);
}

/* Without a host holding DTR the line is like an unplugged serial cable:
 * output is discarded rather than left to block the writer. */
static int usb_tty_write(struct tty_struct *tty, const unsigned char *buf,
			 int count)
{
	unsigned long flags;
	int n = count;

	spin_lock_irqsave(&usb_lock, flags);
	if (usb_online())
		n = kfifo_in(&tx_fifo, buf, count);
	spin_unlock_irqrestore(&usb_lock, flags);
	return n;
}

static int usb_tty_write_room(struct tty_struct *tty)
{
	return usb_online() ? kfifo_avail(&tx_fifo) : TX_FIFO;
}

static int usb_tty_chars_in_buffer(struct tty_struct *tty)
{
	return kfifo_len(&tx_fifo) + (tx_busy ? dma_len : 0);
}

static const struct tty_operations usb_tty_ops = {
	.open = usb_tty_open,
	.close = usb_tty_close,
	.write = usb_tty_write,
	.write_room = usb_tty_write_room,
	.chars_in_buffer = usb_tty_chars_in_buffer,
};

static const struct tty_port_operations usb_port_ops = {
};

static int __init be300_usb_serial_init(void)
{
	unsigned long page;
	int ret;

	page = __get_free_page(GFP_KERNEL);
	if (!page)
		return -ENOMEM;
	dma_phys = virt_to_phys((void *)page);
	dma = (u8 *)KSEG1ADDR(dma_phys);
	dma_cache_wback_inv(page, PAGE_SIZE);

	usb_tty = tty_alloc_driver(1, TTY_DRIVER_REAL_RAW |
				   TTY_DRIVER_DYNAMIC_DEV);
	if (IS_ERR(usb_tty)) {
		free_page(page);
		return PTR_ERR(usb_tty);
	}
	usb_tty->driver_name = "be300_usb";
	usb_tty->name = "ttyBEU";
	usb_tty->major = 0;
	usb_tty->type = TTY_DRIVER_TYPE_SERIAL;
	usb_tty->subtype = SERIAL_TYPE_NORMAL;
	usb_tty->init_termios = tty_std_termios;
	usb_tty->init_termios.c_cflag = B115200 | CS8 | CREAD | HUPCL | CLOCAL;
	tty_set_operations(usb_tty, &usb_tty_ops);
	tty_port_init(&usb_port);
	usb_port.ops = &usb_port_ops;
	tty_port_link_device(&usb_port, usb_tty, 0);
	ret = tty_register_driver(usb_tty);
	if (ret) {
		put_tty_driver(usb_tty);
		free_page(page);
		return ret;
	}
	tty_register_device(usb_tty, 0, NULL);

	usb_hw_init();
	setup_timer(&usb_timer, usb_poll, 0);
	mod_timer(&usb_timer, jiffies + 1);
	printk(KERN_INFO "BE-300: USB function (07cf:2002) as ttyBEU0\n");
	return 0;
}
late_initcall(be300_usb_serial_init);

MODULE_DESCRIPTION("BE-300 USB function serial line");
MODULE_LICENSE("GPL");
