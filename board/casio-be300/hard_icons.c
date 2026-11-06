/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * "BE-300 Hard Icons": KEY_F1..KEY_F7 for the printed icons below the LCD
 * (hard_icons.h), Linux 2.4/2.6/4.2. The touch driver calls
 * be300_hard_icon() from its interrupt path when a strip tap is released.
 * Registered last (late initcall) so existing /dev/input/event numbers
 * of the touch, button and keyboard devices do not move.
 */
#include <linux/version.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/input.h>
#include <linux/errno.h>
#include "hardware.h"
#include "hard_icons.h"

#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
/* The 2.4 port's evdev uses EV_SYN (its EV_RST alias) as the batch
 * terminator, as keys_be300.c does. */
#define input_sync(dev) input_event(dev, EV_SYN, SYN_REPORT, 0)
#endif
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 15)
static struct input_dev icons_storage;
#endif
static struct input_dev *icons;

void be300_hard_icon(int icon)
{
	if (!icons || icon < 0 || icon >= BE300_ICON_COUNT)
		return;
	input_report_key(icons, KEY_F1 + icon, 1);
	input_sync(icons);
	input_report_key(icons, KEY_F1 + icon, 0);
	input_sync(icons);
}

static int __init hard_icons_init(void)
{
	struct input_dev *dev;
	int n;

#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 15)
	dev = &icons_storage;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
	init_input_dev(dev);
#endif
#else
	be300_input_settle();
	dev = input_allocate_device();
	if (!dev)
		return -ENOMEM;
	dev->phys = "be300/hard-icons";
	dev->id.bustype = BUS_HOST;
#endif
	dev->name = "BE-300 Hard Icons";
	set_bit(EV_KEY, dev->evbit);
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
	set_bit(EV_SYN, dev->evbit);	/* == 0; passes 2.4 evdev's SYN gate */
#endif
	for (n = 0; n < BE300_ICON_COUNT; n++)
		set_bit(KEY_F1 + n, dev->keybit);
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 15)
	input_register_device(dev);
#else
	n = input_register_device(dev);
	if (n) {
		input_free_device(dev);
		return n;
	}
#endif
	icons = dev;
	printk(KERN_INFO "BE-300: hard icons send F1-F7\n");
	return 0;
}
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
__initcall(hard_icons_init);
#else
late_initcall(hard_icons_init);
#endif

MODULE_DESCRIPTION("BE-300 hard icons");
MODULE_LICENSE("GPL");
