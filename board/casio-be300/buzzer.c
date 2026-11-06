/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * BE-300 piezo buzzer as an input sound device, Linux 2.4/2.6/4.2.
 *
 * EV_SND SND_TONE <hz> sounds the piezo until a SND_TONE 0; SND_BELL 1 is
 * a 1 kHz tone, like pcspkr. On 2.6 and 4.2 the keyboard handler routes
 * the console bell and KDMKTONE/KIOCSOUND here; 2.4 has no such path, so
 * its kd_mksound hook is taken over instead. Userspace can also write the
 * events to the evdev node. Registers: hardware.c / hardware-regs.h
 * (bltinbuz.dll, via glaze-os kernel/drivers/buzzer.c).
 */
#include <linux/version.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/input.h>
#include <linux/timer.h>
#include <linux/errno.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
#include <linux/sched.h>
#include <linux/vt_kern.h>
#endif
#include "hardware.h"
#include "hard_icons.h"

#ifndef SND_TONE
#define SND_TONE 0x02	/* not yet in 2.4.18's input.h */
#endif

static int buzzer_event(struct input_dev *dev, unsigned int type,
			unsigned int code, int value)
{
	if (type != EV_SND)
		return -1;
	switch (code) {
	case SND_BELL:
		if (value)
			value = 1000;
		break;
	case SND_TONE:
		break;
	default:
		return -1;
	}
	be300_buzzer_tone(value > 0 ? value : 0);
	return 0;
}

#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
static struct input_dev buzzer_dev;
static struct timer_list bell_timer;

static void bell_off(unsigned long unused)
{
	be300_buzzer_tone(0);
}

/* vt.c has already turned KIOCSOUND/KDMKTONE's PIT count back into hz. */
static void buzzer_mksound(unsigned int hz, unsigned int ticks)
{
	del_timer(&bell_timer);
	if (hz > 20 && hz < 32767) {
		be300_buzzer_tone(hz);
		if (ticks)
			mod_timer(&bell_timer, jiffies + ticks);
	} else {
		be300_buzzer_tone(0);
	}
}

static int __init buzzer_init(void)
{
	init_timer(&bell_timer);
	bell_timer.function = bell_off;
	buzzer_dev.name = "BE-300 Buzzer";
	buzzer_dev.evbit[0] = BIT(EV_SND);
	buzzer_dev.sndbit[0] = BIT(SND_BELL) | BIT(SND_TONE);
	buzzer_dev.event = buzzer_event;
	input_register_device(&buzzer_dev);
#ifdef CONFIG_VT
	kd_mksound = buzzer_mksound;
#endif
	printk(KERN_INFO "BE-300: piezo buzzer registered\n");
	return 0;
}
__initcall(buzzer_init);

#elif LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 15)
static struct input_dev buzzer_dev;

/* After the board's touch, button and keyboard devices, whose
 * /dev/input/event numbers profiles depend on. */
static int __init buzzer_init(void)
{
	init_input_dev(&buzzer_dev);
	buzzer_dev.name = "BE-300 Buzzer";
	buzzer_dev.evbit[0] = BIT(EV_SND);
	buzzer_dev.sndbit[0] = BIT(SND_BELL) | BIT(SND_TONE);
	buzzer_dev.event = buzzer_event;
	input_register_device(&buzzer_dev);
	printk(KERN_INFO "BE-300: piezo buzzer registered\n");
	return 0;
}
late_initcall(buzzer_init);

#else
static int __init buzzer_init(void)
{
	struct input_dev *dev;
	int ret;

	be300_input_settle();
	dev = input_allocate_device();
	if (!dev)
		return -ENOMEM;
	dev->name = "BE-300 Buzzer";
	dev->phys = "be300/buzzer";
	dev->id.bustype = BUS_HOST;
	dev->evbit[0] = BIT_MASK(EV_SND);
	dev->sndbit[0] = BIT_MASK(SND_BELL) | BIT_MASK(SND_TONE);
	dev->event = buzzer_event;
	ret = input_register_device(dev);
	if (ret) {
		input_free_device(dev);
		return ret;
	}
	printk(KERN_INFO "BE-300: piezo buzzer registered\n");
	return 0;
}
late_initcall(buzzer_init);
#endif

MODULE_DESCRIPTION("BE-300 piezo buzzer");
MODULE_LICENSE("GPL");
