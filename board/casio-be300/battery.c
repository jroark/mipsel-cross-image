/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * BE-300 battery, AC adapter and charger, Linux 2.4/2.6/4.2.
 *
 * Read as Windows CE's gwes.exe battery driver does (glaze-os
 * kernel/drivers/battery.c, docs/hardware/POWER.md):
 *   GIUPIODL bit 12   1 on battery, 0 with the adapter in
 *   GIUPIODL bit 2    with the adapter: 1 charging, 0 charged
 *   PIU 0x390         battery voltage, 12-bit, by an A/D port scan
 *   EEPROM 0x94/0x95  calibration, else CE's 4.2 V / 3.7 V defaults
 * Arithmetic: battery.h. Registers: hardware-regs.h.
 *
 * Every 2 s, while the touch sequencer is idle, the scan is stopped, GPIO8
 * driven low and, 20 ms later, one conversion made before the touch scan
 * restarts; if the touch driver restarted it meanwhile the sample is tried
 * again shortly. The lines are debounced over 250 ms.
 *
 * 4.2 reports through APM emulation (/proc/apm, APM_IOC_*); 2.4 and 2.6,
 * whose MIPS ports have no APM, get a /proc/apm in the same format.
 */
#include <linux/version.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/timer.h>
#include <linux/spinlock.h>
#include <linux/delay.h>
#include <linux/errno.h>
#include <asm/io.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 15)
#include <linux/apm-emulation.h>
#endif
#include <linux/proc_fs.h>
#include "hardware.h"
#ifndef __iomem
#define __iomem
#endif
/* Only the battery helpers are used in this file. */
#pragma GCC diagnostic ignored "-Wunused-function"
#include "hardware-regs.h"
#include "battery.h"

#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 15)
#ifdef CONFIG_APM_EMULATION
#define BE300_BATT_APM_EMULATION 1
#endif
#else
#define BE300_BATT_PROC_APM 1
#endif

#define POLL_MS		250
#define SAMPLE_POLLS	8	/* a sample every 2 s */
#define SETTLE_MS	20	/* >= 10 ms after GPIO8 (gwes 0xB041C) */

static struct timer_list batt_timer;
static spinlock_t batt_lock;
static struct be300_batt_cal cal;
static unsigned short samples[BE300_BATT_SAMPLES];
static unsigned int next_sample, low_readings, polls, lines, pending_lines;
static unsigned int band = 100, level = 100, valid, settling;

static unsigned long batt_ms(unsigned int ms)
{
	unsigned long j = (ms * HZ + 999) / 1000;

	return j ? j : 1;
}

/* gwes 0xB0704-0xB0868: on battery LOW at the 25 % band or below and
 * CRITICAL after two 10 % readings; with the adapter in and charged, CE
 * reports 100 % whatever the A/D reads. */
static void batt_status(int *ac, int *charging, int *low, int *critical,
			unsigned int *percent)
{
	*ac = !(lines & BE300_GPIO_ON_BATTERY);
	*charging = *ac && (lines & BE300_GPIO_CHARGING);
	*percent = level;
	*low = *critical = 0;
	if (*ac && !*charging)
		*percent = 100;
	else if (!*ac && valid) {
		*low = band <= 25;
		*critical = low_readings >= 2;
	}
}

static void batt_sample_end(void)
{
	unsigned int v, avg;

	/* The touch driver restarted the scan meanwhile: try again soon. */
	if (BE300_R16(0x0a000300) & 0x0004) {
		polls = SAMPLE_POLLS - 1;
		return;
	}
	v = be300_regs_battery_convert();
	be300_piu_start();
	if (!v)
		return;		/* CE keeps its last percentage */
	samples[next_sample] = v;
	next_sample = (next_sample + 1) % BE300_BATT_SAMPLES;
	avg = be300_batt_average(samples, BE300_BATT_SAMPLES);
	band = be300_batt_band(avg, &cal);
	level = be300_batt_level(avg, &cal);
	if (lines & BE300_GPIO_ON_BATTERY) {
		if (band <= 10)
			low_readings++;
	} else {
		low_readings = 0;
	}
	valid = 1;
}

static void batt_tick(unsigned long unused)
{
	unsigned long flags;
	unsigned int now;

	spin_lock_irqsave(&batt_lock, flags);
	if (settling) {
		settling = 0;
		batt_sample_end();
		spin_unlock_irqrestore(&batt_lock, flags);
		mod_timer(&batt_timer, jiffies + batt_ms(POLL_MS));
		return;
	}
	now = be300_regs_battery_lines();
	if (now != pending_lines)
		pending_lines = now;
	else
		lines = now;
	if (++polls >= SAMPLE_POLLS) {
		if (be300_regs_piu_idle()) {
			polls = 0;
			be300_regs_battery_begin();
			settling = 1;
			spin_unlock_irqrestore(&batt_lock, flags);
			mod_timer(&batt_timer, jiffies + batt_ms(SETTLE_MS));
			return;
		}
		polls = SAMPLE_POLLS - 1;	/* the pen is down */
	}
	spin_unlock_irqrestore(&batt_lock, flags);
	mod_timer(&batt_timer, jiffies + batt_ms(POLL_MS));
}

#ifdef BE300_BATT_APM_EMULATION
static void be300_apm_get_power_status(struct apm_power_info *info)
{
	int ac, charging, low, critical;
	unsigned int percent;
	unsigned long flags;

	spin_lock_irqsave(&batt_lock, flags);
	batt_status(&ac, &charging, &low, &critical, &percent);
	spin_unlock_irqrestore(&batt_lock, flags);
	info->ac_line_status = ac ? APM_AC_ONLINE : APM_AC_OFFLINE;
	info->battery_status = charging ? APM_BATTERY_STATUS_CHARGING :
		critical ? APM_BATTERY_STATUS_CRITICAL :
		low ? APM_BATTERY_STATUS_LOW : APM_BATTERY_STATUS_HIGH;
	info->battery_flag = charging ? APM_BATTERY_FLAG_CHARGING :
		critical ? APM_BATTERY_FLAG_CRITICAL :
		low ? APM_BATTERY_FLAG_LOW : APM_BATTERY_FLAG_HIGH;
	info->battery_life = percent;
	info->time = -1;
	info->units = APM_UNITS_UNKNOWN;
}
#endif
#ifdef BE300_BATT_PROC_APM
/* linux/arch/i386/kernel/apm.c's format: driver and BIOS version, flags,
 * AC line, battery status, battery flag, percentage, time, units. */
static int batt_proc_read(char *page, char **start, off_t off, int count,
			  int *eof, void *data)
{
	int ac, charging, low, critical, len;
	unsigned int percent, status, flag;
	unsigned long flags;

	spin_lock_irqsave(&batt_lock, flags);
	batt_status(&ac, &charging, &low, &critical, &percent);
	spin_unlock_irqrestore(&batt_lock, flags);
	status = charging ? 3 : critical ? 2 : low ? 1 : 0;
	flag = charging ? 8 : critical ? 4 : low ? 2 : 1;
	len = sprintf(page, "1.16 1.2 0x02 0x%02x 0x%02x 0x%02x %u%% -1 ?\n",
		      ac, status, flag, percent);
	if (off >= len) {
		*eof = 1;
		return 0;
	}
	*start = page + off;
	len -= off;
	if (len > count)
		len = count;
	else
		*eof = 1;
	return len;
}
#endif

static int __init be300_battery_init(void)
{
	unsigned int b0 = 0xff, b1 = 0xff;
	int acked, eeprom;

	spin_lock_init(&batt_lock);
	acked = be300_regs_ee_battery_cal(&b0, &b1);
	eeprom = acked && be300_batt_cal_decode(b0, b1, &cal);
	if (!eeprom)
		be300_batt_cal_decode(0xff, 0xff, &cal);
	lines = pending_lines = be300_regs_battery_lines();
#ifdef BE300_BATT_APM_EMULATION
	apm_get_power_status = be300_apm_get_power_status;
#endif
#ifdef BE300_BATT_PROC_APM
	create_proc_read_entry("apm", 0, NULL, batt_proc_read, NULL);
#endif
	init_timer(&batt_timer);
	batt_timer.function = batt_tick;
	batt_timer.data = 0;
	polls = SAMPLE_POLLS - 2;	/* the first sample half a second in */
	batt_timer.expires = jiffies + batt_ms(POLL_MS);
	add_timer(&batt_timer);
	printk(KERN_INFO "BE-300: battery %s, calibration %s %03x-%03x\n",
	       lines & BE300_GPIO_ON_BATTERY ? "on battery" :
	       lines & BE300_GPIO_CHARGING ? "charging" : "adapter, charged",
	       eeprom ? "EEPROM" : "default", cal.min, cal.max);
	return 0;
}
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
__initcall(be300_battery_init);
#else
late_initcall(be300_battery_init);	/* after the touch driver's PIU setup */
#endif

MODULE_DESCRIPTION("BE-300 battery and AC adapter");
MODULE_LICENSE("GPL");
