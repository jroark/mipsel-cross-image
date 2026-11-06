/* Register trace checks against the recovered WinCE startup contract. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
static struct { unsigned long pa; unsigned value; unsigned long time; } trace[512];
static unsigned ntrace, serial, clocks, latches, bits, stuck, reset_reads;
static unsigned long now;
static unsigned regs[0x10000 / 4], giu[16], rtc[32];
static unsigned char attr[0x800];
static int cor_ignored, adc_reading = -1, piu_w1c;
static unsigned read8(unsigned long pa)
{
	assert(pa >= 0x0a00d000 && pa < 0x0a00d800);
	return attr[pa - 0x0a00d000];
}
static void write8(unsigned long pa, unsigned value)
{
	assert(pa >= 0x0a00d000 && pa < 0x0a00d800);
	if (cor_ignored && pa == 0x0a00d200)
		return;	/* a card still settling drops the COR write */
	attr[pa - 0x0a00d000] = value;
}
static unsigned read_reg(unsigned long pa)
{
	if (pa >= 0x0f000140 && pa < 0x0f000160) return giu[(pa - 0x0f000140) / 2];
	if (pa >= 0x0f000100 && pa < 0x0f000140) return rtc[(pa - 0x0f000100) / 2];
	if (pa == 0x0a000300 && (regs[0x300/4] & 1) && !stuck && ++reset_reads == 3)
		regs[0x300/4] &= ~1;
	assert(pa >= 0x0a000000 && pa < 0x0a010000);
	return regs[(pa - 0x0a000000) / 4];
}
static void write_reg(unsigned long pa, unsigned value)
{
	unsigned old = read_reg(pa);
	assert(ntrace < 512);
	trace[ntrace].pa = pa; trace[ntrace].value = value; trace[ntrace++].time = now;
	if (pa >= 0x0f000140 && pa < 0x0f000160) { giu[(pa - 0x0f000140)/2] = value; return; }
	if (pa >= 0x0f000100 && pa < 0x0f000140) { rtc[(pa - 0x0f000100)/2] = value; return; }
	if (pa == 0x0a000c4c) {
		assert((old & ~7U) == (value & ~7U));
		if ((value & 2) && !(old & 2)) { serial = (serial << 1) | ((value >> 2) & 1); clocks++; bits++; }
		if ((value & 1) && !(old & 1)) { assert(bits == 8); latches++; bits = 0; }
	}
	regs[(pa - 0x0a000000) / 4] = value;
	if (pa == 0x0a000304 && piu_w1c)	/* PIUINT: mask byte, W1C status */
		regs[0x304/4] = (value & 0xff00) | (old & 0xff & ~value);
	/* Power MCU: 5C after ARG0 35 stops the watchdog, 3A after ARG 53
	 * starts it; STATUS reads 3 while it runs (be300 src/hw/cmcu.c). */
	if (pa == 0x0a007800 && value == 0x5c && regs[0x7804/4] == 0x35)
		regs[0x7834/4] = 0;
	if (pa == 0x0a007808 && value == 0x3a && regs[0x780c/4] == 0x53)
		regs[0x7834/4] = 3;
	/* PIU A/D port scan: PIUSEQEN with PIUMODE 01 latches the battery
	 * reading at 0390 and raises PIUINT bit 6 (be300 src/hw/piu.c). */
	if (pa == 0x0a000300 && (value & 0x0c) == 0x0c && adc_reading >= 0) {
		regs[0x390/4] = 0xf000 | adc_reading;
		regs[0x304/4] |= 0x40;
	}
}
#define BE300_R32(pa) read_reg(pa)
#define BE300_W32(pa,v) write_reg(pa,v)
#define BE300_R16(pa) read_reg(pa)
#define BE300_W16(pa,v) write_reg(pa,(v)&0xffff)
#define BE300_R8(pa) read8(pa)
#define BE300_W8(pa,v) write8(pa,(v)&0xff)
#define BE300_DELAY(us) (now += (us))
#include "../board/casio-be300/hardware-regs.h"

int main(void)
{
	static const unsigned phases[] = {0,1,0x101,0x103,0x10f,0x30f};
	unsigned i, phase = 0; unsigned long previous_time = 0;
	regs[0xc4c/4] = 0xa5a50000;
	regs[0x984/4] = 0x1234000f;
	regs[0xc34/4] = 0xdeadbeef;
	regs[0x1128/4] = 0xa4;
	be300_regs_lcd_init();
	assert(clocks == 8 && latches == 1 && serial == 0xc1);
	assert(regs[0x1128/4] == 0xa5 && regs[0x984/4] == 0x12340002);
	assert(regs[0xc34/4] == 0xdeadbeef && regs[0x98c/4] == 0);
	for (i = 0; i < ntrace; i++) if (trace[i].pa == 0x0a000c48) {
		assert(phase < 6 && trace[i].value == phases[phase]);
		if (phase == 2 || phase == 4) assert(trace[i].time - previous_time >= 1000);
		if (phase == 5) assert(trace[i].time - previous_time >= 20000);
		previous_time = trace[i].time; phase++;
	}
	assert(phase == 6 && now >= 22095);
	assert(regs[0xc00/4] == 0x20 && regs[0xc0c/4] == 0xf1 && regs[0xc24/4] == 0x14);
	be300_regs_brightness(0); assert(regs[0x98c/4] == 3339);
	be300_regs_brightness(3); assert(regs[0x98c/4] == 1964);
	be300_regs_brightness(5); assert(regs[0x98c/4] == 0);
	for (i = 0; i < 16; i++) giu[i] = 0xa5a5;
	be300_regs_giu0();
	assert(giu[0] == 0xa5a4 && giu[8] == 0xa5a4);
	assert(giu[10] == 0xa5a5 && giu[12] == 0xa5a5);
	assert(giu[1] == 0xa5a5 && giu[9] == 0xa5a5);
	/* Only line 0 is ours: every other GIU line off, all pending cleared. */
	assert(giu[6] == 0 && giu[7] == 0 && giu[4] == 0xffff && giu[5] == 0xffff);
	reset_reads = 0;
	assert(!be300_regs_piu_prepare());
	assert(regs[0x308/4] == 1500 && regs[0x30c/4] == 200);
	assert(regs[0x310/4] == 50 && regs[0x318/4] == 1);
	assert(regs[0x304/4] == 255 && !(regs[0x300/4] & 1));
	be300_regs_piu_start();
	assert(regs[0x3c8/4] == 3 && regs[0x300/4] == 0x306);
	assert(regs[0x304/4] == 0xdd00);
	be300_regs_piu_ack(0xdd04);
	assert(regs[0x304/4] == 0xdd1c && regs[0x300/4] == 0x306);
	be300_regs_piu_ack(0xdd08);
	assert(regs[0x304/4] == 0xdd08 && regs[0x300/4] == 0x306);
	ntrace = 0;
	be300_regs_piu_ack(0xdd00);
	assert(ntrace == 0);
	stuck = 1; now = 0;
	assert(be300_regs_piu_prepare() == -1 && now == 10000);
	regs[0x7834/4] = 3; /* real MCU status need not return zero */
	be300_regs_watchdog_reload(); be300_regs_watchdog_poll();
	assert(regs[0x7814/4] == 150 && regs[0x780c/4] == 0x53 && regs[0x7808/4] == 0x3a);
	/* Power-on: only 111C is on; the SIU must not be touched until its
	 * candidate gates are, and GPIO4/6 join GPIO5 as CE drives them. */
	memset(regs + 0x1100/4, 0, 16 * 4);
	regs[0x111c/4] = 1;
	giu[0] = 0x0020; giu[2] = 0xaab2;
	assert(!be300_regs_siu_clocked());
	be300_regs_power_on();
	assert(be300_regs_siu_clocked());
	assert(regs[0x1104/4] == 1 && regs[0x1108/4] == 1 && regs[0x1120/4] == 1);
	assert(regs[0x112c/4] == 1 && regs[0x1138/4] == 1 && regs[0x113c/4] == 1);
	assert(regs[0x111c/4] == 1 && !regs[0x1114/4] && !regs[0x1100/4]);
	assert(regs[0x1b20/4] == 1 && regs[0x1b24/4] == 0 && regs[0x1b2c/4] == 1);
	assert(regs[0xa0dc/4] == 0xff);
	assert(giu[0] == 0x0070 && giu[2] == 0xaae2);	/* CE: IOSELL 70, PIODL ..E2 */
	regs[0xa008/4] = 0x2f9; assert(be300_regs_card_present());
	regs[0xa008/4] = 0x3ff; assert(!be300_regs_card_present());
	regs[0x1000/4] = 0; regs[0xa008/4] = 0x2b9;	/* cold card: 1000 reads 0 */
	assert(be300_regs_card_present());
	/* Socket baseline (stock SPL 80F03248/80F03290) before power-up. */
	regs[0x111c/4] = 0; giu[0] = 0x0040; giu[2] = 0x0002;
	be300_regs_socket_bus_init();
	assert(regs[0x111c/4] == 1 && regs[0xa010/4] == 0x1073);
	assert(regs[0xa014/4] == 0x1061 && regs[0xa018/4] == 0x10b1);
	assert(giu[0] == 0x0060 && giu[2] == 0x0022);
	/* COR window: A034 bit 2, A024 bits 2-3 clear, A020 bit 3 only. */
	regs[0xa020/4] = 0x10f; regs[0xa024/4] = 0x0f; regs[0xa034/4] = 0x30;
	be300_regs_card_cor(0x3e0, 0x41);
	assert(attr[0x3e0] == 0x41 && regs[0xa020/4] == 0x10b);
	assert(regs[0xa024/4] == 0x03 && regs[0xa034/4] == 0x04);
	/* ATA: CCSR FD, COR 43, CCSR 01; read back, five tries. */
	now = 0;
	assert(!be300_regs_ata_cor(0x43));
	assert(attr[0x200] == 0x43 && attr[0x202] == 1 && now == 10000);
	cor_ignored = 1; attr[0x200] = 0; now = 0;
	assert(be300_regs_ata_cor(0x43) == -1 && now == 5 * 110000);
	cor_ignored = 0;
	/* Watchdog stop before halt/sleep, start on wake. */
	regs[0x7834/4] = 3;
	assert(!be300_regs_cmcu_stop() && !(regs[0x7834/4] & 7));
	assert(regs[0x7804/4] == 0x35 && regs[0x7800/4] == 0x5c);
	be300_regs_cmcu_start();
	assert(regs[0x7814/4] == 0x96 && regs[0x7834/4] == 3);
	/* Power-off: the ETIME alarm (ECMP) is moved out of reach, its latch
	 * cleared, so only Power wakes HIBERNATE. */
	be300_regs_rtc_alarm_off();
	assert(rtc[4] == 0xffff && rtc[5] == 0xffff && rtc[6] == 0xffff && rtc[0x1f] == 1);
	/* Piezo: 2 kHz at 50% is period 704, duty 351; the backlight's own
	 * 0980/0988/098C are untouched. */
	regs[0x980/4] = 1; regs[0x984/4] = 0x12340002; regs[0x988/4] = 0xf70;
	regs[0x98c/4] = 981; regs[0x1128/4] = 0xa4;
	be300_regs_buzzer(2000, 50);
	assert(regs[0x9a0/4] == 1 && regs[0x9a4/4] == 704 && regs[0x9a8/4] == 351);
	assert(regs[0x1128/4] == 0xa5 && regs[0x984/4] == 0x12340202);
	assert(regs[0x980/4] == 1 && regs[0x988/4] == 0xf70 && regs[0x98c/4] == 981);
	ntrace = 0;
	be300_regs_buzzer(0, 50);
	assert(regs[0x9a0/4] == 0 && ntrace == 1);
	{
		u32 saved[3];
		/* Blank with no tone: control 0, mode nibble and gate cleared. */
		be300_regs_backlight_off(saved, 0);
		assert(regs[0x980/4] == 0 && regs[0x984/4] == 0x12340200);
		assert(regs[0x1128/4] == 0xa4);
		be300_regs_backlight_on(saved, 0);
		assert(regs[0x980/4] == 1 && regs[0x984/4] == 0x12340202);
		assert(regs[0x1128/4] == 0xa5);
		/* Blank while a tone sounds: the shared gate and 0202 stay. */
		be300_regs_buzzer(1000, 50);
		be300_regs_backlight_off(saved, 1);
		assert(regs[0x980/4] == 0 && regs[0x1128/4] == 0xa5);
		assert((regs[0x984/4] & 0x0202) == 0x0202 && regs[0x9a0/4] == 1);
		be300_regs_backlight_on(saved, 1);
		assert(regs[0x980/4] == 1 && regs[0x1128/4] == 0xa5);
	}
	/* Panel power-down: C48 30F -> 10F (20 ms) -> 101 (1 ms) -> 0, C30 1;
	 * the VRAM gates stay on so a late framebuffer write cannot stall. */
	regs[0xc48/4] = 0x30f; regs[0x1100/4] = regs[0x110c/4] = 1; ntrace = 0; now = 0;
	be300_regs_lcd_sleep();
	assert(ntrace == 4 && trace[0].value == 0x10f && trace[1].value == 0x101);
	assert(trace[1].time >= 20000 && trace[2].time >= 21000 && trace[2].value == 0);
	assert(regs[0xc30/4] == 1 && regs[0x1100/4] == 1 && regs[0x110c/4] == 1);
	/* Battery: lines from GIUPIODL bits 2/12; an A/D sample only while the
	 * touch sequencer is idle, PIU state restored, touch events untouched. */
	giu[2] = 0x1004;
	assert(be300_regs_battery_lines() == 0x1004);
	regs[0x300/4] = 0x0400 | 0x0106; assert(be300_regs_piu_idle());
	regs[0x300/4] = 0x0800 | 0x0106; assert(!be300_regs_piu_idle());
	regs[0x300/4] = 0x1000 | 0x0106;
	giu[2] = 0x1104;
	be300_regs_battery_begin();
	assert(regs[0x300/4] == 0x1002 && giu[2] == 0x1004);
	regs[0x314/4] = 0x11; regs[0x318/4] = 0x22; regs[0x304/4] = 0xdd09;
	adc_reading = 0xcd5; piu_w1c = 1;
	assert(be300_regs_battery_convert() == 0xcd5);
	assert(regs[0x314/4] == 0x11 && regs[0x318/4] == 0x22);
	/* Pending touch events (09) survive; the A/D bit is cleared. */
	assert(regs[0x304/4] == 0xdd09 && !(regs[0x300/4] & 0x0c));
	adc_reading = -1; regs[0x304/4] = 0xdd00;
	assert(be300_regs_battery_convert() == 0);	/* no result: bounded */
	piu_w1c = 0;
	{
		/* An absent or erased EEPROM never acknowledges. */
		unsigned int b0 = 0, b1 = 0;
		regs[0xa1a4/4] = 1;
		assert(!be300_regs_ee_battery_cal(&b0, &b1));
		assert(b0 == 0xff && b1 == 0xff && regs[0x1124/4] == 0);
		assert(regs[0xa140/4] == 1 && regs[0xa194/4] == 0);
	}
	puts("LCD sequence/delays, serial contrast, duty, PIU timeout, GIU preservation, MCU protocol, power-on gates/GPIO, card detect, GIU lines, socket baseline, COR and watchdog stop/start, alarm-off, buzzer, shared-gate blanking, battery A/D, EEPROM and panel sleep passed");
	return 0;
}
