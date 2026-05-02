/*
 * arch/mips/vr41xx/casio-be300/power.c
 *
 * Minimal APM status provider for the BE-300 emulator profile.
 *
 * Copyright (C) 2026 John Roark
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#include <linux/apm-emulation.h>
#include <linux/init.h>

static void be300_apm_get_power_status(struct apm_power_info *info)
{
	info->ac_line_status = APM_AC_ONLINE;
	info->battery_status = APM_BATTERY_STATUS_HIGH;
	info->battery_flag = APM_BATTERY_FLAG_HIGH;
	info->battery_life = 100;
	info->time = -1;
	info->units = APM_UNITS_UNKNOWN;
}

static int __init be300_power_init(void)
{
	apm_get_power_status = be300_apm_get_power_status;

	return 0;
}
device_initcall(be300_power_init);
