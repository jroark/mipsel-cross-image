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
#include <linux/notifier.h>
#include <linux/reboot.h>
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
#include "card.h"

/* Initialized before registering controls; valid on all three kernels. */
static spinlock_t display_lock;
static struct timer_list cmcu_timer;
static unsigned int cmcu_polls;
static int cmcu_halted;
static unsigned int brightness = 5, contrast = 5;
static int blanked, buzzer_on, panel_asleep, blank_level, suspend_level;
static u32 saved_backlight[3];

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
	unsigned long pa;

	/*
	 * Writing a source word clears its latch; a power-on boot's touch
	 * source is latched before anything runs. Bit 2 must stay set on a
	 * source Linux serves or its latch never clears: PCMCIA 0, buttons 1,
	 * audio 8, touch 9 (glaze-os irq.c, docs/HARDWARE.md).
	 */
	for (source = 0; source < 16; source++) {
		pa = 0x0a000010UL + source * 4;
		if (source <= 1 || source == 8 || source == 9)
			BE300_W32(pa, (BE300_R32(pa) & ~8U) | 4);
		else
			be300_girq0_source_mask(source);
	}
	BE300_W32(0x0a000008, 1);
}

void be300_console_ready(void)
{
	if (!be300_regs_siu_clocked())
		be300_regs_power_on();
}
void be300_framebuffer_ready(void)
{
	/* Enable VRAM access before early fbcon draws. Full panel setup and
	 * settling delays run later, after delay calibration, in hardware_init. */
	BE300_W32(0x0a001100, BE300_R32(0x0a001100) | 1);
	BE300_W32(0x0a00110c, BE300_R32(0x0a00110c) | 1);
}
void be300_giu0_prepare(void)
{
	be300_regs_giu0();
}

void be300_piu_start(void)
{
	be300_regs_piu_start();
}

void be300_piu_ack(unsigned int status)
{
	be300_regs_piu_ack(status);
}

int be300_piu_prepare(void)
{
	if (be300_regs_piu_prepare()) {
		printk(KERN_ERR "BE-300: PIU reset timed out\n");
		return -ETIMEDOUT;
	}
	return 0;
}

/*
 * Framebuffer blank levels: any nonzero level turns the backlight off;
 * POWERDOWN (4, also 2.4 fbcon's VESA powerdown + 1) also powers the panel
 * down, and unblank starts it again with its brightness and contrast.
 * The fb core serializes calls, so the panel's millisecond waits run
 * outside display_lock, which only guards the BLG/CMM registers.
 */
int be300_lcd_blank(int level)
{
	unsigned long flags;
	int blank = level != 0;

	blank_level = level;
	if (!blank && panel_asleep) {
		be300_regs_lcd_init();	/* turns the backlight on at level 5 */
		spin_lock_irqsave(&display_lock, flags);
		if (blanked)
			BE300_W32(BE300_BLG(0), 0);
		be300_regs_brightness(brightness);
		be300_regs_contrast(contrast);
		spin_unlock_irqrestore(&display_lock, flags);
		panel_asleep = 0;
	}
	spin_lock_irqsave(&display_lock, flags);
	if (blank != blanked) {
		if (blank)
			be300_regs_backlight_off(saved_backlight, buzzer_on);
		else
			be300_regs_backlight_on(saved_backlight, buzzer_on);
		blanked = blank;
	}
	spin_unlock_irqrestore(&display_lock, flags);
	if (level >= 4 && !panel_asleep) {
		be300_regs_lcd_sleep();
		panel_asleep = 1;
	}
	return 0;
}

/* Sound the piezo at hz (80..6000, clamped), or stop it with 0. Safe from
 * interrupt context: the console bell stops it from a timer. */
void be300_buzzer_tone(unsigned int hz)
{
	unsigned long flags;

	if (hz && hz < 80)
		hz = 80;
	if (hz > 6000)
		hz = 6000;
	spin_lock_irqsave(&display_lock, flags);
	be300_regs_buzzer(hz, 50);
	buzzer_on = hz != 0;
	/* While blanked the shared gate was released; a tone needs it. */
	if (blanked && !buzzer_on)
		BE300_W32(BE300_CMM, BE300_R32(BE300_CMM) & ~1U);
	spin_unlock_irqrestore(&display_lock, flags);
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
	if (cmcu_halted)
		return;
	be300_regs_watchdog_poll();
	if (++cmcu_polls == 50) {
		be300_regs_watchdog_reload();
		cmcu_polls = 0;
	}
	mod_timer(&cmcu_timer, jiffies + (HZ / 10 ? HZ / 10 : 1));
}

/* Stop serving the power MCU's watchdog and stop the watchdog itself.
 * The keepalive's 0x53/0x3A pair is also its start command, so the timer
 * must not run again afterwards. */
void be300_cmcu_shutdown(void)
{
	cmcu_halted = 1;
	del_timer(&cmcu_timer);
	if (be300_regs_cmcu_stop())
		printk(KERN_WARNING "BE-300: MCU watchdog did not stop\n");
}

/* Halt and power-off end in HIBERNATE or a spin; restart would otherwise
 * also find the watchdog armed before the new kernel serves it. */
static int be300_reboot_notify(struct notifier_block *nb, unsigned long code,
			       void *unused)
{
	be300_cmcu_shutdown();
	if (code != SYS_RESTART)	/* stay off until Power is pressed */
		be300_regs_rtc_alarm_off();
	return NOTIFY_DONE;
}

static struct notifier_block be300_reboot_nb = {
	.notifier_call = be300_reboot_notify,
};

/* Start the watchdog again and resume serving it (after sleep). */
void be300_cmcu_resume(void)
{
	be300_regs_cmcu_start();
	cmcu_polls = 0;
	cmcu_halted = 0;
	mod_timer(&cmcu_timer, jiffies + (HZ / 10 ? HZ / 10 : 1));
}

/* Panel and backlight off for sleep; resume restores the blank level. */
void be300_lcd_suspend(void)
{
	suspend_level = blank_level;
	be300_lcd_blank(4);
}

void be300_lcd_resume(void)
{
	be300_lcd_blank(0);
	if (suspend_level)
		be300_lcd_blank(suspend_level);
}

void be300_card_write_cor(unsigned int attr, unsigned int cor)
{
	be300_regs_card_cor(attr, cor);
}

/*
 * Configure the card in socket 0 for the function its CIS names: ATA
 * through COR 0x43 at the secondary IDE ports, an I/O card from its CONFIG
 * and CFTABLE tuples. On a real BE-300 a COR of zero (power-on) left ATA
 * disabled (glaze-os docs/hardware/PHYSICAL_NAND.md). Emulated cards
 * ignore the COR, so an ATA readback mismatch there is only logged.
 */
int be300_card_configure(void)
{
	unsigned int function = 0xff, man = 0, product = 0, attr, cor;

	if (!be300_regs_card_present())
		return -ENODEV;
	be300_card_identity(&function, &man, &product);
	if (function == 4) {
		if (be300_regs_ata_cor(0x43))
			printk(KERN_INFO "BE-300: CF card did not read back COR 43\n");
		return 0;
	}
	if (be300_card_io_config(&attr, &cor)) {
		be300_regs_card_cor(attr, cor);
		printk(KERN_INFO "BE-300: card %04x:%04x COR %02x at %03x\n",
		       man, product, cor, attr);
	}
	return 0;
}

/* pcmcia.dll 0x0198C15C..0x0198C338: Vcc, reset pulse, card windows. */
static void be300_socket_power_up(void)
{
	be300_regs_socket_bus_init();
	BE300_W32(0x0a00a034, (BE300_R32(0x0a00a034) | 4) & ~0x30U);
	BE300_W32(0x0a00a034, (BE300_R32(0x0a00a034) | 8) & ~0x30U);
	BE300_W32(0x0a00a024, BE300_R32(0x0a00a024) & ~0x0cU);
	BE300_W32(0x0a00a020, BE300_R32(0x0a00a020) & ~0x0cU);
	BE300_W32(0x0a00a000, 0);
	BE300_W32(0x0a00a004, BE300_R32(0x0a00a004) | 1);
	BE300_W32(0x0a00a000, 8);
	BE300_W32(0x0a00a000, 9);
	be300_regs_delay_ms(300);
	BE300_W32(0x0a00a004, BE300_R32(0x0a00a004) & ~1U);
	be300_regs_delay_ms(20);
	BE300_W32(0x0a00a000, 0x0b);
	BE300_W32(0x0a001b20, 1);
	BE300_W32(0x0a00a01c, BE300_R32(0x0a00a01c) | 4);
}

static void __init be300_socket_prepare(void)
{
	u32 ctrl;

	ctrl = BE300_R32(0x0a00a000);
	if (be300_regs_card_present() && (ctrl & 0x0b) == 0x0b &&
	    !(BE300_R32(0x0a00a004) & 1))
		return; /* configured handoff, leave the card's COR alone */
	be300_regs_socket_bus_init();
	if (!be300_regs_card_present())
		return;
	be300_socket_power_up();
	be300_card_configure();
}

static int __init be300_hardware_init(void)
{
	spin_lock_init(&display_lock);
	be300_regs_power_on();	/* before any other companion unit */
	be300_regs_lcd_init();
	be300_regs_buzzer(0, 0);	/* stop a tone the previous OS left */
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
	register_reboot_notifier(&be300_reboot_nb);
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
