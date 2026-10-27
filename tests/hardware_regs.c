/* Register trace checks against the recovered WinCE startup contract. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
static struct { unsigned long pa; unsigned value; unsigned long time; } trace[512];
static unsigned ntrace, serial, clocks, latches, bits, stuck, reset_reads;
static unsigned long now;
static unsigned regs[0x10000 / 4], giu[16];
static unsigned read_reg(unsigned long pa)
{
	if (pa >= 0x0f000140 && pa < 0x0f000160) return giu[(pa - 0x0f000140) / 2];
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
	if (pa == 0x0a000c4c) {
		assert((old & ~7U) == (value & ~7U));
		if ((value & 2) && !(old & 2)) { serial = (serial << 1) | ((value >> 2) & 1); clocks++; bits++; }
		if ((value & 1) && !(old & 1)) { assert(bits == 8); latches++; bits = 0; }
	}
	regs[(pa - 0x0a000000) / 4] = value;
}
#define BE300_R32(pa) read_reg(pa)
#define BE300_W32(pa,v) write_reg(pa,v)
#define BE300_R16(pa) read_reg(pa)
#define BE300_W16(pa,v) write_reg(pa,(v)&0xffff)
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
	reset_reads = 0;
	assert(!be300_regs_piu_prepare());
	assert(regs[0x308/4] == 1500 && regs[0x30c/4] == 200);
	assert(regs[0x310/4] == 50 && regs[0x318/4] == 1);
	assert(regs[0x304/4] == 255 && !(regs[0x300/4] & 1));
	stuck = 1; now = 0;
	assert(be300_regs_piu_prepare() == -1 && now == 10000);
	regs[0x7834/4] = 3; /* real MCU status need not return zero */
	be300_regs_watchdog_reload(); be300_regs_watchdog_poll();
	assert(regs[0x7814/4] == 150 && regs[0x780c/4] == 0x53 && regs[0x7808/4] == 0x3a);
	puts("LCD sequence/delays, serial contrast, duty, PIU timeout, GIU preservation and MCU protocol passed");
	return 0;
}
