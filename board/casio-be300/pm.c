/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * BE-300 suspend to RAM ("mem" in /sys/power/state), Linux 4.2.
 *
 * VR4131 SUSPEND (UM 12.1.4(3)): every clock but the RTC's, ICU's and
 * PMU's stops and SDRAM self-refreshes until an interrupt request. As
 * glaze-os kernel/drivers/power.c suspend_until() and Windows CE
 * (nk.exe 0x800792AC..0x80079598) do: stop the power MCU's watchdog,
 * power the panel down, leave only the power switch (POWERINTR) unmasked
 * in the ICU and only the ICU's line (IM2) in Status, so the Count/
 * Compare tick cannot end the sleep, and sleep again until the switch is
 * what woke it. Waking also presses Power for the buttons driver, which
 * reports KEY_POWER; userspace choosing to suspend on KEY_POWER should
 * ignore the press that woke it.
 *
 * Emulator-verified only: glaze-os has not yet checked SUSPEND's wake on
 * a real BE-300 (docs/hardware/POWER.md).
 */
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/interrupt.h>
#include <linux/suspend.h>
#include <linux/io.h>
#include <asm/irq_regs.h>
#include <asm/mipsregs.h>
#include <asm/vr41xx/irq.h>
#include "hardware.h"

#define ICU_MSYSINT1	((void __iomem *)KSEG1ADDR(0x0b00008c))
#define ICU_MGIUINTL	((void __iomem *)KSEG1ADDR(0x0b000094))
#define ICU_SYSINT1	((void __iomem *)KSEG1ADDR(0x0b000080))
#define ICU_MSYSINT2	((void __iomem *)KSEG1ADDR(0x0f0000a6))
#define ICU_MGIUINTH	((void __iomem *)KSEG1ADDR(0x0f0000a8))
#define PMU_INT		((void __iomem *)KSEG1ADDR(0x0f0000c0))
#define GIU_INTSTATL	((void __iomem *)KSEG1ADDR(0x0f000148))
#define GIRQ0_KEYS	((void __iomem *)KSEG1ADDR(0x0a000014))	/* source 1 */
#define KEYS_LATCH	((void __iomem *)KSEG1ADDR(0x0a00a042))
#define KEYS_SET2	((void __iomem *)KSEG1ADDR(0x0a00a045))
#define SYSINT1_POWER	0x0002
#define SYSINT1_GIU	0x0100
#define KEY2_POWER	0x80
#define PMUINT_POWERSWINTR 0x0001

static volatile int power_pressed;

/* Power held, read as the buttons driver does (keybddr.dll: a throwaway
 * 16-bit read of A042, then the set-2 byte at A045). */
static int power_held(void)
{
	(void)readw(KEYS_LATCH);
	return readb(KEYS_SET2) & KEY2_POWER;
}

/* Re-arm the wake sources: a write acknowledges the button source's latch
 * (bits 2 and 3: mode and enable), then GIU line 0's status. */
static void wake_ack(void)
{
	writew(PMUINT_POWERSWINTR, PMU_INT);
	writel(0x0c, GIRQ0_KEYS);
	writew(0x0001, GIU_INTSTATL);
}
extern const char be300_sleep_begin[], be300_sleep_end[];

/* The switch while running or asleep: acknowledge it (PMUINTREG W1C). An
 * interrupt taken between enabling interrupts and SUSPEND would otherwise
 * return into the SUSPEND and sleep until the next press: resume past it,
 * as glaze-os power_trap() does. */
static irqreturn_t be300_power_irq(int irq, void *dev)
{
	struct pt_regs *regs = get_irq_regs();

	writew(PMUINT_POWERSWINTR, PMU_INT);
	power_pressed = 1;
	if (regs && regs->cp0_epc >= (unsigned long)be300_sleep_begin &&
	    regs->cp0_epc < (unsigned long)be300_sleep_end)
		regs->cp0_epc = (unsigned long)be300_sleep_end;
	return IRQ_HANDLED;
}

/* One SUSPEND with interrupts on and only IM2 (the ICU) unmasked, as one
 * block. Glaze sets IE itself rather than relying on SUSPEND doing so as
 * STANDBY does; the emulator's SUSPEND is a WAIT that does not. */
static void be300_suspend_once(unsigned int status)
{
	__asm__ __volatile__(
		".set push\n\t.set noreorder\n\t"
		".globl be300_sleep_begin\nbe300_sleep_begin:\n\t"
		"mtc0 %0, $12\n\tnop\n\tnop\n\tnop\n\t"
		".word 0x42000022\n\t"	/* suspend: COP0 function 0x22 */
		"nop\n\tnop\n\tnop\n\tnop\n\t"
		".globl be300_sleep_end\nbe300_sleep_end:\n\t"
		".set pop" :: "r"(status) : "memory");
}

static int be300_pm_enter(suspend_state_t state)
{
	u16 msysint1, msysint2, mgiul, mgiuh;
	unsigned int status;
	u32 keys;

	be300_lcd_suspend();
	be300_cmcu_shutdown();

	local_irq_disable();
	status = read_c0_status();
	msysint1 = readw(ICU_MSYSINT1);
	msysint2 = readw(ICU_MSYSINT2);
	mgiul = readw(ICU_MGIUINTL);
	mgiuh = readw(ICU_MGIUINTH);
	keys = readl(GIRQ0_KEYS) & 0x0f;
	writew(0, ICU_MSYSINT1);
	writew(0, ICU_MSYSINT2);
	writew(0, ICU_MGIUINTH);
	/*
	 * Wake on POWERINTR, and on the GIRQ0 button source through GIU line
	 * 0 as glaze-os does: the Power key is in that source's word, and the
	 * emulator raises no POWERINTR while running. The board cascade masks
	 * the source again when it fires, so other buttons cannot storm.
	 */
	wake_ack();
	writew(0x0001, ICU_MGIUINTL);
	writew(SYSINT1_POWER | SYSINT1_GIU, ICU_MSYSINT1);
	power_pressed = 0;
	for (;;) {
		be300_suspend_once((status & ~ST0_IM) | STATUSF_IP2 | ST0_IE);
		local_irq_disable();
		if (power_pressed || power_held() ||
		    (readw(ICU_SYSINT1) & SYSINT1_POWER))
			break;
		wake_ack();
	}
	writew(PMUINT_POWERSWINTR, PMU_INT);
	writel(keys, GIRQ0_KEYS);
	writew(0x0001, GIU_INTSTATL);
	writew(mgiuh, ICU_MGIUINTH);
	writew(mgiul, ICU_MGIUINTL);
	writew(msysint2, ICU_MSYSINT2);
	writew(msysint1, ICU_MSYSINT1);
	write_c0_status(status);
	local_irq_enable();

	be300_cmcu_resume();
	be300_lcd_resume();
	return 0;
}

static const struct platform_suspend_ops be300_pm_ops = {
	.valid = suspend_valid_only_mem,
	.enter = be300_pm_enter,
};

static int __init be300_pm_init(void)
{
	int ret = request_irq(POWER_IRQ, be300_power_irq, IRQF_NO_SUSPEND, "power switch",
			      NULL);

	if (ret)
		printk(KERN_WARNING "BE-300: power switch IRQ: %d\n", ret);
	suspend_set_ops(&be300_pm_ops);
	printk(KERN_INFO "BE-300: suspend to RAM available\n");
	return 0;
}
late_initcall(be300_pm_init);
