/* Board initialization shared by the 2.4, 2.6 and 4.2 source builds.
 * Sources and limits: docs/HARDWARE.md; no post-WinCE register snapshots.
 */
#include <linux/version.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/errno.h>
#include <linux/ctype.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/timer.h>
#include <linux/delay.h>
#include <linux/spinlock.h>
#include <asm/io.h>
#include <asm/uaccess.h>
#include "hardware.h"
#ifndef __iomem
#define __iomem
#endif
#ifndef __user
#define __user
#endif
#include "hardware-regs.h"

/* Initialized before registering controls; valid on all three kernels. */
static spinlock_t display_lock;
static struct timer_list cmcu_timer;
static unsigned int cmcu_polls;
static unsigned int brightness = 5, contrast = 5;
static int blanked;
static u32 saved_control, saved_config, saved_gate;

void be300_girq0_source_mask(unsigned int source)
{
	unsigned long pa = 0x0a000010UL + source * 4;
	BE300_W32(pa, BE300_R32(pa) & ~8U);
}

void be300_girq0_source_unmask(unsigned int source)
{
	unsigned long pa = 0x0a000010UL + source * 4;
	/* WinCE initializes an owned source with 4 then C. */
	BE300_W32(pa, BE300_R32(pa) | 0x0c);
}

void be300_girq0_pending_ack(unsigned int pending)
{
	unsigned int source;
	for (source = 0; source < 16; source++)
		if (pending & (1U << source))
			be300_girq0_source_mask(source);
}

void be300_girq0_init(void)
{
	unsigned int source;
	for (source = 0; source < 16; source++)
		be300_girq0_source_mask(source);
	BE300_W32(0x0a000008, 1);
}

void be300_console_ready(void)
{
	if (!be300_regs_siu_clocked())
		be300_regs_power_on();
}
void be300_giu0_prepare(void)
{
	be300_regs_giu0();
}

int be300_piu_prepare(void)
{
	if (be300_regs_piu_prepare()) {
		printk(KERN_ERR "BE-300: PIU reset timed out\n");
		return -ETIMEDOUT;
	}
	return 0;
}

int be300_lcd_blank(int blank)
{
	unsigned long flags;

	blank = !!blank;
	spin_lock_irqsave(&display_lock, flags);
	if (blank != blanked) {
		if (blank) {
			saved_control = BE300_R32(BE300_BLG(0));
			saved_config = BE300_R32(BE300_BLG(4));
			saved_gate = BE300_R32(BE300_CMM) & 1;
			BE300_W32(BE300_BLG(0), 0);
			BE300_W32(BE300_BLG(4), 0);
			BE300_W32(BE300_CMM, BE300_R32(BE300_CMM) & ~1U);
		} else {
			BE300_W32(BE300_CMM, (BE300_R32(BE300_CMM) & ~1U) | saved_gate);
			BE300_W32(BE300_BLG(4), saved_config);
			BE300_W32(BE300_BLG(0), saved_control);
		}
		blanked = blank;
	}
	spin_unlock_irqrestore(&display_lock, flags);
	return 0;
}

static ssize_t display_read(struct file *file, char __user *buf,
			    size_t count, loff_t *pos)
{
	char text[32];
	int len;
	unsigned long flags;

	spin_lock_irqsave(&display_lock, flags);
	len = sprintf(text, "%u %u\n", brightness, contrast);
	spin_unlock_irqrestore(&display_lock, flags);
	if (*pos < 0)
		return -EINVAL;
	if (*pos >= len)
		return 0;
	if (count > len - *pos)
		count = len - *pos;
	if (copy_to_user(buf, text + *pos, count))
		return -EFAULT;
	*pos += count;
	return count;
}

/* Bounded decimal parsing also works on the original 2.4 kernel, whose
 * early lib/vsprintf may not provide sscanf/snprintf.
 */
static int display_level(char **cursor, unsigned int max, unsigned int *out)
{
	char *p = *cursor;
	unsigned int value = 0;

	while (isspace(*p))
		p++;
	if (!isdigit(*p))
		return -EINVAL;
	do {
		value = value * 10 + *p++ - '0';
		if (value > max)
			return -EINVAL;
	} while (isdigit(*p));
	if (*p && !isspace(*p))
		return -EINVAL;
	*cursor = p;
	*out = value;
	return 0;
}

static ssize_t display_write(struct file *file, const char __user *buf,
			     size_t count, loff_t *pos)
{
	char text[32], *cursor = text;
	unsigned int b, c;
	unsigned long flags;

	if (!count || count >= sizeof(text))
		return -EINVAL;
	if (copy_from_user(text, buf, count))
		return -EFAULT;
	text[count] = 0;
	if (display_level(&cursor, 5, &b) ||
	    display_level(&cursor, 11, &c) || c < 1)
		return -EINVAL;
	while (isspace(*cursor))
		cursor++;
	if (*cursor)
		return -EINVAL;
	spin_lock_irqsave(&display_lock, flags);
	if (b != brightness)
		be300_regs_brightness(b);
	if (c != contrast)
		be300_regs_contrast(c);
	brightness = b;
	contrast = c;
	spin_unlock_irqrestore(&display_lock, flags);
	return count;
}

static struct file_operations display_fops = {
	.owner = THIS_MODULE,
	.read = display_read,
	.write = display_write,
};

static struct miscdevice display_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "be300-display",
	.fops = &display_fops,
};

static void cmcu_tick(unsigned long unused)
{
	be300_regs_watchdog_poll();
	if (++cmcu_polls == 50) {
		be300_regs_watchdog_reload();
		cmcu_polls = 0;
	}
	mod_timer(&cmcu_timer, jiffies + (HZ / 10 ? HZ / 10 : 1));
}

static void __init be300_socket_prepare(void)
{
	unsigned int n;
	u32 ctrl;

	if (!be300_regs_card_present())
		return;
	ctrl = BE300_R32(0x0a00a000);
	if ((ctrl & 0x0b) == 0x0b && !(BE300_R32(0x0a00a004) & 1))
		return; /* configured handoff, leave the card's COR alone */
	BE300_W32(0x0a00a034, (BE300_R32(0x0a00a034) | 4) & ~0x30U);
	BE300_W32(0x0a00a034, (BE300_R32(0x0a00a034) | 8) & ~0x30U);
	BE300_W32(0x0a00a024, BE300_R32(0x0a00a024) & ~0x0cU);
	BE300_W32(0x0a00a020, BE300_R32(0x0a00a020) & ~0x0cU);
	BE300_W32(0x0a00a000, 0);
	BE300_W32(0x0a00a004, BE300_R32(0x0a00a004) | 1);
	BE300_W32(0x0a00a000, 8);
	BE300_W32(0x0a00a000, 9);
	for (n = 0; n < 300; n++)
		udelay(1000);
	BE300_W32(0x0a00a004, BE300_R32(0x0a00a004) & ~1U);
	for (n = 0; n < 20; n++)
		udelay(1000);
	BE300_W32(0x0a00a000, 0x0b);
	BE300_W32(0x0a001b20, 1);
	BE300_W32(0x0a00a01c, BE300_R32(0x0a00a01c) | 4);
}

static int __init be300_hardware_init(void)
{
	spin_lock_init(&display_lock);
	be300_regs_power_on();	/* before any other companion unit */
	be300_regs_lcd_init();
	be300_socket_prepare();
	BE300_W16(0x0a00a040, 0x9eff); /* NK 80076D58, keybddr 01A3246C */
	BE300_W32(0x0a0003c8, 2);    /* shared analog interface, NK 80076D94 */
	udelay(200);
	BE300_W32(0x0a0003c8, 3);
	BE300_W32(0x0a007810, 0x10000);
	be300_regs_watchdog_reload();
	init_timer(&cmcu_timer);
	cmcu_timer.function = cmcu_tick;
	cmcu_timer.data = 0;
	cmcu_timer.expires = jiffies + (HZ / 10 ? HZ / 10 : 1);
	add_timer(&cmcu_timer);
	printk(KERN_INFO "BE-300: original LCD initialized; MCU watchdog active\n");
	return 0;
}
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
__initcall(be300_hardware_init);
#else
arch_initcall(be300_hardware_init);
#endif
/* misc_init runs after arch init; registration must wait for its class. */
static int __init be300_display_register(void)
{
	return misc_register(&display_device);
}
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
__initcall(be300_display_register);
#else
device_initcall(be300_display_register);
#endif
MODULE_LICENSE("GPL");
